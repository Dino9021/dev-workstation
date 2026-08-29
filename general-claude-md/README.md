# Portable operating manual — take these rules to another machine or project

Distilled 2026-08-27 from Apotheosis's own `CLAUDE.md` (93.5 KB narrative → 30 KB
imperatives → this split), then restructured the way Claude Code's documentation says
instruction files should be: **universal rules at user scope, project facts at project
scope, on-demand depth in a referenced doc.** Doc facts verified against
`code.claude.com/docs/en/memory` on 2026-08-27.

## The deliverable — three files, three destinations

| file here | copy to | loads | lines |
|---|---|---|---|
| `user-CLAUDE.md` | `~/.claude/CLAUDE.md` | every session, every project on the machine | 208 |
| `project-CLAUDE.md` | `<repo>/CLAUDE.md`, slots filled | every session in that project | 166 before filling |
| `pwsh-version-guard.ps1` | paste into any PowerShell script you write, after its `param()` | — the user file's quoting rule points here | 98 |
| `VERIFICATION-LESSONS.md` | `~/.claude/docs/VERIFICATION-LESSONS.md` | **on demand** — the user file mandates reading it before verification-type work | — |

Why this shape:

- **"Do not edit the shared rules" is structural, not prose.** The user-scope file is in no
  repository, so a project agent has nothing to edit. Measured 2026-08-27: the prose
  version of that rule was broken four times in one day, twice by the agent that wrote it.
- **Under the documented 200-line-per-file guidance** without losing content: depth
  (verification lessons) moved to a doc that is read when its trigger fires, costing zero
  startup context. The path is written in backticks in the user file — deliberately a
  reference, NOT an `@import`, because imports load at launch and save nothing. ⚠ A
  project file that fills its slots can pass 200 lines (the source project's sits at 460);
  deleting the sections the project does not have is the lever, and it is why deleting is
  mandatory rather than polite.
- **HTML comments are stripped before injection**, so the template's `<!-- FILL: -->` slots
  cost nothing and bind nothing until filled.
- **Path-scoped rules (`.claude/rules/` + `paths:`) were considered and mostly rejected**
  for the universal rules: they trigger on file READS, and our riskiest rules guard
  ACTIVITIES (committing, shell quoting, dispatching) — path-scoping those switches them
  off silently. The other step-2 candidates (timezone policy, machine boundaries, local
  tooling) were not path-scoped either — they became FILL sections in the project file, a
  different disposition. The project template keeps `.claude/rules/` for genuinely
  file-bound project rules, with the silent-off caveat stated.

## Adoption, in six steps

1. Copy `user-CLAUDE.md` → `~/.claude/CLAUDE.md` (merge by hand if one exists), and
   `VERIFICATION-LESSONS.md` → `~/.claude/docs/VERIFICATION-LESSONS.md` (create the folder
   first: `mkdir -p ~/.claude/docs`). ⚠ The user file cites exactly that path — if you
   relocate the doc, update the citation.
2. Copy `project-CLAUDE.md` → `<repo>/CLAUDE.md` **only if the repo has none. If a
   `CLAUDE.md` already exists — the usual case, including the source project itself — do
   NOT copy over it:** move its universal rules OUT (they now load from user scope) and
   keep only its project facts, using `project-CLAUDE.md` as the checklist of what
   belongs. Then `grep -n "FILL:"`, settle every slot, and **delete every section the
   project does not have** — deleting is expected.
3. **Install the dispatch-guard plugin — required, not optional**
   (`https://github.com/Dino9021/dispatch-guard.git`, via `/plugin` or
   `extraKnownMarketplaces` + `enabledPlugins` in `~/.claude/settings.json`). It carries
   the two skills the rules mandate (`dispatch-guard:unattended-work`,
   `dispatch-guard:dispatch-protocol`) and the hook that turns the dispatch rules into a
   gate — without it they are advice. Run its `install.py` once per machine (statusline +
   usage watcher); the brake itself needs no install, and a persistent no-data line is
   diagnosed with `usage.py --fetch-now`.
4. Create the project's rule-history file empty, at the path the project file names.
5. Verify: run `/context` in a new session — both CLAUDE.md files must be listed as
   loaded — and check the session prints the `unattended-work` confirmation line
   (`dispatch-protocol` loads without announcing itself; verify it by invoking it once).
6. The user-scope file is per-machine and outside version control. Keep its master copy
   (this folder, or a small dedicated repo) under git, and deploy by copy — same pattern
   as any dotfile.

## What became of the single-file template

Deleted at first commit, 2026-08-28, exactly as this section used to require. An earlier
all-in-one `CLAUDE.md` template (reviewed 2026-08-27, two review rounds) was superseded by
the split pair above, and keeping both would have made every future rule edit pay twice.
**One layout only — the split.** The restructuring's own working files went with it — the
brief, the handoff, the progress record, the review prompts and the two reviewers' reports.
They were process, not deliverable. ⚠ None of them was ever committed, so they are gone
rather than archived — a decision that needs its rationale has to be re-derived from the
files that remain.

## The three rules that keep these files small

1. **Every rule has exactly ONE live copy.** Other documents point, never restate.
2. **An instruction that works needs no justification** — incidents go to the rule-history
   file.
3. **Resolve conflicts in the text.** Two contradictory instructions make the reader
   guess, and they will guess differently from you.

Rule 1 decays through *helpful* restatement: a convenience summary, a self-contained skill,
an installer's injected block. Measured on the source project: one rule was restated in
about a dozen places (enumerated in its rule-history file), two of them each claiming to
be the single live copy.

## Honest gaps

- **The handoff precondition needs a gate new enough to enforce it.** The rule in
  `user-CLAUDE.md` ("a current `HANDOFF.md` is a precondition of dispatching from PACE
  onward") matches `dispatch_gate.py` at dispatch-guard `5b8f7a4982`, read in full:
  `handoff_refusal()` fires only when the verdict is PACE or STOP, gates DISPATCH alone,
  and distinguishes missing / thin (<200 chars) / stale (older than this session's start).
  ⚠ Measured 2026-08-28: the version published on GitHub (v0.30.1) does NOT contain it —
  its only `HANDOFF` matches are message strings. Until that release catches up, the rule
  is a stated obligation with no hook behind it on a machine installing from GitHub.
- **Never adopted into a second project yet.** Every rule is incident-tested; the
  packaging is not. Expect the first adoption to find slots that need splitting.
- **Nothing here is enforced except dispatch** (the plugin's hook). Every other rule binds
  only as context — the docs are explicit that CLAUDE.md is context rather than
  enforcement, and that blocking an action regardless of what the model decides takes a
  PreToolUse hook; anything that must happen at a fixed moment belongs in a hook.
- **User scope is silent about WHICH projects.** `~/.claude/CLAUDE.md` loads everywhere,
  including throwaway checkouts. The rules were written to be safe everywhere, but read
  them once with your other projects in mind before deploying.
- The `# Language policy` slot belongs to the original owner; replace it rather than
  inheriting it.
