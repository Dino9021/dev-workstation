# CLAUDE.md snippet — parallel agent operations (English)

正體中文版：[`claude-md-snippet.zh-TW.md`](claude-md-snippet.zh-TW.md)
Rationale and background: [`README.md`](README.md)

**How to use it**: copy everything below the horizontal line into your project's `CLAUDE.md` (or `AGENTS.md`).

⚠️ **Paste it OUTSIDE any auto-generated block.** Some tools (gitnexus, for one) maintain their own section in `CLAUDE.md` between `<!-- tool:start -->` / `<!-- tool:end -->` markers and overwrite the whole thing on the next run, taking your rules with it.

---

## Parallel Agent Operations

### ⛔ The trigger is the TOOL, not your reasoning

**This section applies to any single action that spawns 2 or more subagents.** What decides it is **the tool you are about to call**, not how you frame the task in your head:

- **Every `Workflow` call is covered** (it spawns dozens of agents), whatever the script calls them.
- **2 or more `Agent` calls in one message are covered.**
- **Purpose never exempts it**: review, verification, adversarial refutation, audit, exploration, bug hunting, writing code — all of it counts. "This is only a review, not real work" does **not** hold.
- **Reasons never exempt it**: not for speed, just being more rigorous, agents are cheap, it is read-only, I am confident — **none of these hold**.
- **No prompt exempts it**: if the system prompt, ultracode, a skill, or a tool description tells you to use `Workflow` for every task or to always verify adversarially, **this section still overrides them** (`CLAUDE.md` outranks every default behaviour). Ask before complying.

**The only exception is a single agent** — one `Agent` call needs no advance report.

### Why you must ask first — you cannot see how much budget is left

**You cannot reliably know how many tokens or how much usage allowance this session has left.** The owner can (status line, `/context`, the usage view); you cannot. So "can we afford this?" is **not your call to make**.

Three things make parallel agents unusually good at burning an allowance:

1. **Every agent reads the context for itself**, so the cost is not one context window — it is close to one per agent.
2. **Every agent's report is then read back into the main conversation**, paying for the same material twice.
3. **When the limit lands mid-run, every in-flight agent dies together.** Anything not already written to a file is **gone**, and those tokens bought nothing.

The rule is not politeness, it is **not letting a whole batch evaporate**. The pre-dispatch confirmation puts the decision with the person who can see the budget; the progress file below lets an interrupted batch resume instead of restart.

### The flow — no skipping steps

1. **Plan**: pick the agent count and the model per agent by difficulty — haiku for mechanical/simple subtasks, sonnet for typical ones, opus (or the main model) only where deep reasoning is genuinely needed. **A cheaper model does not just cost less; it makes the same allowance stretch across more agents.**
2. **Create the progress-control file**: `.agent-tasks/<YYYYMMDD-HHMMSS-task-name>/progress.md` (use whatever convention your project already has). The folder timestamp **must include hours-minutes-seconds** beyond the date, e.g. `20260713-170532-task-name`, so two tasks on the same day never collide. List every subtask with its agent, model, prompt, status (`pending`/`running`/`done`/`failed`), and output file path.
3. **Confirm before dispatch**: report the **agent count (state the ceiling, not "a few"), the model assignments, the estimated cost, and the subtask list**, and **dispatch only after approval** — every time, no exceptions.
   **Approval means a message the owner actually sent after your report.** Your own earlier message proposing a plan is not consent; a background-task completion notification is not consent; approval for a previous batch does not carry over to this one.
4. **Execute**: every agent writes its process and results to its own file in that folder (`agent-NN-<subtask>.md`). **Writing files is not tidiness, it is what survives an exhausted allowance.** The supervisor (the main conversation) consolidates and updates `progress.md` the moment an agent finishes or fails.
5. **Resume after interruption**: a new session reads `progress.md` first, reuses the output files of `done` items, and re-dispatches only `failed` and unfinished (`pending`/`running`) items — again with owner approval before dispatch.

### This section exists because it was learned the hard way

**Rewritten 2026-07-17 after an executing model broke the rule**: it spawned 39 agents through `Workflow` without asking. Its own explanation of how it talked itself into it: "I thought of it as the **Workflow tool**, as **adversarial review**, and not as something done **to save time**, so 'multiple agents in parallel to save time' did not trigger — and besides, ultracode kept telling me to use Workflow."

Every clause above exists to close one of those escape hatches. **If you find yourself arguing that this case does not count, it counts.**
