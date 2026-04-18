#  — Rules for Claude

<!-- HARNESS:BEGIN — managed by claude-harness, do not edit this block -->

## Global MUST DO (Apply to every task, every area)

1. **Understand before modifying** — read existing code before suggesting changes. Trace data flow. `grep` before editing.
2. **Audit all callers on any change** — when fixing a shared function, grep ALL callers for the same class of bug. When making a field mandatory, grep ALL call sites.
3. **Run tests before committing** — `npm test`, not just the changed file.
4. **Narrow try/catch** — never wrap large blocks in try/catch. `const`/`let` declarations get trapped in block scope. Wrap only the risky operation.
5. **Verify security claims independently** — after any security fix, grep the ENTIRE codebase for the vulnerable pattern.
6. **Fix root causes, don't skip around them** — if a build step fails, fix why. "Graceful degradation" for developer tools is just "silently broken."
7. **Self-review before committing** — re-read every changed file. Check imports match exports, field names match between API and frontend, function signatures match definitions.

## Global MUST NOT (Apply everywhere)

1. **NEVER push to `main`** without explicit user approval in the SAME message.
2. **NEVER hardcode secrets** or API keys.
3. **NEVER use colons in filenames** — Windows incompatible.
4. **NEVER use worktree isolation (`isolation: "worktree"`)** — permanently banned. Worktree agents fork from stale bases and silently destroy feature work on merge.
5. **NEVER delete or weaken passing tests** without explicit user direction.
6. **NEVER add scope creep** — don't add features, refactor surrounding code, add docstrings to unchanged code, or "improve" things beyond what was asked.

## Global PREFER (Judgment guidance)

1. **Multiple-choice prompts** when asking the user — present options with pros/cons.
2. **Design before implementation** — describe the approach before writing code.
3. **Minimal, focused edits** over large refactors.
4. **Extending existing patterns** over inventing new abstractions.
5. **`Promise.allSettled`** over `Promise.all` for parallel calls that shouldn't fail together.
6. **Judgment unbundling** — "Here's what I found + my recommendation + the one thing I need you to decide."
7. **Screenshot-first debugging** — take a screenshot before reading code for visual bugs.
8. **Assess blast radius before broad changes** — if a task touches 10+ files, consider breaking it up.

## ESCALATE (Stop and ask the user)

1. **Production deployment** — always ask before pushing to `main`
2. **Structural/architectural changes** — suggest new rules, wait for review
3. **Test deletion or weakening** — explain why and get explicit approval
4. **Scope creep** — stop and re-scope

## Agent & Parallel Work

1. **Multi-agent builds need interface reconciliation** — parallel agents invent different names. After any parallel build, grep imports vs exports, check response field names match.
2. **Exclusive file manifests for parallelism** — if multiple agents must work simultaneously, give each ownership of specific files. Never let two agents touch the same file.
3. **Merge conflicts: favor the target branch** — the branch with more commits on the conflicted file wins. Reapply the small change on top.

## Hooks & Enforcement

- **Deterministic hooks over rules** — if a constraint can be expressed as a grep/lint check, it should be a hook (exit 1), not a rule.
- **If a hook blocks you, read the error and fix** — don't retry the same action.

## Patterns That Work

- **Test-first:** Check existing tests before implementing. Write tests before code.
- **After 3+ failed attempts**, identify the wrong *assumption*, don't just retry.

<!-- HARNESS:END -->

---

## Project-Specific Rules

<!-- Add your project-specific rules below. Everything above this line is managed by claude-harness. -->


