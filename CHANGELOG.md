# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- English interface. It is the default; Russian stays when Russian is the system's first language. `AGENT_NOTCH_LANG=en|ru` overrides it.
- README and promo screenshots are now in English.

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

[0.1.0]: https://github.com/Forichok/Agent-Notch/releases/tag/v0.1.0
