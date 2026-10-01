#!/usr/bin/env bash
set -euo pipefail

# Trinity orchestrator. Runs the Agent Trinity as headless `opencode run` processes.
#
# Implementation of docs/architecture/trinity-orchestrator/plan.md. The contract beside
# it (contract.md) is the source of truth for every behaviour encoded here; section
# numbers in the comments below refer to it.
#
# Two modes, per contract section 1:
#   trinity.sh <task>             brahma -> vishnu -> maheshwara, strictly sequential
#   trinity.sh --parallel <task>  brahma || vishnu, refuses unless a plan is on disk
#
# Exit codes, per contract section 1:
#   0  every role completed, no breach
#   1  a role crashed, refused, went silent, or breached its permitted paths
#   2  usage error
#   3  precondition unmet (--parallel with no plan on disk)
#
# ponytail: `opencode run` always exits 0, even when the agent hard-fails, so the exit
# code is deliberately ignored. Completion is decided from the --format json event stream
# (contract section 4), and the exit code is captured only to report it. Acceptable today
# because that stream is the only signal that separates a clean turn from a crash, verified
# on this machine 2026-09-30. Limitation: a provider failure that emits a *partial* stream
# that looks complete would read as success; only an empty stream is caught. Upgrade path:
# if OpenCode ever sets a non-zero exit on agent failure, use it and delete the stream
# parsing.

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$REPO_ROOT/.trinity"
PLAN_GLOB="$REPO_ROOT/docs/architecture/*/plan.md"

# Roles and the paths each may write. This restates the invariant in ADR 0003 so the path
# check has something to compare against, and it is also stated in each role's prompt,
# because a role that does not know its boundary cannot stay inside it.
permitted_for() {
  case "$1" in
    brahma)     printf 'docs/' ;;
    vishnu)     printf '!docs/' ;;   # inverted: everything except docs/
    maheshwara) printf '*' ;;        # unrestricted
  esac
}

usage() {
  cat <<EOF
Usage: trinity.sh [--parallel] "<task>"

  <task>            What the trinity should do. One argument.

  --parallel        Run brahma and vishnu concurrently. Refuses unless a plan
                    already exists at docs/architecture/<feature>/plan.md.
EOF
}

die_usage() {
  printf '%s\n' "$1" >&2
  usage >&2
  exit 2
}

# ── 1. Parse args (contract section 1) ────────────────────────────────────────
PARALLEL=0
TASK=""
TASK_SEEN=0
for arg in "$@"; do
  case "$arg" in
    --parallel)
      PARALLEL=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die_usage "Unknown option: $arg"
      ;;
    *)
      if [ "$TASK_SEEN" -eq 1 ]; then
        die_usage "Expected exactly one task, got more than one."
      fi
      TASK="$arg"
      TASK_SEEN=1
      ;;
  esac
done

if [ "$TASK_SEEN" -ne 1 ] || [ -z "$TASK" ]; then
  die_usage "Expected exactly one non-empty task argument."
fi

# ── 2. Resolve the opencode binary, preferring the local install ──────────────
LOCAL_BIN="$REPO_ROOT/open-code/node_modules/.bin/opencode"
OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
[ -x "$LOCAL_BIN" ] && OPENCODE_BIN="$LOCAL_BIN"
if [ -z "$OPENCODE_BIN" ]; then
  printf '%s✗ opencode not found. Run: cd open-code && npm install opencode-ai%s\n' "$RED" "$RST" >&2
  exit 2
fi

# ── 3. Preconditions (contract section 2) ────────────────────────────────────
# Checked once, before anything starts. No polling, no retry: a precondition that cannot
# be established is a refusal, not an error to work around.
if [ "$PARALLEL" -eq 1 ]; then
  # shellcheck disable=SC2086
  if ! ls $PLAN_GLOB >/dev/null 2>&1; then
    printf '%s✗ --parallel needs a plan on disk.%s\n' "$RED" "$RST" >&2
    printf '  Vishnu builds from a plan. Without one there is nothing to build from,\n' >&2
    printf '  and running the pair anyway is a race, not a parallel launch.\n' >&2
    printf '\n  Run the chain first:  trinity.sh "%s"\n' "$TASK" >&2
    exit 3
  fi
