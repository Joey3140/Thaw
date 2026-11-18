# HiddenMenuBar — Rules for Claude

<!-- HARNESS:BEGIN — managed by claude-harness, do not edit this block -->

Inherits every rule in `~/.claude/CLAUDE.md` and `~/claude-projects/CLAUDE.md`. Only project deltas go below; duplicating global rules makes maintenance lossy.

## Project MUST DO

1. **Verify before committing** — no test command is configured (harness-config.json `testCommand` is blank); exercise the change the way this file describes (build script, live check, or manual run).

## Project PREFER

1. **Assess blast radius before broad changes** — if a task touches 10+ files, consider breaking it up.
2. **Structural/architectural changes** — suggest new rules and wait for review before restructuring.

<!-- HARNESS:END -->


## Tests (2.1.0)

- Upstream 2.1.0 ships `ThawTests/` (Swift unit tests). They are deliberately NOT the harness test command (Joey, 2026-11-13): they touch the real Thaw settings and the live menu bar. Run them on purpose, with Thaw quit, when a change touches what they cover; `./build.sh` (notarize + install + relaunch) stays the verify step.
- First launch of a new major version shows a "Welcome to Thaw" / Get Started screen, and the menu bar icon appears only after it (2.1.0 on 2026-11-13). If the icon is missing after an install, `open -a /Applications/Thaw.app` brings that window up.

---

## Project-Specific Rules

<!-- Add your project-specific rules below. Everything above this line is managed by claude-harness. -->


