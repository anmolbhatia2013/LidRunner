# LidRunner agent integration

One skill, one hook script, three agents. Source of truth for everything an AI agent needs to keep working on this Mac with the lid closed or from a phone.

| Agent | How it's installed | Hooks | Always-on fallback |
| --- | --- | --- | --- |
| ChatGPT / Codex | User skill `~/.codex/skills/closed-lid-mode` | `~/.codex/hooks.json`: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse (trusted via `/hooks`) | Marked section in `~/.codex/AGENTS.md` |
| Claude (Claude Code, Claude desktop Code tab) | Plugin `lidrunner@lidrunner-local` from the marketplace in this folder | `plugin/hooks/hooks.json`: SessionStart, UserPromptSubmit, PostToolUse | Not needed; plugin hooks always load |
| Gemini (Antigravity: `agy`, Antigravity app/IDE) | Plugin `lidrunner` in `~/.gemini/config/plugins/` | `plugin/hooks.json`: PreInvocation (ephemeral, once per turn plus on change) | `plugin/rules/AGENTS.md` |

`plugin/` is a single directory that is both a Claude Code plugin (`.claude-plugin/plugin.json`, `hooks/hooks.json`) and an Antigravity plugin (`plugin.json`, `hooks.json`, `rules/`). Each tool ignores the other's files; `agy plugin validate` warns that `hooks/hooks.json` isn't read, which is expected.

## Install

From the repository root:

```sh
./agents/install.sh
# Or select only the integration you want:
./agents/install.sh codex
./agents/install.sh claude
./agents/install.sh antigravity
```

The installer runs local tests first, then updates user-level integrations for the selected installed tools. Back up any customized `~/.codex/skills/closed-lid-mode` directory before running it: the Codex step replaces that directory. It does not start a power session or restart a running agent.

**Codex first-install limit:** the installer installs the skill only. It preserves existing `~/.codex/hooks.json` and `~/.codex/AGENTS.md` files and does not create automatic hooks or a fallback section on a new setup. Invoke the `closed-lid-mode` skill explicitly unless you have separately configured its hook script using your Codex version's supported hook setup and approved it through `/hooks`. The table above describes the fully configured development setup, not a promise that all Codex hooks are installed automatically.

## Layout

- `plugin/skills/closed-lid-mode/SKILL.md`: agent-neutral skill (Codex also reads `agents/openai.yaml`).
- `plugin/skills/closed-lid-mode/scripts/status.py`: read-only lid/power/Capture Guard/agent-app status.
- `plugin/skills/closed-lid-mode/scripts/hook.py`: lifecycle hook. `--host codex` (default), `--host claude`, or `--host antigravity --event PreInvocation`.
- `.claude-plugin/marketplace.json`: local Claude Code marketplace `lidrunner-local`.
- `tests/test_closed_lid_skill.py`: 66 tests across status, simulation, cache pruning, Codex, Claude, Antigravity and CLI paths. Set `LIDRUNNER_SKILL_SCRIPTS` to test an installed copy.
- `install.sh [codex] [claude] [antigravity]`: run the tests, then install or refresh.
- `plugin/assets/icon.png`: plugin icon for both Claude Code and Antigravity.

**After editing anything in `plugin/`, bump `version` in both `plugin/.claude-plugin/plugin.json` and `plugin/plugin.json`, then run `install.sh`.** Claude Code keeps a cached copy per version under `~/.claude/plugins/cache/lidrunner-local/` and won't pick up changes otherwise.

## Testing with the lid open

`LIDRUNNER_SIMULATE_LID=closed` (or `open`) makes `status.py` and the hook report a fake state, always prefixed `[SIMULATED TEST STATE, not the real lid]` and marked `"simulated": true`. Any other value is ignored.

`./e2e.sh [codex] [claude] [antigravity]` runs one small model request per agent under the simulation and prints PASS (the model quoted the notice), HOOK (the notice was delivered but no model reply) or FAIL. Logs go to `../evidence/e2e-<timestamp>/`. Results on 6 Nov 2026:
- Antigravity: **PASS**. The model quoted the notice and planned to load the skill, refresh screenshots, avoid the shortcut, and watch the battery.
- Claude Code: **HOOK**. The debug log showed context parsed at SessionStart and UserPromptSubmit. A model response was not verified.
- Codex: **HOOK**. Trusted SessionStart and UserPromptSubmit hooks ran and recorded the simulated closed state. A model response was not verified.

This script is an opt-in live integration test, not a unit test: it makes authenticated model requests, can consume usage allowance, clears the Codex hook cache, and writes local diagnostic logs. Evidence logs are not published.

## Hook behaviour

The hook reads host state only. It never approves, denies or rewrites a tool call; for Antigravity it registers no `PreToolUse` hook because that event requires a decision. It caches a hashed session id, a state fingerprint and (Antigravity only) the integer turn marker under `~/Library/Caches/LidRunner/<host>-hooks/`. It never stores prompts, tool input, transcripts or paths. State for sessions idle longer than a day is deleted (checked at most hourly), so the cache stays small even with hundreds of headless sessions a day; a forgotten session simply behaves like a new one. Open-lid sessions stay quiet; a closed lid is announced at session/turn start and on any state change.

## Remove

- Claude Code: `claude plugin uninstall lidrunner@lidrunner-local` and `claude plugin marketplace remove lidrunner-local`.
- Antigravity: `agy plugin uninstall lidrunner`.
- Codex: remove only the `~/.codex/skills/closed-lid-mode` directory after backing up any customizations. If you separately configured LidRunner hooks or an `AGENTS.md` section, remove those entries only, preserving unrelated hooks and instructions; review hook trust through `/hooks`.

None of these stop LidRunner or Capture Guard.