fi

# ── 4. State directory (contract section 5) ──────────────────────────────────
# ponytail: the run id carries the PID as well as the second. A bare whole-second
# timestamp collided when two runs started inside the same second, which the test suite
# does constantly: the second run inherited the first run's .verdict files, so a breach
# from one run failed an unrelated later one. About one run in five failed, at random,
# depending on where the second boundary fell. Acceptable today because PID plus
# second is unique among live processes. Limitation: a PID recycled within the same second
# would still collide. Upgrade path: use nanoseconds (date +%N) where supported, or mktemp.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="$STATE_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"
printf '%s  run %s  mode %s\n' "$RUN_ID" "$TASK" \
  "$([ "$PARALLEL" -eq 1 ] && echo parallel || echo chain)" > "$STATE_DIR/latest"

# Reference file for the path check. It lives inside .trinity, which the check prunes, so
# it can never be reported as a role's write.
STAMP="$RUN_DIR/.stamp"

# Directories the path check prunes. Build artefacts and vendored trees are not the
# operator's code, and a rebuild would otherwise read as an agent breach.
#
# ponytail: the two forms this replaced were both wrong, and both failed silently.
# Grouping the tests as \( -path A -path B \) ANDs them, so nothing matched and the prune
# never fired — the orchestrator's own .trinity/ logs read as a brahma breach. Holding
# them in a bash array then failed differently, because -path "./x" word-splits into two
# elements and every index was off by one, so find got a bare path and errored. Written
# literally instead, because the array was used once and bought nothing. Limitation: the
# prune list is maintained by hand. Upgrade path: derive it from .gitignore rather than
# restating it.
sweep_paths() {
  find . \( -path "./.git" -o -path "./.trinity" -o -path "./.venv" \
            -o -path "./.devbox" -o -name "node_modules" \) -prune \
    -o -type f -newer "$STAMP" -print 2>/dev/null || true
}

