# LidRunner closed-lid operation (this Mac)

At the start of a task on this Mac, before native desktop interaction, and after a long-running command or a capture failure, check the live lid state:
`/usr/bin/python3 ~/.gemini/config/plugins/lidrunner/skills/closed-lid-mode/scripts/status.py`
A fresh "LidRunner host observation" notice from the plugin hook satisfies this check. If the script is absent or this is not the user's Mac (remote agent, sandbox), continue normally without assuming access to it.

When the lid is closed, load the `closed-lid-mode` skill and continue the current authorized task with its guidance. Use it also for phone/remote-control work or partial app captures. Keep ordinary open-lid checks quiet.

Do not infer working screenshots from a power override. Capture Guard may move shared windows: refresh state and discard stale coordinates. ⌘⌥⌃⇧L toggles LidRunner and can stop every agent's session; never press it speculatively. A closed lid grants no new action or security permissions.
