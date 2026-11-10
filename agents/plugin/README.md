# LidRunner agent plugin

Read-only closed-lid and phone-remote awareness for LidRunner on macOS. This directory is a Claude Code plugin and an Antigravity plugin; its shared skill can also be installed for Codex.

The plugin reports host state and provides screenshot-recovery guidance. It does not install the LidRunner power helper, start a power session, grant permissions, or provide remote access.

## Install and test

See the [repository integration guide](https://github.com/anmolbhatia2013/LidRunner/blob/main/agents/README.md) for complete installation, Codex first-install limitations, tests, and removal instructions. From a source checkout, run `./agents/install.sh` to install integrations for available tools, or pass `codex`, `claude`, or `antigravity` to select one.

The Codex installer replaces the same-named user skill; back up customizations first. It does not configure Codex hooks on a fresh setup. Claude Code uses the local marketplace `lidrunner-local`; Antigravity installs the plugin as `lidrunner`.

## Package layout

- `skills/closed-lid-mode/SKILL.md`: shared agent guidance.
- `skills/closed-lid-mode/scripts/status.py`: read-only lid, power, Capture Guard, and agent-app status.
- `skills/closed-lid-mode/scripts/hook.py`: host-specific lifecycle notices.
- `.claude-plugin/plugin.json` and `hooks/hooks.json`: Claude Code plugin metadata and hooks.
- `plugin.json`, `hooks.json`, and `rules/AGENTS.md`: Antigravity metadata, hook, and fallback rule.
- `assets/icon.png`: plugin icon.

## Privacy and scope

The hook never approves, denies, or rewrites a tool call. It caches a hashed session identifier and host-state fingerprint under `~/Library/Caches/LidRunner/`; it does not store prompts, tool input, transcripts, or document contents. Closed-lid state grants no additional permissions.

`LIDRUNNER_SIMULATE_LID=closed` or `open` enables clearly labeled test state. Simulation is not evidence of physical closed-lid operation. Local unit tests and opt-in live integration tests live in the parent repository, not this standalone plugin package.

## Updating

When changing plugin content, bump `version` in both `.claude-plugin/plugin.json` and `plugin.json`, then use the repository installer to refresh the cached integration. Existing sessions may continue using their previously loaded version. Updating source alone does not update installed plugins.

## Remove

- Claude Code: `claude plugin uninstall lidrunner@lidrunner-local`, then `claude plugin marketplace remove lidrunner-local`.
- Antigravity: `agy plugin uninstall lidrunner`.
- Codex: remove only the installed `closed-lid-mode` skill after backing up customizations. If separately configured, remove only LidRunner's hook entries and fallback instructions, preserving unrelated configuration.

Removing an integration does not stop LidRunner or Capture Guard.
