# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Prompts and skills on ⌃⌥P: a search box under the notch over any app. ↩ pastes a saved prompt where the cursor is (through the clipboard, which is put back), ⌘↩ copies, ⌘1–9 picks by row; most used lately first. ⇥ switches to installed skills of Claude Code and Codex and pastes their call.
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
- Answers from the notch through hooks: Allow, Deny, Always and hand-back for permission requests, with ⌃⌥Y / ⌃⌥N; buttons and free text for `AskUserQuestion`; accept or return a plan. Risky commands need a click.
- Agent card with done, remaining, files and log tabs.
- Plan limits for Claude and Codex, a context ring per agent, approximate session cost and today's spend.
- Click or double-click to jump back to the chat in the Claude or Codex app, or resume in Terminal.
- Finish toast, settings with presets, launch at login.
- Homebrew cask, DMG and zip downloads.

[0.4.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.4.0
[0.3.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.3.0
[0.2.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.2.0
[0.1.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.1.0
