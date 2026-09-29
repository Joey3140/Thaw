# HiddenMenuBar — Rules for Claude

<!-- HARNESS:BEGIN — managed by claude-harness, do not edit this block -->

Inherits all global rules from `~/.claude/CLAUDE.md` and `~/Harness Projects/CLAUDE.md` — MUST DO / MUST NOT / PREFER / agent rules live there. Only harness-project deltas below; duplicating global rules makes maintenance lossy.

## Project MUST DO

1. **Verify before committing** — this project has no test suite yet; exercise the change the way this file describes (build script, live check, or manual run).

## Project MUST NOT

1. **NEVER use worktree isolation (`isolation: "worktree"`)** — permanently banned. Worktree agents fork from stale bases and silently destroy feature work on merge.

## Project PREFER

1. **Assess blast radius before broad changes** — if a task touches 10+ files, consider breaking it up.
2. **Structural/architectural changes** — suggest new rules and wait for review before restructuring.

<!-- HARNESS:END -->

---

## Project-Specific Rules

<!-- Add your project-specific rules below. Everything above this line is managed by claude-harness. -->


