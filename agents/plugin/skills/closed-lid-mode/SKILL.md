---
name: closed-lid-mode
description: Continue authorized work on this Mac when its lid is closed or the user is driving the agent from a phone (ChatGPT Remote, Claude Remote Control, Antigravity remote control). Checks live LidRunner and Capture Guard readiness, recovers partial app captures, and preserves running tasks. Use when a host-state check or hook reports the lid closed, during remote desktop work, or when asked about lid-closed operation or LidRunner.
---

# Closed-lid mode

Treat a closed lid as host state, not a new task or a reason to stop. Continue the current authorized task. This skill gives no extra tool access, permissions, or authorization to send, publish, pay, delete, or alter security settings.

It works the same way in Codex/ChatGPT, Claude (Claude Code, Claude desktop) and Gemini (Antigravity). Paths below are relative to this skill's directory, the folder containing this `SKILL.md`.

## Read the live state

Run this short, read-only check when starting/resuming work on this Mac, before native desktop interactions, after a lid/display transition or capture failure, and at the next natural checkpoint after a long tool call:

```sh
/usr/bin/python3 "<absolute path to this skill's directory>/scripts/status.py"
```

A fresh lifecycle-hook notice ("LidRunner host observation: …") can satisfy the same check; avoid duplicate probes. `mode` is `closed`, `open`, `unknown`, or `unsupported_host`. Hardware state takes priority over fresh local diagnostics. Unknown is not open. On another host (a cloud sandbox, a remote agent, SSH), these local paths do not describe this Mac; use that host's available tools and do not assume access to this Mac.

`power_session_active` verifies fresh app and privileged-helper status with an unexpired deadline. `capture_guard_ready` verifies fresh companion status and its permission. `agent_apps_running` lists which agent apps (ChatGPT, Claude, Gemini, Antigravity) LidRunner sees running. None of these prove a usable screenshot, successful input, or a phone connection. Verify the actual action in the actual app. Do not inspect account databases or assume phone transport from a network-link indicator.

## Choose the working path

- Use the most direct available connector, CLI, filesystem, or browser interface for the task, just as with the lid open. Closed-lid mode does not require moving every task into desktop UI.
- For native app interaction, use the computer-use tool your host provides and its returned documentation: Codex's computer-use (CUA) tool, Claude's computer-use tools (for example `mcp__computer-use__*` or another connected app-control MCP), or Antigravity's available tools. Check current accessibility state before selecting controls. Do not substitute AppleScript, event synthesis, or a new remote-control server for a missing UI tool.
- Existing approval requirements still apply. Ask for physical interaction only when a specific observed OS authentication, Touch ID, or permission prompt cannot be completed remotely. Explain the exact blocker and continue independent work.

## Phone and remote access by agent

Each agent's own pairing and permissions manage access; LidRunner only keeps the Mac awake and the agent app running.

| Agent | Phone/remote path | Notes |
| --- | --- | --- |
| ChatGPT / Codex | ChatGPT → Remote on iPhone | Desktop control after locking needs ChatGPT → Settings → Computer Use → Locked use. Verified on the development host on 24 Sep 2026; verify separately on this host. |
| Claude | Claude Remote Control (Claude app on iPhone, or claude.ai/code) to a Claude Code session in the Claude desktop app or `claude` CLI | Requires that session to stay running; LidRunner can keep the Claude app open. Not yet physically verified with the lid closed. |
| Gemini / Antigravity | `agy remote-control start` (background daemon), or `agy --remote-control` for one CLI session | The daemon runs independently of the Antigravity app. Not yet physically verified with the lid closed. |

Prior results on this Mac do not prove another agent, app, or the current permission state works. Test the actual path.

## Partial, blank, stale, or displaced screenshots

Capture Guard automatically centers standard app windows that expose macOS's English **Window sharing** control while a LidRunner session is active and the lid is closed. A new sharing session, changed display geometry, or window size/position change can trigger a move after about two seconds of stable geometry. It skips the agent apps' own windows (ChatGPT, Claude, Gemini, Antigravity).

1. Get fresh app accessibility state and a screenshot. If capture just started or moved, let the recovery settle and obtain a fresh observation. Discard earlier screen coordinates and stale element indexes.
2. If the image remains partial, check status once. In the affected app, use its observed **Window → Center** command if available, then capture again. This recovery was verified in Calculator; inspect whether another app actually supports it.
3. Verify the screenshot contains the needed controls. Prefer accessible controls to guessing coordinates in missing image regions. After an action, confirm the intended change with fresh state; a tool timeout may still have performed the action. Never blindly repeat a consequential action.
4. Bound recovery to two attempts. If full capture still fails, continue through an available structured interface or report the exact blocked UI step. Do not restart the agent app, WindowServer, or the Mac, change locking, or install a display driver just to force a screenshot.

The helper may re-center a window after moving or resizing it; avoid fighting it with repeated drags. It skips hidden apps, fullscreen/minimized/nonstandard windows, and unrecognized sharing chrome. Oversized windows are not resized. A fresh image remains necessary even if its repair counter increases.

## Preserve the working session

- **⌘⌥⌃⇧L toggles LidRunner on/off.** Do not press it speculatively: it can stop all running closed-lid work, for every agent at once. Other global shortcuts depend on the host's configuration. Start a new power session only when needed and within the user's request; inspect current state first.
- Keep the existing eight-hour bound, battery cutoff at 15%, thermal protection, and heartbeat recovery. Do not silently extend a session or remove cutoffs. If status reports battery near cutoff or session expiry, tell the user when that materially threatens ongoing work.
- Keep LidRunner, Capture Guard and the agent app you are running in (and any other agent the user has working) running during active closed-lid work. Refreshing instructions, installing a skill, or updating a plugin does not require restarting them.
- Once the lid opens, resume normal operation and refresh UI state because window geometry may change again. Do not end the power session merely because the lid opened.

## Local components and further diagnosis

Read only as needed:

- App: `~/Applications/LidRunner.app`
- Capture companion: `~/Applications/LidRunner Capture Guard.app`
- State files: `~/Library/Application Support/LidRunner/diagnostics.json` and `capture-guard.json`
- Power helper state: `/Library/Application Support/LidRunner/status.json`
- Source and verified limits: `README.md`, `CAPTURE-GUARD.md`, and `agents/README.md` in the user's LidRunner source checkout. Do not assume its location. Machine-local `evidence/` logs are not included in the public repository.

The lifecycle hook (`scripts/hook.py`) adds brief state notices at session/turn start and tool boundaries, suppressing unchanged notices. It only reads host state and writes a small per-session cache (hashed session id plus state fingerprint). It never modifies tool arguments or approval decisions. Codex requires its normal `/hooks` trust review; the Claude Code plugin and Antigravity plugin load hooks when the plugin is enabled. Neither hooks nor this skill wake an idle conversation or guarantee immediate awareness in an already-running model request.
