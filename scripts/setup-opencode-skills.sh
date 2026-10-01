#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
BLD='\033[1m'
RST='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_NAME="redesign-existing-projects"
CONFIG="$REPO_ROOT/opencode.json"
# ponytail: single in-tree skill dir, relative path in config so a fresh clone works.
# superpowers/ is excluded on purpose — it arrives via the plugin entry in opencode.json.
SKILLS_PATH=".opencode/skills"
SKILL_DIR="$REPO_ROOT/$SKILLS_PATH"

# ── 1. Install taste-skill if missing ────────────────────────────────────────
if [ -d "$SKILL_DIR/$SKILL_NAME" ]; then
  echo -e "${GRN}✓ Taste-skill ($SKILL_NAME) already installed${RST}  ($SKILL_DIR/$SKILL_NAME)"
else
  echo -e "${BLD}◈ Installing Taste Skill ($SKILL_NAME) ...${RST}"
  ( cd "$REPO_ROOT" && npx --yes skills add Leonxlnx/taste-skill \
    --skill "$SKILL_NAME" -a opencode -y --copy )
  if [ -d "$SKILL_DIR/$SKILL_NAME" ]; then
    echo -e "${GRN}✓ Installed $SKILL_NAME${RST}"
  else
    echo -e "${RED}✗ Install failed — check the output above${RST}"
    exit 1
  fi
fi

# ── 2. Ensure opencode.json registers the single skill dir (idempotent) ───────
if [ ! -f "$CONFIG" ]; then
  echo -e "${YEL}  No opencode.json found — skipping config patch (run scripts/opencode.sh first)${RST}"
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  if jq -e --arg p "$SKILLS_PATH" '.skills.paths == [$p]' "$CONFIG" >/dev/null 2>&1; then
    echo -e "${GRN}✓ opencode.json skills.paths already configured${RST}"
  else
    TMP=$(mktemp)
    jq --arg p "$SKILLS_PATH" '.skills.paths = [$p]' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
    echo -e "${GRN}✓ opencode.json skills.paths updated${RST}"
  fi
else
  echo -e "${YEL}  jq not found — ensure opencode.json skills.paths contains:${RST}"
  echo "    $SKILLS_PATH"
fi

echo -e "\n${GRN}✓ OpenCode skills ready${RST}"
