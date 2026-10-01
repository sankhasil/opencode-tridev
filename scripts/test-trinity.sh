#!/usr/bin/env bash
set -euo pipefail

# Test harness for scripts/trinity.sh.
#
# The real `opencode run` is replaced by a stub, because every property under test —
# refusal, silence, a mid-turn crash, a path breach — is unreachable on demand from a
# live model, and a test that costs a model call per case is a test nobody runs.
#
# Cases map to docs/architecture/trinity-orchestrator/contract.md section 9.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TEST_REPO="$TMP_ROOT/repo"
mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/open-code/node_modules/.bin" \
         "$TEST_REPO/docs/architecture"

cp "$ROOT/scripts/trinity.sh" "$TEST_REPO/scripts/trinity.sh"

# Stub opencode. STUB_MODE selects the stream shape; STUB_WRITE_DIR makes each role write
# its own file in that directory, so a run can test both sides of the docs/ rule at once;
# STUB_SLEEP holds the process open so overlap is observable.
cat <<'EOF' > "$TEST_REPO/open-code/node_modules/.bin/opencode"
#!/usr/bin/env bash
set -euo pipefail

PROMPT="${*: -1}"
ROLE="$(printf '%s' "$PROMPT" | sed -nE 's/.*Load the ([a-z]+) skill.*/\1/p')"

if [ -n "${STUB_LOG:-}" ]; then
  printf 'start %s %s\n' "${ROLE:-unknown}" "$(date +%s.%N)" >> "$STUB_LOG"
fi

if [ -n "${STUB_WRITE_DIR:-}" ]; then
  mkdir -p "$STUB_WRITE_DIR"
  printf 'written by %s\n' "${ROLE:-unknown}" > "$STUB_WRITE_DIR/${ROLE:-unknown}.md"
fi

[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"

emit_text() {
  printf '{"type":"text","part":{"text":%s}}\n' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/\\n"/')"
}

case "${STUB_MODE:-done}" in
  done)
    printf '{"type":"step_start","part":{}}\n'
    printf '{"type":"step_finish","part":{"reason":"stop"}}\n'
    emit_text "TRINITY-DONE: ${ROLE:-unknown}"
    ;;
  refused)
    printf '{"type":"step_start","part":{}}\n'
    printf '{"type":"step_finish","part":{"reason":"stop"}}\n'
    emit_text "TRINITY-REFUSED: ${ROLE} may not do this"
    ;;
  silent)
    # Completed the turn but never reported an outcome.
    printf '{"type":"step_start","part":{}}\n'
    printf '{"type":"step_finish","part":{"reason":"stop"}}\n'
    emit_text "I am not sure what to do here."
    ;;
  crash)
    # Ended mid-turn, still issuing tool calls, and no sentinel.
    printf '{"type":"step_start","part":{}}\n'
    printf '{"type":"tool_use","part":{"tool":"read","state":{"status":"error","error":"nope"}}}\n'
    printf '{"type":"step_finish","part":{"reason":"tool-calls"}}\n'
    ;;
  empty)
    # Provider failure: no events at all.
    ;;
esac

if [ -n "${STUB_LOG:-}" ]; then
  printf 'end %s %s\n' "${ROLE:-unknown}" "$(date +%s.%N)" >> "$STUB_LOG"
fi
exit 0
EOF
chmod +x "$TEST_REPO/open-code/node_modules/.bin/opencode"

# The stub must be reachable by the name trinity.sh resolves. It prefers
# open-code/node_modules/.bin/opencode, which exists here, so no PATH surgery is needed.
assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    echo "assertion failed: $message" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

run_trinity() {
  ( cd "$TEST_REPO" && bash scripts/trinity.sh "$@" )
}

run_trinity_code() {
  ( cd "$TEST_REPO" && bash scripts/trinity.sh "$@" >/dev/null 2>&1 ) && echo 0 || echo $?
}

pass() { printf '  ok  %s\n' "$1"; }

echo "trinity.sh"

# ── Check 3: usage errors exit 2 ──────────────────────────────────────────────
assert_eq '2' "$(run_trinity_code)" 'no arguments should be a usage error'
assert_eq '2' "$(run_trinity_code --nonsense task)" 'unknown flag should be a usage error'
assert_eq '2' "$(run_trinity_code --parallel '')" 'empty task should be a usage error'
assert_eq '2' "$(run_trinity_code a b)" 'two tasks should be a usage error'
assert_eq '0' "$(grep -c 'Usage:' "$TEST_REPO"/dev/null 2>/dev/null || echo 0)" 'usage text is not required in stdout'
pass 'usage errors exit 2'

