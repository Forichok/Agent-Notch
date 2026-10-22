# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Agents' house on the desktop: an optional animated pixel wallpaper where every project is a room and every agent walks around in it. Click or pinch to fly to a room, Esc goes back to the overview. Off by default; turn it on in Settings → Desktop house. Nothing is drawn while the desktop is covered, and fewer frames are drawn on battery and in Low Power Mode.
- Agents' house as a screen saver, Agent Notch House: the same live house while the Mac is idle, and on the lock screen with "Require password immediately". Install it from Settings → Desktop house or by double-clicking the `.saver`; releases ship it as `AgentNotchHouse-<version>.saver.zip` and inside the DMG.
- In the agents' house a finished agent takes a real shower (about 20 seconds behind fogged glass, then a towel) instead of turning around at the door. Codex agents are a blue cloud-headed robot, or your own Codex pet when `~/.codex/pets` has one. A dog lives in a kennel in the wider yard: it sleeps there at night, walks a finished agent to the shower, fetches a ball and barks at fires; the cat's house is now on the roof. Project rooms get beanbags, armchairs, a sofa and floor cushions where agents work on a laptop when the desks are taken. The roof tanks say which limit window they show (5 hours or a week), Codex's is named CODEX, and hovering a tank lists every window with its reset time.

## [0.6.0] - 2026-10-16

### Added

- Claude and Codex each get their own icon in Settings → Appearance: Auto, a built-in style, or any SF Symbol found by search. A chosen icon stays the same under every theme (#28).
- Codex CLI sessions open in their own Terminal or iTerm2 tab, like Claude sessions. When only the project folder could be opened, a toast says so and offers "Copy resume command"; the command is copied, never run (#29).
- The done toast shows unfinished plan items ("2 of 7 left") and the commit made by that session, not the repository HEAD (#30).

### Changed

- Logs are followed through file-system events instead of a 1.5 s disk poll, with a full rescan every 30 s as a safety net. With 200 live sessions and 10,000 archived logs: idle CPU 2.08% → 0.51% of one core, update latency p95 1448 → 291 ms, memory 37 MB (#31).

### Fixed

- An agent that waits for its background helpers shows "working · waiting for N helpers" instead of "waiting for you" or "done" (#30).
- Silence no longer counts as done. A session that exits without finishing its turn is marked interrupted and gets no success toast (#30).
- If the terminal tab cannot be selected (for example, Automation is denied), the terminal is still brought forward instead of opening Claude Desktop or the folder (#29).

## [0.5.0] - 2026-10-15

The app code is the same as in 0.4.1, which was built after these changes landed. This release names them.

### Added

- Answer delivery is confirmed. A notch answer counts as delivered only after the hook passes it to the agent and reports back. Otherwise the row turns red with "delivery unconfirmed", "Open terminal" and "Dismiss". If the agent stops waiting before you answer (Esc, Ctrl-C, its own timeout), the row clears quietly. The countdown appears only in the last 30 seconds (#22).
- Settings show where a connection stops, per agent: config written, helper alive, first hook received, Codex waiting for trust in `/hooks`. "Test request" checks the path end to end without creating an approvable prompt. `notch-hook doctor` prints the same states (#25).
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are respected for hooks, sessions, skills and logs. Hooks installed under a custom folder are removed even when the variable is no longer set (#24).
- Codex workers started from a Claude chat sit under that chat (#19).

### Fixed

- Resumed or old Codex sessions are found again: discovery follows file changes, not folder dates (#17).
- Uninstalling cleans both agents even if one config cannot be read, and never rewrites a config with comments (#18).
- README matches what the app does: questions, plans and "Always allow" are Claude Code only (#16).

## [0.4.1] - 2026-10-15

### Added

- In-app updates from a menu/settings button, with signed downloads and installation after confirmation. No background checks. Releases can be prepared locally without GitHub Actions.
- Prompts and skills on ⌃⌥P: a search box under the notch over any app. ↩ pastes a saved prompt where the cursor is (through the clipboard, restored by default after a delay if unchanged), ⌘↩ copies, ⌘1–9 picks by row; most used lately first. ⇥ switches to installed skills of Claude Code and Codex and pastes their call.
- Settings → Prompts & skills: the prompt library, insertion statistics (totals, last 14 days, most used) and a Skills tab with each skill's description, front matter, files, SKILL.md and how often Claude Code called it.

### Fixed

- Accessibility access survives app updates and rebuilds: the ad-hoc signature now requires the bundle id instead of its own hash.

## [0.4.0] - 2026-10-14

### Added

- Keep awake switch at the top right of the agent list, with a highlighted On state and explicit On/Off labels. It controls macOS sleep prevention, including when the lid is closed; the mode stays on after quitting the app until switched off.
- Optional passwordless switching in Settings → General → Keep awake. One administrator confirmation grants only `pmset disablesleep 0` and `pmset disablesleep 1` for the current user. Settings can check and remove the permission; both READMEs cover setup and removal.
- Prompts card tab with the first user prompt and later prompts, newest first (#4).
- Sound presets and a library for importing and selecting custom sounds (#5, #7).
- Original Claude and OpenAI glyphs for logo marks when the desktop app is missing (#3).

### Fixed

- Codex cards show commands, web searches and errors in Log (#8).
- Confirmed Codex automatic reviews stay in Codex rather than reopening as permission requests (#6).
- Sleep-mode changes wait for system confirmation before reporting failure. The switch keeps showing the state read from macOS.
- Passwordless setup rejects inaccessible sudoers directories so the installed rule remains discoverable for removal in Settings.
- Builds check for the Prompts tab before producing an app and record their source revision.
- CI runs on the renamed default branch, master (#3).

## [0.3.0] - 2026-10-13

### Added

- Thirteen list themes: Terminal, Liquid Glass, Paper, Midnight, Console, Phosphor, Synthwave, Blueprint, Brutalism, Hologram, Wasteland, Pixel and Rubber Ducks. Every theme except Terminal can also restyle the marks in the wing.
- A sound for each event, set in Settings → Sounds, with a volume slider and preview. Only "waiting for permission" makes a sound until you change it.
- README and promo screenshots are in English.

## [0.2.0] - 2026-10-13

### Added

- English interface. It is the default; Russian is used when Russian is the first system language. `AGENT_NOTCH_LANG=en` or `ru` picks one by hand.

### Fixed

- `brew uninstall --zap agent-notch` now removes the Claude Code and Codex hooks before deleting the app's support folder (#1).

## [0.1.0] - 2026-10-13

First public release.

### Added

- The wing beside the notch: one mark per Claude Code or Codex agent, with vendor, model weight and state; subagents next to their parent; counters past six agents; one-line summary when the menu bar is crowded; menu bar item on Macs without a notch.
- The list: projects, sessions and subagent trees, the current tool of each agent, a "needs attention" block on top.
- Answers from the notch through hooks: Allow, Deny and hand-back for Claude Code and Codex permission requests, with ⌃⌥Y / ⌃⌥N. Claude Code also supports Always rules, buttons and free text for `AskUserQuestion`, and accepting or returning a plan. Risky commands need a click.
- Agent card with done, remaining, files and log tabs.
- Plan limits for Claude and Codex, a context ring per agent, approximate session cost and today's spend.
- Click a row to open its card; double-click to try the recorded app or terminal, with a project-folder fallback.
- Finish toast, settings with presets, launch at login.
- Homebrew cask, DMG and zip downloads.

[0.4.1]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.4.1
[0.4.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.4.0
[0.3.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.3.0
[0.2.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.2.0
[0.1.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.1.0
