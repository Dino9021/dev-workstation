# CLAUDE.md snippet — claude-mem (English)

正體中文版：[`claude-md-snippet.zh-TW.md`](claude-md-snippet.zh-TW.md)
Rationale and background: [`README.md`](README.md)

**How to use it**: copy everything below the horizontal line into your project's `CLAUDE.md`
(or `CLAUDE.local.md`, if you would rather it stayed off the shared, version-controlled file
— this rule is about a tool that only exists on machines where you installed it).

⚠️ **Paste it OUTSIDE any auto-generated block.** Some tools (gitnexus, for one) maintain
their own section between `<!-- tool:start -->` / `<!-- tool:end -->` markers and overwrite
the whole thing on the next run, taking your rules with it.

---

## claude-mem — what it is, and what it is NOT

`claude-mem` captures observations of this session passively and injects relevant ones at the
start of later sessions. You do not operate it; it operates on you.

### It is not the project's memory folder, and the difference is load-bearing

| | claude-mem | the project's `Memory/` folder |
|---|---|---|
| Where | `~/.claude-mem`, a local SQLite database | files in the repository |
| Who can read it | **only this machine, only this account** | everyone who clones the repo |
| Survives a new workstation | **no** | yes, it is in git |
| Reviewable in a diff | no | yes |
| Written by | hooks, automatically | you, deliberately |

**A deferred item, a decision, a handover or anything another person must act on goes in a
FILE.** claude-mem having "remembered" it satisfies no rule that asks for a written record —
the next person, the next machine, and the reviewer all see nothing. If your project's
instructions name a pending file, a task folder or a decision record, those are still the
only places those things live.

Use claude-mem for what it is good at: *"have I seen this before?"*

### Four behaviours that look like faults and are not

1. **A brand-new project's first session gets no injected memory.** Injection starts from the
   **second** session onward, because the first one is what creates the observations.
2. **Observations appear without being asked for.** They stream in as the agent reads, edits
   and runs commands. Never announce that you are "saving this to claude-mem" — nothing is
   being saved by you, and saying so invents an action that did not happen.
3. **Nothing is captured while the worker is down.** It is a local service on port 37777.
   `npx claude-mem status` answers in one line; `npx claude-mem doctor` diagnoses.
4. **A teammate's session cannot see your observations, and yours cannot see theirs.** The
   database is per machine and per account. There is no sync unless you bought one.

### Searching it

Search before redoing work someone (possibly you, last month) already finished:

```
npx claude-mem search "<what you are about to start>"
```

If a `mem-search` skill is available in the session, prefer it — it is the same store with a
better interface. **An empty result is not proof of absence**: memory only holds sessions
that ran on this machine while the worker was up. Treat a miss as UNCONFIRMED and check the
repository itself before concluding nobody has done the work.