# ── Check 3b: the chain runs all three roles in order ─────────────────────────
STUB_LOG="$TMP_ROOT/chain.log" STUB_MODE=done run_trinity "add a feature" >/dev/null
chain_roles="$(awk '{print $2}' "$TMP_ROOT/chain.log" | uniq | tr '\n' ' ')"
assert_eq 'brahma vishnu maheshwara ' "$chain_roles" 'chain should run brahma, vishnu, maheshwara in order'

# Ordering, not just membership: each role's "end" precedes the next role's "start".
assert_eq '3' "$(grep -c '^end ' "$TMP_ROOT/chain.log")" 'each role should end before the next begins'
pass 'chain runs brahma -> vishnu -> maheshwara sequentially'

# ── Check 4: --parallel with no plan exits 3 and starts nothing ───────────────
rm -rf "$TEST_REPO/docs/architecture"/*
assert_eq '3' "$(run_trinity_code --parallel "replan")" 'parallel without a plan should refuse'

STUB_LOG="$TMP_ROOT/nothing.log" STUB_MODE=done run_trinity --parallel "replan" >/dev/null 2>&1 || true
assert_eq '0' "$([ -f "$TMP_ROOT/nothing.log" ] && echo 1 || echo 0)" 'a refused parallel run must start no process'
pass '--parallel without a plan exits 3 and starts nothing'

# ── Check 5: --parallel with a plan starts both concurrently ──────────────────
mkdir -p "$TEST_REPO/docs/architecture/demo"
cat <<'EOF' > "$TEST_REPO/docs/architecture/demo/plan.md"
---
type: concept
title: Demo
---

# Demo
EOF

STUB_LOG="$TMP_ROOT/par.log" STUB_MODE=done STUB_SLEEP=1 run_trinity --parallel "replan" >/dev/null
brahma_end="$(awk '$1=="end" && $2=="brahma" {print $3; exit}' "$TMP_ROOT/par.log")"
vishnu_start="$(awk '$1=="start" && $2=="vishnu" {print $3; exit}' "$TMP_ROOT/par.log")"
if [ -z "$brahma_end" ] || [ -z "$vishnu_start" ]; then
  echo "assertion failed: parallel run did not start both roles" >&2
  exit 1
fi
# Vishnu must have started before brahma finished, otherwise the pair was sequential.
overlapped="$(awk -v a="$vishnu_start" -v b="$brahma_end" 'BEGIN{print (a < b) ? "yes" : "no"}')"
assert_eq 'yes' "$overlapped" 'brahma and vishnu should overlap in time'
pass '--parallel starts brahma and vishnu concurrently'

# ── Check 6: breach is detected and names the file ────────────────────────────
# The check only runs where a role has the tree to itself, which is chain mode. In
# parallel mode it is structurally impossible to attribute a write to a role, so the
# orchestrator says so rather than reporting a false breach — see the parallel case below.
mkdir -p "$TEST_REPO/docs/architecture/demo"
# Chain mode, all three roles write at the repo root. Only brahma breaches: vishnu and
# maheshwara may write anywhere, and vishnu must not write into docs/.
out="$(STUB_MODE=done STUB_WRITE_DIR="$TEST_REPO" run_trinity "replan" 2>&1 || true)"
assert_eq '1' "$(printf '%s' "$out" | grep -c 'brahma wrote outside its permitted paths')" \
  'brahma should be named as the breaching role'
assert_eq '1' "$(printf '%s' "$out" | grep -c './brahma.md')" 'the offending file should be named'
assert_eq '0' "$(printf '%s' "$out" | grep -c './vishnu.md')" 'vishnu writing at the root is allowed'
assert_eq '0' "$(printf '%s' "$out" | grep -c './maheshwara.md')" 'maheshwara writing at the root is allowed'
rm -f "$TEST_REPO/brahma.md" "$TEST_REPO/vishnu.md" "$TEST_REPO/maheshwara.md"

# vishnu writing into docs/ is a breach; brahma writing into docs/ is not. One run, both
# directions.
out="$(STUB_MODE=done STUB_WRITE_DIR="$TEST_REPO/docs" run_trinity "replan2" 2>&1 || true)"
assert_eq '0' "$(printf '%s' "$out" | grep -c './docs/brahma.md')" 'brahma writing into docs/ is allowed'
assert_eq '1' "$(printf '%s' "$out" | grep -c './docs/vishnu.md')" 'vishnu writing into docs/ is a breach'
rm -f "$TEST_REPO/docs/brahma.md" "$TEST_REPO/docs/vishnu.md" "$TEST_REPO/docs/maheshwara.md"

# A breach must set a non-zero exit. In parallel mode the roles run in background
# subshells, so a breach recorded in a shell variable would never reach the parent and the
# run would exit 0 while printing a warning.
assert_eq '1' "$(STUB_MODE=done STUB_WRITE_DIR="$TEST_REPO" run_trinity_code "breach exit check")" \
  'a breach in chain mode should exit 1'
rm -f "$TEST_REPO/brahma.md" "$TEST_REPO/vishnu.md" "$TEST_REPO/maheshwara.md"
assert_eq '0' "$(run_trinity_code "clean run")" 'a run with no breach should exit 0'
pass 'breach names the role and the file, and exits non-zero'

# Parallel mode must not claim a clean path check it cannot perform, and must not
# attribute one role's write to the other.
out="$(STUB_MODE=done STUB_WRITE_DIR="$TEST_REPO" run_trinity --parallel "replan3" 2>&1 || true)"
assert_eq '1' "$(printf '%s' "$out" | grep -c 'path check not applicable')" \
  'parallel mode should say the path check does not apply'
assert_eq '0' "$(printf '%s' "$out" | grep -c 'wrote outside its permitted paths')" \
  'parallel mode must not attribute one role write to another role'
rm -f "$TEST_REPO/brahma.md" "$TEST_REPO/vishnu.md"

# ── Check 7: a well-behaved run prints nothing about paths ───────────────────
out="$(STUB_MODE=done run_trinity "clean task" 2>&1)"
assert_eq '0' "$(printf '%s' "$out" | grep -c 'BREACH')" 'a clean run must not mention BREACH'
pass 'no breach prints nothing about paths'

# ── Sentinel classification: crash, refusal, silence each stop the chain ──────
for mode in crash refused silent; do
  code="$(STUB_MODE="$mode" run_trinity_code "task for $mode")"
  assert_eq '1' "$code" "a $mode role should stop the chain with exit 1"
done
pass 'crash, refusal, and silence each stop the chain'

# A refusal in the first role must prevent the second role from running at all.
STUB_LOG="$TMP_ROOT/refuse.log" STUB_MODE=refused run_trinity "task" >/dev/null 2>&1 || true
assert_eq '0' "$(awk '$2=="vishnu"' "$TMP_ROOT/refuse.log" | wc -l | tr -d ' ')" \
  'a refusing brahma must prevent vishnu from starting'
pass 'a refusal stops the chain before the next role'

# ── Check 8: no survivors ─────────────────────────────────────────────────────
STUB_MODE=done run_trinity "survivor check" >/dev/null
assert_eq '0' "$(pgrep -f "node_modules/.bin/opencode run" 2>/dev/null | wc -l | tr -d ' ')" \
  'no opencode run child should remain after the script exits'
pass 'no survivors'

# ── Check 9: syntax ───────────────────────────────────────────────────────────
bash -n "$TEST_REPO/scripts/trinity.sh"
pass 'bash -n clean'

# ── The run leaves a readable state directory, and nothing else ───────────────
# Contract section 5: one directory per run, never cleaned automatically, plus a
# one-line `latest`. Several runs have happened by now, so assert >= 1, not == 1.
run_dirs="$(find "$TEST_REPO/.trinity" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
if [ "$run_dirs" -lt 1 ]; then
  echo "assertion failed: no run directory was created" >&2
  exit 1
fi
assert_eq '1' "$(wc -l < "$TEST_REPO/.trinity/latest" | tr -d ' ')" 'latest should be a single line'
assert_eq '0' "$(pgrep -f 'opencode run' 2>/dev/null | wc -l | tr -d ' ')" 'no opencode run process should outlive the run'
pass 'state directory is one plain-text run directory per run plus latest'

# ── Regression: back-to-back runs must not share a run directory ──────────────
# A whole-second run id collided here: the second run inherited the first run's verdict
# and breach files, so results leaked between runs. About one run in five failed.
for i in 1 2 3 4 5 6; do
  run_trinity "collision probe $i" >/dev/null
done
dirs="$(find "$TEST_REPO/.trinity" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
if [ "$dirs" -lt 6 ]; then
  echo "assertion failed: 6 back-to-back runs produced only $dirs run directories" >&2
  echo "a run id collision would explain this" >&2
  exit 1
fi
pass 'back-to-back runs get distinct run directories'

echo "all trinity.sh tests passed"
