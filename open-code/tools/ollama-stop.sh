#!/usr/bin/env bash
# Vendored from PersonalCodes/fotography_ai/opencode-ui, 2026-09-28. Unmodified otherwise.
#
# Stop the local ollama daemon started via tools/ollama-serve.sh.
# SIGTERM lets ollama unload runners before exiting.
set -euo pipefail

if pkill -x ollama; then
  echo "ollama stopped"
else
  echo "ollama not running"
fi
