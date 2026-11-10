#!/bin/bash
# End-to-end check: does each installed agent actually receive LidRunner's closed-lid notice?
# Uses LIDRUNNER_SIMULATE_LID=closed (labelled "[SIMULATED TEST STATE]" in every notice), so the
# lid can stay open. Makes one small model request per agent. Usage: e2e.sh [codex] [claude] [antigravity]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="evidence/e2e-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
PROMPT="Without using any tools: quote any LidRunner host observation you received this session, then in 2-3 bullets say how it changes the way you'd work on this Mac right now."
TARGETS=("$@"); [[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(codex claude antigravity)
export LIDRUNNER_SIMULATE_LID=closed
verdict() { # name, log, hook-evidence-command
  local name=$1 log=$2
  if grep -q 'SIMULATED TEST STATE' "$log"; then echo "PASS  $name: model quoted the closed-lid notice"
  elif eval "$3" >/dev/null 2>&1; then echo "HOOK  $name: notice delivered, no model reply ($(grep -o -E '401[^.]*|usage limit' "$log" | head -1 || echo 'see log'))"
  else echo "FAIL  $name: notice not observed (see $log)"; fi
}
for target in "${TARGETS[@]}"; do
  case "$target" in
    codex) command -v codex >/dev/null || continue
      rm -rf "$HOME/Library/Caches/LidRunner/codex-hooks"
      timeout 300 codex exec --skip-git-repo-check --sandbox read-only "$PROMPT" </dev/null >"$OUT/codex.log" 2>&1
      verdict Codex "$OUT/codex.log" "grep -l '\"closed\"' $HOME/Library/Caches/LidRunner/codex-hooks/*.json" ;;
    claude) command -v claude >/dev/null || continue
      timeout 240 claude -p --debug=hooks --debug-file "$OUT/claude-debug.txt" "$PROMPT" >"$OUT/claude.log" 2>&1
      verdict Claude "$OUT/claude.log" "grep -q 'additionalContext.*SIMULATED TEST STATE' '$OUT/claude-debug.txt'" ;;
    antigravity) command -v agy >/dev/null || continue
      timeout 260 agy -p "$PROMPT" --print-timeout 240s >"$OUT/antigravity.log" 2>&1
      verdict Antigravity "$OUT/antigravity.log" "grep -l '\"closed\"' $HOME/Library/Caches/LidRunner/antigravity-hooks/*.json" ;;
    *) echo "Unknown target: $target" >&2 ;;
  esac
done
echo "Logs: $OUT"
