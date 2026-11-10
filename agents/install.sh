#!/bin/bash
# Install or refresh LidRunner's agent integration for Codex, Claude Code and Antigravity (Gemini).
# Safe to re-run. Pass any of: codex claude antigravity (default: all that are installed).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
TARGETS=("$@"); [[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(codex claude antigravity)
find plugin -name __pycache__ -prune -exec rm -rf {} +
/usr/bin/python3 tests/test_closed_lid_skill.py >/dev/null 2>&1 || { echo "Skill tests failed; run tests/test_closed_lid_skill.py" >&2; exit 1; }
for target in "${TARGETS[@]}"; do
  case "$target" in
    codex)
      # User-scope skill; ~/.codex/hooks.json and the AGENTS.md section keep their existing commands/paths,
      # so previously granted hook trust is preserved.
      if [[ -d "$HOME/.codex" ]]; then
        mkdir -p "$HOME/.codex/skills"
        rm -rf "$HOME/.codex/skills/closed-lid-mode.new"
        cp -R plugin/skills/closed-lid-mode "$HOME/.codex/skills/closed-lid-mode.new"
        rm -rf "$HOME/.codex/skills/closed-lid-mode"
        mv "$HOME/.codex/skills/closed-lid-mode.new" "$HOME/.codex/skills/closed-lid-mode"
        echo "Codex: skill installed at ~/.codex/skills/closed-lid-mode"
      fi ;;
    claude)
      if command -v claude >/dev/null; then
        # Claude Code caches a copy per plugin version: bump plugin/.claude-plugin/plugin.json "version" when
        # content changes, then update. A plain re-install of an installed plugin does not refresh the cache.
        claude plugin marketplace add "$HERE" >/dev/null 2>&1 || true
        claude plugin marketplace update lidrunner-local
        if claude plugin list 2>/dev/null | grep -q 'lidrunner@lidrunner-local'; then
          claude plugin update lidrunner@lidrunner-local --scope user
        else
          claude plugin install lidrunner@lidrunner-local --scope user
        fi
        echo "Claude Code: plugin lidrunner@lidrunner-local installed (new sessions pick it up)"
      fi ;;
    antigravity)
      if command -v agy >/dev/null; then
        agy plugin validate plugin
        agy plugin install "$HERE/plugin"
        echo "Antigravity: plugin installed at ~/.gemini/config/plugins/lidrunner"
      fi ;;
    *) echo "Unknown target: $target" >&2; exit 2 ;;
  esac
done