# A path is a breach when it is outside the role's permitted set.
#   docs/   -> must start with ./docs/
#   !docs/  -> must NOT start with ./docs/
#   *       -> anything
is_breach() {
  local role="$1" path="$2"
  case "$(permitted_for "$role")" in
    docs/)  case "$path" in ./docs/*) return 1 ;; *) return 0 ;; esac ;;
    '!docs/') case "$path" in ./docs/*) return 0 ;; *) return 1 ;; esac ;;
    *)      return 1 ;;
  esac
}

# ── 5. Role invocation (contract sections 3 and 4) ────────────────────────────
# BREACHES is safe as a plain variable because the path check only runs in chain mode,
# which is sequential. In parallel mode run_role runs in a background subshell and the
# assignment would be lost.
BREACHES=0

build_prompt() {
  local role="$1" permitted
  permitted="$(permitted_for "$role")"
  if [ "$permitted" = "!docs/" ]; then
    permitted_desc="everywhere except docs/"
  elif [ "$permitted" = "docs/" ]; then
    permitted_desc="docs/ only"
  else
    permitted_desc="anywhere in this repository"
  fi

  cat <<EOF
$TASK

Load the $role skill and follow it exactly.
You may write $permitted_desc.
Do not write anywhere else.

When you have finished, end your reply with exactly one line and nothing after it:
TRINITY-DONE: $role          if you completed the task
TRINITY-REFUSED: <reason>     if you declined it
EOF
}

# Classify a role from its --format json stream.
#
# The crash check runs FIRST: a stream that never completed a turn has no trustworthy
# final text, so the sentinel is not consulted (contract section 4).
#
# Prints one of: done | refused | silent | crashed | empty
classify() {
  local stream="$1"
  local reason="" sentinel=""

  if [ ! -s "$stream" ]; then
    printf 'empty'
    return
  fi

  # Last step_finish reason, and the last text line, read line by line. Accumulating the
  # whole stream and re-parsing at the end would lose the final event if the run died
  # mid-write, and that final event carries the verdict.
  #
  # ponytail: whitespace after the colon is normalised away before matching. The stream
  # observed on this machine is compact (`"reason":"stop"`), but a formatting change in a
  # future OpenCode would make every match fail, every role read as crashed, and the tool
  # stop working entirely. Acceptable today because the observed format is compact.
  # Limitation: this is a text match, not a JSON parse, so a model that emits the literal
  # text "reason":"stop" inside a message could confuse it. Upgrade path: if jq is already
  # a dependency of the launcher (it is), parse the stream with jq instead of matching.
  while IFS= read -r line; do
    line="${line//: /:}"
    case "$line" in
      *'"type":"step_finish"'*)
        case "$line" in
          *'"reason":"stop"'*)   reason="stop" ;;
          *'"reason":"'*)        reason="other" ;;
        esac
        ;;
      *'"type":"text"'*)
        case "$line" in
          *'TRINITY-DONE:'*)     sentinel="done" ;;
          *'TRINITY-REFUSED:'*)  sentinel="refused" ;;
        esac
        ;;
    esac
  done < "$stream"

  if [ "$reason" != "stop" ]; then
    printf 'crashed'
  elif [ "$sentinel" = "done" ]; then
    printf 'done'
  elif [ "$sentinel" = "refused" ]; then
    printf 'refused'
  else
    printf 'silent'
  fi
}

run_role() {
  local role="$1" raw="$2" log="$RUN_DIR/$role.log" prompt breaches="" verdict
  prompt="$(build_prompt "$role")"

  touch "$STAMP"
  "$OPENCODE_BIN" run --format json "$prompt" > "$raw" 2>> "$log" || true

  # The path check runs only when a role has the tree to itself. In parallel mode brahma
  # and vishnu share one tree, so an mtime sweep cannot tell whose write it is — and
  # because brahma's permitted set (docs/) and vishnu's (everything else) together cover
  # the whole tree, every touched file is permitted for *someone*. Running the per-role
  # check there does not fail open, it fails wrong: it attributed vishnu's writes to
  # brahma and would fail every parallel run. Recorded as a deviation from US3 in the plan.
  if [ "$PARALLEL" -eq 0 ]; then
    breaches="$(sweep_paths | while IFS= read -r p; do
      if is_breach "$role" "$p"; then printf '%s\n' "$p"; fi
    done)"
  fi

  verdict="$(classify "$raw")"

  # The verdict is written to a file rather than a shell variable because a role may run in
  # a subshell (parallel mode), and a subshell's variable assignments do not reach the
  # parent. ponytail: a file per role is less clever than declare -A and cannot be lost by
  # process isolation. Limitation: one small file per role per run. Upgrade path: none
  # needed until there are enough roles for the file count to matter.
  printf '%s\n' "$verdict" > "$RUN_DIR/$role.verdict"

  case "$verdict" in
    done)    printf '  %s✓%s %-11s done\n' "$GRN" "$RST" "$role" ;;
    refused) printf '  %s✗%s %-11s refused\n' "$RED" "$RST" "$role" ;;
    silent)  printf '  %s✗%s %-11s completed but reported no outcome\n' "$RED" "$RST" "$role" ;;
    crashed) printf '  %s✗%s %-11s crashed mid-turn\n' "$RED" "$RST" "$role" ;;
    empty)   printf '  %s✗%s %-11s produced no events (provider failure?)\n' "$RED" "$RST" "$role" ;;
  esac

  if [ -n "$breaches" ]; then
    BREACHES=1
    {
      printf '%s wrote outside its permitted paths\n' "$role"
      printf '%s' "$breaches"
    } >> "$RUN_DIR/paths.txt"
    printf '  %s⚠ breach%s  %s wrote outside its permitted paths\n' "$RED" "$RST" "$role" >&2
    printf '%s' "$breaches" | sed 's/^/      /' >&2
  fi

  # Surface tool errors without gating on them: the signal is reliable but the stop
  # condition would be wrong, because an agent that hits one bad read and recovers would
  # be failed (contract section 4).
  if grep -q '"status":"error"' "$raw" 2>/dev/null; then
    printf '  %s·%s tool error seen; not gating on it\n' "$YEL" "$RST" >&2
  fi
}

role_verdict() {
  local role="$1"
  [ -f "$RUN_DIR/$role.verdict" ] && cat "$RUN_DIR/$role.verdict" || printf 'missing'
}

# ── 6. Modes (contract section 2) ────────────────────────────────────────────
cd "$REPO_ROOT"
printf '%s◈ Trinity%s  %s%s%s\n' "$BLD" "$RST" "$CYN" "$TASK" "$RST"
printf '  run %s  →  %s\n\n' "$RUN_ID" "${RUN_DIR#$REPO_ROOT/}"

EXIT=0
if [ "$PARALLEL" -eq 0 ]; then
  for role in brahma vishnu maheshwara; do
    run_role "$role" "$RUN_DIR/$role.json"
    if [ "$(role_verdict "$role")" != "done" ]; then
      printf '\n%s✗ chain stopped at %s.%s Later roles did not run: a build without a plan\n' "$RED" "$role" "$RST" >&2
      printf '  and a verify without a build are both meaningless.\n' >&2
      printf '  Log: %s\n' "${RUN_DIR#$REPO_ROOT/}/$role.log" >&2
      EXIT=1
      break
    fi
  done
else
  # Both roles start, neither waits for the other. The path check is per-role, so
  # disjointness is checked after the fact, not enforced during.
  PIDS=""
  for role in brahma vishnu; do
    run_role "$role" "$RUN_DIR/$role.json" > "$RUN_DIR/$role.out" 2>&1 &
    PIDS="$PIDS $!"
  done
  for pid in $PIDS; do
    wait "$pid" || true
  done
  for role in brahma vishnu; do
    cat "$RUN_DIR/$role.out" 2>/dev/null || true
    if [ "$(role_verdict "$role")" != "done" ]; then
      EXIT=1
    fi
  done
  if [ "$EXIT" -ne 0 ]; then
    printf '\n%s✗ parallel run did not complete cleanly.%s\n' "$RED" "$RST" >&2
    printf '  Log: %s\n' "${RUN_DIR#$REPO_ROOT/}/" >&2
  fi

  # Say plainly what is not being checked, rather than printing a clean path that means
  # nothing. Disjointness here is enforced only by the role prompts, not by measurement.
  printf '  %s·%s path check not applicable in parallel mode: both roles share one tree,\n' "$YEL" "$RST"
  printf '    so a write cannot be attributed to the role that made it.\n'
fi

# ── 7. Report (contract sections 6 and 7) ────────────────────────────────────
if [ "$BREACHES" -eq 1 ]; then
  printf '\n%s✗ BREACH%s  a role wrote outside its permitted paths.\n' "$RED" "$RST" >&2
  printf '  See %s. No cleanup is attempted: there is no undo (ADR 0003).\n' \
    "${RUN_DIR#$REPO_ROOT/}/paths.txt" >&2
  EXIT=1
fi
if [ "$EXIT" -eq 0 ]; then
  printf '\n%s✓ trinity complete%s  → %s\n' "$GRN" "$RST" "${RUN_DIR#$REPO_ROOT/}/"
else
  printf '\n%s✗ trinity incomplete%s  → %s\n' "$RED" "$RST" "${RUN_DIR#$REPO_ROOT/}/"
fi

exit "$EXIT"
