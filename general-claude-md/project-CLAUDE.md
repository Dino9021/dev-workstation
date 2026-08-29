<!-- DESTINATION: <repo>/CLAUDE.md  (project scope). This template holds ONLY project
     facts. The universal rules load from user scope (~/.claude/CLAUDE.md) in every
     session and are deliberately NOT restated here — one live copy per rule.

     Adopting: grep -n "FILL:" this file; settle every slot; DELETE every section your
     project does not have (a section kept "just in case" is a rule nobody can obey).
     Then delete this comment. HTML comments cost no context — they are stripped before
     injection — so unfilled slots are invisible to the agent, which is exactly why an
     unfilled slot binds nothing. -->

# CLAUDE.md — <!-- FILL: project name -->

The universal rules (git, dispatch, ADR, searching, quoting, verification) load from this
machine's user-scope `~/.claude/CLAUDE.md` before this file. **This file adds only what is
true of THIS project — and it is the one instruction file agents may add to.** When told to
record a new project instruction, append it here or under `.claude/rules/`; never edit the
user-scope file, and never restate a rule that already lives there.

Incidents behind this project's rules go to <!-- FILL: rule-history path, e.g.
`docs/RULE-HISTORY.md` — create it empty; keep it off every required-read list -->.

## Mission

<!-- FILL: one paragraph — what this system is, who runs it, and the top priorities an
     agent must protect. -->

## Stage

<!-- FILL: e.g. "DEVELOPMENT — nothing is deployed; wiping and rebuilding is always
     acceptable; do NOT add backward-compatibility shims or data migrations." Name the ONE
     thing the stage marker governs and state that nothing else keys off it; only the
     owner flips it. -->

## Layout

<!-- FILL: each component's top-level directory and what it owns (code, deploy,
     migrations, docs). State whether components must build from a sparse clone of their
     own path. Name any DEAD directory names so stale references read as drift. -->

## Schema maintenance

<!-- FILL: the files that must be updated with every schema change so the database can be
     wiped and rebuilt — or delete this section if there is no database. -->

## Non-negotiable constraints

<!-- FILL: "Do not ..." lines that hold regardless of the task. Keep the list short
     enough to actually be read. -->

## Owner approval categories

The ADR process (user scope) requires owner approval for these standing categories, and
the ADR review never replaces that approval:

<!-- FILL: e.g. privilege boundaries · audit guarantees and audit-record behaviour ·
     database schema · command-execution boundaries. -->

## Accepted-by-design residuals — do not re-flag

<!-- FILL: findings reviewers will keep rediscovering, each with why it is accepted.
     Without this list, every review round re-reports them. -->

## Required read order for every new session

1. <!-- FILL: this project's orientation documents, in order. Keep the list SHORT —
     every session pays for it. Conditional items must say WHEN they become mandatory. -->
2. The mandatory reads the user-scope rules already define — the verification doc
   (`~/.claude/docs/VERIFICATION-LESSONS.md`) and both `dispatch-guard` skills — at the
   triggers stated there.

Do not read the full documentation tree unless the active task explicitly names a
document.

## Source of truth hierarchy

1. **Existing code**<!-- FILL: name the code roots --> plus its migrations. Nothing
   outranks it.
2. The current task's own file<!-- FILL: where task files live -->.
3. Decision records (why) and the current-state record (what shipped)<!-- FILL: paths -->.
4. Specifications — review snapshots; they go stale.
5. Pre-implementation designs — every claim unconfirmed until `git grep` finds it.

On conflict the code wins: report the divergence and banner the document in place. Do not
change code to match a document, and do not delete the document's wrong text — a silent
rewrite destroys the evidence the next reader needs.

## Project memory

- First thing every session: read <!-- FILL: memory index path, e.g. `Memory/MEMORY.md` -->,
  then individual memory files as needed. Write new memory there — not into user-level
  memory no teammate can see.
- <!-- FILL: is the memory folder tracked and pushed? If yes: commit+push IS the backup;
  never write credentials or machine identifiers into it. -->

## Task folders

<!-- FILL: where dispatch task folders live (the dispatch-guard default is an auto-probe
     that settles on `<repo>/Memory/tasks/`), whether they are committed, and any capture
     rules for external model runs. ⚠ Naming a different location here is not enough — set
     `dispatch.task_root` in the plugin config too, or the gate will reject dispatches
     that use it. Delete this section if the plugin default is used unchanged. -->

## Language policy

<!-- FILL: (or delete) the original owner's policy: interact in Traditional Chinese
     (Taiwan terminology), never Simplified; all repository documents English-only, no
     bilingual copies in any agent-read path; Chinese for the owner is produced in
     conversation, not stored; identifiers and code names stay untranslated. -->

## Machine boundaries

<!-- FILL: (or delete) if building and real testing happen on different machines, name
     both and forbid the crossover (never elevate / install / treat the build box as a
     test target — and say what IS normal there, so the boundary does not read as "do
     nothing"). Require every result report to name the machine it ran on. Note any
     security posture that silently blocks unsigned binaries, and where measurements go
     instead of standalone probe executables. -->

## Timestamps

<!-- FILL: (or delete) if the project renders timestamps to humans: storage/transport
     stay UTC; display is ONE configured zone, never the viewer's, stated beside every
     value; name the single formatting seam per side; label wall-clock values instead of
     converting; validate zone ids in exactly one function and reject ambiguous legacy
     abbreviations (CET/MET/EET/WET); record every deliberate exception here or someone
     will "fix" it; test with a fractional-offset zone (`Asia/Kathmandu`, +5:45), an
     empty value, and an invalid one. -->

## Honeypots

<!-- FILL: (or delete) if the project plants deliberate decoys: name the marker (e.g. a
     grep-able tag) and require `git grep -n <marker>` before reporting ANY dead code,
     unreachable path, or unused field. A document describing a decoy as live is drift —
     banner it. -->

## Current design topic

<!-- FILL: (or delete) what is being designed right now, what is already settled, where
     the evidence lives. Replace it when the topic changes — a stale "current topic"
     points every new session at finished work. When you retire a target document, delete
     or repoint every pointer to it in the same change. -->

## Local tooling

<!-- FILL: (or delete) optional code-graph harnesses. ⚠ The tools are PER-MACHINE, not
     per-project: if they are identical across your projects, keep the routing table in a
     user-scope rules file (`~/.claude/rules/tooling.md` — loads in every project) and
     leave only the injection guards here; one copy either way. Content: which tool
     answers which question, one routing table, no overlaps except the ones you name.
     State that nothing may write into this file and name the flag that stops each
     injector. A graph's caller-answer is not evidence — when load-bearing, settle it
     with `git grep` plus a positive control. Freshness is never visible in the answer
     itself: state per tool what triggers a re-index, how long it takes, how to read its
     status, whether uncommitted code is included — and never judge freshness from the
     index database's mtime. -->

## Situational rules — `.claude/rules/`

Project rules that only matter for part of the codebase go in `.claude/rules/*.md` with
`paths:` frontmatter, so they load only when a matching file is read. ⚠ Use this ONLY for
rules tied to reading particular files: a rule that guards an activity (committing,
running shell commands, deploying) never triggers on a file read, so path-scoping it
switches it off silently. When in doubt, the rule stays in this file.

User-level equivalents live in `~/.claude/rules/` (loaded before project rules), and the
directory supports symlinks — the documented way to share one rule set across projects.
