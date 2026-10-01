#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

OLLAMA_MODEL="hhao/qwen2.5-coder-tools:7b"
TOOLS_BASE="http://localhost:4198/v1"
TSYSTEMS_BASE="https://llm-server.llmhub.t-systems.net/v2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_SRC="$REPO_ROOT/open-code/AGENTS.md"
AGENTS_MARKER_BEGIN="<!-- BEGIN OPENCODE SHARED AGENTS -->"
AGENTS_MARKER_END="<!-- END OPENCODE SHARED AGENTS -->"
CONFIG_SRC="$REPO_ROOT/opencode.json"
# ponytail: Colibri/DeepSeek-V4-Flash is NOT usable until 32 GB RAM; this box has 16 GB.
# The provider block is deliberately NOT generated into opencode.json, so the
# model can only be re-enabled here once running on a 32 GB+ machine.

fetch_tsystems_models() {
  local response_url="$TSYSTEMS_BASE/models"
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YEL}  jq not found — keeping existing T-Systems models block${RST}"
    return 1
  fi

  if [ -z "${TSYSTEMS_OPENCODE_API_KEY:-}" ]; then
    echo -e "${YEL}  TSYSTEMS_OPENCODE_API_KEY not set — keeping existing T-Systems models block${RST}"
    return 1
  fi

  if ! curl -fsS -H "Authorization: Bearer ${TSYSTEMS_OPENCODE_API_KEY}" "$response_url" | jq -c '
    [(.data // .models // [])[]
      | {
          id: .id,
          base_name: (.meta_data.display_name // .name // .id),
          context: (.meta_data.max_sequence_length // .context_window // .contextWindow // .limit.context // 0),
          output: (.meta_data.max_output_length // .max_output_tokens // .maxOutputTokens // .limit.output // 0)
        }
    ]
  ' ; then
    echo -e "${YEL}  Failed to fetch T-Systems /models — keeping existing models block${RST}"
    return 1
  fi
}

build_tsystems_models_json() {
  local source_json="$1"
  jq -cn --argjson models "$source_json" '
    def tier_of($severity):
      {"Budget": 1, "Moderate cost": 2, "Premium": 3, "High cost": 4, "Very high cost": 5}[$severity];
    def pricing($id):
      {
        "claude-sonnet-4.6": {severity: "High cost", label: "Claude 4.6 Sonnet", input: "2.97", output: "14.85", context: 200000},
        "claude-opus-4.8": {severity: "Very high cost", label: "Claude Opus 4.8", input: "4.95", output: "24.75", context: 200000},
        "gemini-3.1-pro": {severity: "High cost", label: "Gemini 3.1 Pro", input: "3.60", output: "16.20", context: 200000},
        "gemini-3.5-flash": {severity: "Moderate cost", label: "Gemini 3.5 Flash", input: "1.49", output: "8.91", context: 1000000},
        "gpt-5.4": {severity: "High cost", label: "GPT 5.4", input: "2.42", output: "14.49", context: 400000},
        "glm-5.2": {severity: "Premium", label: "GLM 5.2", input: "1.50", output: "3.50", context: 1000000},
        "gpt-oss-120b": {severity: "Budget", label: "GPT OSS 120B", input: "0.20", output: "0.65", context: 128000},
        "jina-embeddings-v2-base-de": {severity: "Budget", label: "Jina Embeddings v2 Base DE", input: "0.05", output: "0.05", context: 8000},
        "jina-embeddings-v2-base-code": {severity: "Budget", label: "Jina Embeddings v2 Base Code", input: "0.05", output: "0.05", context: 8000},
        "mistral-small-4": {severity: "Moderate cost", label: "Mistral Small 4", input: "0.60", output: "1.20", context: 256000},
        "nvidia-nemotron-3-super-120b-a12b-fp8": {severity: "Moderate cost", label: "NVIDIA Nemotron 3 Super 120B FP8", input: "0.60", output: "1.20", context: 1000000},
        "qwen3.6-35b-a3b-fp8": {severity: "Moderate cost", label: "Qwen3.6 35B A3B FP8", input: "0.60", output: "1.20", context: 256000},
        "bge-m3": {severity: "Budget", label: "BGE-M3", input: "0.05", output: "0.05", context: 8000}
      }[($id | ascii_downcase)];
    def priced_name($model; $price):
      if $price then
        "TIER \(tier_of($price.severity)) \($price.severity | ascii_upcase) - \($price.label) (Euro\($price.input)/Euro\($price.output))"
      else
        "UNPRICED - \($model.base_name)"
      end;
    reduce $models[] as $model (
      {};
      .[$model.id] = (
        (pricing($model.id)) as $price
        | {
            name: priced_name($model; $price),
            limit: {
              context: (
                if (($price // {}) | has("context")) and (($model.context | tonumber?) // 0) <= 0 then
                  $price.context
                else
                  (($model.context | tonumber?) // (($price // {}).context // 128000))
                end
              ),
              output: ($model.output | tonumber? // 4096)
            }
          }
      )
    )
  '
}

merge_configs() {
  local base_config="$1"
  local target_config="$2"
  local merged_config="$3"

  jq -s '
    def merge_values($base; $overlay):
      if ($base | type) == "object" and ($overlay | type) == "object" then
        reduce (($base + $overlay) | keys_unsorted[]) as $key (
          {};
          .[$key] =
            if ($base | has($key)) and ($overlay | has($key)) then
              merge_values($base[$key]; $overlay[$key])
            elif $overlay | has($key) then
              $overlay[$key]
            else
              $base[$key]
            end
        )
      elif ($base | type) == "array" and ($overlay | type) == "array" then
        reduce ($base + $overlay)[] as $item (
          [];
          if any(.[]; . == $item) then . else . + [$item] end
        )
      else
        $overlay
      end;

    merge_values(.[0]; .[1])
  ' "$base_config" "$target_config" > "$merged_config"
}

build_merged_agents() {
  local src="$1" dst="$2" out="$3"

  # ponytail: Three idempotent cases — (1) markers present: replace the shared
  # block, preserve local content before/after it; (2) no markers, dst==src:
  # wrap src with markers; (3) no markers, dst starts with src (old plain-cp
  # first run + hand-edited local content): wrap the shared prefix, keep the
  # suffix as local content after END. Trailing blanks around the block are
  # trimmed so repeated runs produce byte-identical output (cmp -s fires the
  # "no merge needed" branch instead of accumulating blank lines each run).
  if grep -Fq "$AGENTS_MARKER_BEGIN" "$dst"; then
    local tmp_before tmp_after
    tmp_before="$(mktemp)"; tmp_after="$(mktemp)"
    awk -v begin="$AGENTS_MARKER_BEGIN" -v end="$AGENTS_MARKER_END" \
        -v bf="$tmp_before" -v af="$tmp_after" '
      $0 == begin { state=1; next }
      state==1 && $0 == end { state=2; next }
      state==0 { print > bf }
      state==2 { print > af }
    ' "$dst"
    awk '{ lines[++n]=$0 } END { while (n>0 && lines[n]=="") n--; for (i=1;i<=n;i++) print lines[i] }' "$tmp_before" > "${tmp_before}.c"
    awk 'NF{p=1} p{lines[++n]=$0} END{while(n>0 && lines[n]=="")n--; for(i=1;i<=n;i++) print lines[i]}' "$tmp_after" > "${tmp_after}.c"
    : > "$out"
    if [ -s "${tmp_before}.c" ]; then cat "${tmp_before}.c" >> "$out"; printf '\n' >> "$out"; fi
    printf '%s\n\n' "$AGENTS_MARKER_BEGIN" >> "$out"
    cat "$src" >> "$out"
    printf '\n%s\n' "$AGENTS_MARKER_END" >> "$out"
    if [ -s "${tmp_after}.c" ]; then printf '\n' >> "$out"; cat "${tmp_after}.c" >> "$out"; fi
    rm -f "$tmp_before" "$tmp_after" "${tmp_before}.c" "${tmp_after}.c"
  elif cmp -s "$src" "$dst"; then
    printf '%s\n\n' "$AGENTS_MARKER_BEGIN" > "$out"
    cat "$src" >> "$out"
    printf '\n%s\n' "$AGENTS_MARKER_END" >> "$out"
  else
    local src_bytes suffix_tmp
    src_bytes="$(wc -c < "$src")"
    if cmp -s "$src" <(head -c "$src_bytes" "$dst"); then
      suffix_tmp="$(mktemp)"
      tail -c +"$((src_bytes + 1))" "$dst" \
        | awk 'NF{p=1} p{lines[++n]=$0} END{while(n>0 && lines[n]=="")n--; for(i=1;i<=n;i++) print lines[i]}' \
        > "$suffix_tmp"
      printf '%s\n\n' "$AGENTS_MARKER_BEGIN" > "$out"
      cat "$src" >> "$out"
      printf '\n%s\n' "$AGENTS_MARKER_END" >> "$out"
      if [ -s "$suffix_tmp" ]; then printf '\n' >> "$out"; cat "$suffix_tmp" >> "$out"; fi
      rm -f "$suffix_tmp"
    else
      cat "$dst" > "$out"
      printf '\n%s\n\n' "$AGENTS_MARKER_BEGIN" >> "$out"
      cat "$src" >> "$out"
      printf '\n%s\n' "$AGENTS_MARKER_END" >> "$out"
    fi
  fi
}

agents_merge_action() {
  local dst="$1"
  if grep -Fq "$AGENTS_MARKER_BEGIN" "$dst"; then
    printf 'Update shared AGENTS.md block in %s' "$dst"
  else
    printf 'Add shared AGENTS.md block into %s' "$dst"
  fi
}

confirm_agents_merge() {
  local prompt="$1" reply
  printf '%s' "$prompt"
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

load_env_file() {
  local env_file="$1"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  fi
}

# Load launcher defaults first so project-local .env can override them.
# devbox.json init_hook also does this for `devbox shell`; this covers `devbox run` and direct `bash scripts/opencode.sh`.
load_env_file "$REPO_ROOT/.env"

LOCAL_BIN="$REPO_ROOT/open-code/node_modules/.bin/opencode"
OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
[ -x "$LOCAL_BIN" ] && OPENCODE_BIN="$LOCAL_BIN"

if [ -z "$OPENCODE_BIN" ]; then
  echo -e "${RED}✗ opencode not found, skipping execution. Config/Agents generated.${RST}"
  echo "  Install locally: cd open-code && npm install opencode-ai"
  # Proceed to generate config even if we can't execute immediately
  :
fi

# ── 1. Parse args + resolve target folder ─────────────────────────────────
START_OLLAMA=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --ollama)
      START_OLLAMA=1
      ;;
    --help|-h)
      echo "Usage: opencode.sh [--ollama] [TARGET]"
      echo "  --ollama  Start Ollama + tool-call proxy if not running"
      echo "  TARGET    Working folder (default: repo root)"
      exit 0
      ;;
    *)
      if [ -n "$TARGET" ]; then
        echo -e "${RED}✗ Unexpected argument: $arg${RST}"
        exit 1
      fi
      TARGET="$arg"
      ;;
  esac
done
: "${TARGET:=$REPO_ROOT}"
if [[ "$TARGET" != /* ]]; then
  TARGET="$REPO_ROOT/$TARGET"
fi
TARGET="$(cd "$TARGET" && pwd)"

if [ ! -d "$TARGET" ]; then
  echo -e "${RED}✗ Folder not found: $TARGET${RST}"
  exit 1
fi

TARGET="${TARGET:-.}"
if [[ "$TARGET" != /* ]]; then
    TARGET="$REPO_ROOT/$TARGET"
fi
TARGET="$(cd "$TARGET" && pwd)"

load_env_file "$TARGET/.env"

# ── 1.5. Ensure agent skills are installed locally ─────────────────────
install_skills() {
    local SKILLS_DIR="$REPO_ROOT/.agents/skills"
    local SUPERPOWERS_URL="https://github.com/obra/superpowers.git"
    
    mkdir -p "$SKILLS_DIR"
    
    if [ ! -d "$SKILLS_DIR/superpowers" ]; then
        echo -e "${YEL}  🧩 Installing agent skills...${RST}"
        git clone --depth 1 "$SUPERPOWERS_URL" "$SKILLS_DIR/superpowers" 2>/dev/null
        echo -e "${GRN}  ✓ superpowers skill installed${RST}"
    else
        echo -e "${GRN}  ✓ superpowers skill already installed${RST}"
    fi
}
install_skills

echo -e "${BLD}◈ OpenCode${RST}  →  ${CYN}${TARGET}${RST}"

# ── 2. Write project config (sync T-Systems models only when the catalog changes) ──
mkdir -p "$(dirname "$CONFIG_SRC")"
TSYSTEMS_MODELS='{
  "claude-sonnet-4.6": {
    "name": "Claude 4.6 Sonnet (High cost, Euro2.97/Euro14.85)",
    "limit": { "context": 200000, "output": 64000 }
  },
  "claude-opus-4.8": {
    "name": "Claude Opus 4.8 (Very high cost, Euro4.95/Euro24.75)",
    "limit": { "context": 200000, "output": 128000 }
  },
  "gpt-5.4": {
    "name": "GPT 5.4 (High cost, Euro2.42/Euro14.49)",
    "limit": { "context": 400000, "output": 128000 }
  },
  "gemini-3.1-pro": {
    "name": "Gemini 3.1 Pro (High cost, Euro3.60/Euro16.20)",
    "limit": { "context": 200000, "output": 65536 }
  },
  "Qwen3.6-35B-A3B-FP8": {
    "name": "Qwen 3.6 35B FP8 (Moderate cost, Euro0.60/Euro1.20)",
    "limit": { "context": 256000, "output": 262144 }
  },
  "NVIDIA-Nemotron-3-Super-120B-A12B-FP8": {
    "name": "NVIDIA Nemotron 3 Super 120B FP8 (Moderate cost, Euro0.60/Euro1.20)",
    "limit": { "context": 1000000, "output": 256000 }
  },
  "gpt-oss-120b": {
    "name": "GPT OSS 120B (Euro0.20/Euro0.65)",
    "limit": { "context": 128000, "output": 32768 }
  }
}'

# ponytail: on fetch failure, prefer the models block already in opencode.json over
# the embedded catalog. The embedded 7-model list is a first-run bootstrap only;
# writing it over a good 40-model block silently drops 33 models and strips every
# TIER label, with no error. Acceptable today because the block is only ever
# replaced when /models actually answers. Limitation: a model removed upstream
# lingers in the config until the next successful sync. Upgrade path: if the API
# ever returns a catalog hash, compare that instead of falling back.
EXISTING_TSYSTEMS_MODELS="$(jq -c '.provider.tsystems.models // empty' "$CONFIG_SRC" 2>/dev/null || true)"

if TSYSTEMS_FETCHED="$(fetch_tsystems_models 2>/dev/null)"; then
  TSYSTEMS_MODELS="$(build_tsystems_models_json "$TSYSTEMS_FETCHED")"
  echo -e "${GRN}✓ Synced T-Systems models from /models${RST}"
elif [ -n "$EXISTING_TSYSTEMS_MODELS" ]; then
  TSYSTEMS_MODELS="$EXISTING_TSYSTEMS_MODELS"
  echo -e "${YEL}  /models unreachable — keeping existing T-Systems models block ($(printf '%s' "$EXISTING_TSYSTEMS_MODELS" | jq 'length') models)${RST}"
else
  echo -e "${YEL}  Using embedded T-Systems model catalog (first run bootstrap)${RST}"
fi

    # ponytail: one relative path so a fresh clone resolves the skills without
    # an absolute /Users/... path baked into the generated config.
    SKILLS_PATH=".opencode/skills"

# ── Model selection: env → existing opencode.json → built-in default ──────────
# Reading the existing config is what makes opencode.json the source of truth for
# model choice. Without it the generator silently reverts a hand-edited model on
# every launch.
#
# ponytail: three-level precedence with jq as an optional dependency. Acceptable
# today because a missing jq only costs the "read existing config" step — env and
# the built-in default still work. Limitation: editing model choice then running
# without jq discards the edit. Upgrade path: if jq is ever guaranteed, drop the
# env level and let opencode.json be the only place a model is chosen.
DEFAULT_MODEL="${DEFAULT_MODEL:-}"
DEFAULT_SMALL_MODEL="${DEFAULT_SMALL_MODEL:-}"
if { [ -z "$DEFAULT_MODEL" ] || [ -z "$DEFAULT_SMALL_MODEL" ]; } &&
   [ -f "$CONFIG_SRC" ] && command -v jq >/dev/null 2>&1; then
  [ -z "$DEFAULT_MODEL" ] && DEFAULT_MODEL="$(jq -r '.model // empty' "$CONFIG_SRC" 2>/dev/null)"
  [ -z "$DEFAULT_SMALL_MODEL" ] && DEFAULT_SMALL_MODEL="$(jq -r '.small_model // empty' "$CONFIG_SRC" 2>/dev/null)"
fi
: "${DEFAULT_MODEL:=opencode/space-bunny-free}"
: "${DEFAULT_SMALL_MODEL:=$DEFAULT_MODEL}"

    TMP_CONFIG="$(mktemp)"
    cat > "$TMP_CONFIG" << EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$DEFAULT_MODEL",
  "small_model": "$DEFAULT_SMALL_MODEL",
  "share": "disabled",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "TIER 0 FREE - Local Ollama",
      "options": {
        "baseURL": "$TOOLS_BASE",
        "apiKey": "ollama"
      },
      "models": {
        "$OLLAMA_MODEL": {
          "name": "TIER 0 FREE - Qwen2.5 Coder Tools 7B (local)"
        }
      }
    },
    "tsystems": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "T-Systems LLM Hub",
      "options": {
        "baseURL": "$TSYSTEMS_BASE",
        "apiKey": "{env:TSYSTEMS_OPENCODE_API_KEY}"
      },
      "models": $TSYSTEMS_MODELS
    }
  },
  "mcp": {
    "jira": {
      "type": "local",
      "command": ["uvx", "mcp-atlassian"],
      "enabled": true,
      "environment": {
        "JIRA_URL": "{env:JIRA_URL}",
        "JIRA_USERNAME": "{env:JIRA_USER_EMAIL}",
        "JIRA_API_TOKEN": "{env:JIRA_API_TOKEN}",
        "JIRA_PROJECTS_FILTER": "{env:JIRA_PROJECT}"
      }
    }
  },
  "plugin": ["opencode-skillful", "superpowers@git+https://github.com/obra/superpowers.git"],
  "skills": {
    "paths": [
      "$SKILLS_PATH"
    ]
  }
}
EOF
if [ -f "$CONFIG_SRC" ] && cmp -s "$TMP_CONFIG" "$CONFIG_SRC"; then
  rm -f "$TMP_CONFIG"
  echo -e "${GRN}✓ OpenCode config unchanged${RST}  ($CONFIG_SRC)"
else
  mv "$TMP_CONFIG" "$CONFIG_SRC"
  echo -e "${GRN}✓ OpenCode config written${RST}  ($CONFIG_SRC)"
fi

# Copy config to TARGET so opencode finds it in CWD
CONFIG_DST="$TARGET/opencode.json"
if [ "$CONFIG_SRC" != "$CONFIG_DST" ] && [ -f "$CONFIG_SRC" ]; then
  if [ -f "$CONFIG_DST" ]; then
    TMP_MERGED_CONFIG="$(mktemp)"
    merge_configs "$CONFIG_SRC" "$CONFIG_DST" "$TMP_MERGED_CONFIG"
    mv "$TMP_MERGED_CONFIG" "$CONFIG_DST"
    echo -e "${GRN}✓ Config merged into CWD${RST}  ($CONFIG_DST)"
  else
    cp "$CONFIG_SRC" "$CONFIG_DST"
    echo -e "${GRN}✓ Config copied to CWD${RST}  ($CONFIG_DST)"
  fi
fi

# ── 3. Propagate AGENTS.md to target (idempotent) ─────────────────────────
AGENTS_DST="$TARGET/AGENTS.md"
if [ ! -f "$AGENTS_DST" ]; then
  {
    printf '%s\n\n' "$AGENTS_MARKER_BEGIN"
    cat "$AGENTS_SRC"
    printf '\n%s\n' "$AGENTS_MARKER_END"
  } > "$AGENTS_DST"
  echo -e "${GRN}✓ AGENTS.md copied${RST}  → ${AGENTS_DST}"
else
  TMP_MERGED_AGENTS="$(mktemp)"
  build_merged_agents "$AGENTS_SRC" "$AGENTS_DST" "$TMP_MERGED_AGENTS"

  if cmp -s "$AGENTS_DST" "$TMP_MERGED_AGENTS"; then
    rm -f "$TMP_MERGED_AGENTS"
    echo -e "${GRN}✓ AGENTS.md unchanged${RST}  (no merge needed)"
  else
    AGENTS_ACTION="$(agents_merge_action "$AGENTS_DST")"
    echo -e "${YEL}  AGENTS.md merge preview:${RST}"
    diff -u "$AGENTS_DST" "$TMP_MERGED_AGENTS" || true
    echo ""

    if confirm_agents_merge "$AGENTS_ACTION? [y/N] "; then
      mv "$TMP_MERGED_AGENTS" "$AGENTS_DST"
      echo -e "${GRN}✓ AGENTS.md merged${RST}  (preserved local content, updated shared block)"
    else
      rm -f "$TMP_MERGED_AGENTS"
      echo -e "${YEL}  AGENTS.md merge skipped${RST}"
    fi
  fi
fi

# ── 4. Ensure Ollama + tool-call proxy are running (opt-in via --ollama) ────
# Both are managed by `npm run ollama:serve` (concurrently: ollama-serve.sh +
# ollama-tool-call-proxy.mjs). Started once, left running across sessions —
# killing/restarting on every launch would reload the model from disk every
# single time, which is its own multi-second-to-minute tax.
#
# ponytail: Ollama is optional because the operator may run a cloud-only model
# (T-Systems, Claude, Gemini). Default skips the probe/start entirely; pass
# --ollama to auto-start. On failure, warn and continue so opencode still
# launches with whatever model opencode.json declares.
#
# port_up: returns success if *anything* answers, even a 4xx. The proxy 404s
# on GET/non-chat-completions requests, so `curl -f` would wrongly read that
# as "down" — only a connection failure (curl's synthetic 000) counts as down.
#
# ponytail: no `|| echo 000` fallback. curl already prints 000 on a refused
# connection AND exits non-zero, so the fallback appended a second 000 and the
# test compared "000000" != "000" — true. port_up therefore reported DOWN
# services as UP and --ollama silently started nothing while printing a green
# check. Acceptable today because -e is the only error indicator and 000 is the
# documented sentinel. Limitation: an empty response body yields "" and would
# also read as up. Upgrade path: if a real readiness endpoint appears, prefer
# its payload over the status code.
port_up() {
  local url="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url")" || return 1
  [ "$code" != "000" ]
}

if [ "$START_OLLAMA" -ne 1 ]; then
  echo -e "${YEL}  Ollama: skipped (pass --ollama to auto-start)${RST}"
else
  if ! port_up "http://localhost:11434/api/tags" || ! port_up "http://localhost:4198/"; then
    echo -e "${YEL}  Ollama and/or tool-call proxy not running — starting...${RST}"
    ( cd "$REPO_ROOT/open-code" && nohup npm run ollama:serve > "$REPO_ROOT/.ollama-serve.log" 2>&1 & )

    echo -n "  Waiting for services"
    READY=0
    for i in $(seq 1 30); do
      if port_up "http://localhost:11434/api/tags" && port_up "http://localhost:4198/"; then
        READY=1
        break
      fi
      echo -n "."
      sleep 1
    done
    echo ""

    if [ "$READY" -ne 1 ]; then
      echo -e "${YEL}  ! Ollama/proxy didn't come up within 30s — continuing anyway${RST}"
      echo -e "    Check: tail -f $REPO_ROOT/.ollama-serve.log"
    else
      echo -e "${GRN}✓ Ollama reachable${RST}"
      echo -e "${GRN}✓ Tool-call proxy reachable${RST}"
    fi
  else
    echo -e "${GRN}✓ Ollama reachable${RST}"
    echo -e "${GRN}✓ Tool-call proxy reachable${RST}"
  fi
fi

# ── 5. (Colibri intentionally omitted — not usable until 32 GB RAM) ───────

# ── 6. Launch ────────────────────────────────────────────────────────────
ACTUAL_MODEL="$(command -v jq >/dev/null 2>&1 && jq -r '.model // "unknown"' "$CONFIG_SRC" 2>/dev/null || echo "unknown")"
echo -e "${YEL}  Model : $ACTUAL_MODEL${RST}"
echo -e "${YEL}  Folder: $TARGET${RST}"
echo ""
cd "$TARGET" && exec "$LOCAL_BIN"
