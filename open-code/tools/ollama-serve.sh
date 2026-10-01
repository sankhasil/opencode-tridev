#!/usr/bin/env bash
# Vendored from PersonalCodes/fotography_ai/opencode-ui, 2026-09-28. Unmodified otherwise.
#
# Start the local ollama daemon with a context window large enough for
# opencode's agent prompts (~15k tokens). The default 4096 context truncates
# the prompt, which makes models (gemma4, qwen2.5) drop their tool calls.
set -euo pipefail

# ponytail: 16384 covers the ~15k-token agent prompt on this 16 GB Mac.
# 32768 with the 9 GB qwen2.5-coder model exhausted RAM and caused runner
# hangs/eviction. Raise only on a larger machine.
exec env OLLAMA_CONTEXT_LENGTH=16384 ollama serve
