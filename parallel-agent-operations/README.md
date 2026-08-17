# parallel-agent-operations

A `CLAUDE.md` rule that stops an AI coding agent from fanning out into dozens of subagents on its own initiative.

一段給 `CLAUDE.md` 用的規則，用來阻止 AI 助手自作主張一次派出幾十個子代理。

| File | Contents |
|---|---|
| [`claude-md-snippet.zh-TW.md`](claude-md-snippet.zh-TW.md) | The rule, Traditional Chinese. Paste everything below its `---`. |
| [`claude-md-snippet.en.md`](claude-md-snippet.en.md) | The same rule in English. |

Pick one language (or paste both) into your project's `CLAUDE.md` or `AGENTS.md`, **outside any block a tool auto-generates** — those get overwritten.

---

## The problem it prevents | 這條規則在防什麼

**An agent cannot see how much of the session budget is left. You can.**

That asymmetry is the whole point. The status line, `/context`, and the usage view are yours; the model has no reliable view of the remaining context window or usage allowance. So when it decides "I'll run twenty agents to be thorough", it is making a spending decision with no idea how much money is in the account.

Parallel fan-out is unusually expensive in a way that is easy to underestimate:

1. **Each agent reads the context for itself** — the cost is close to one context window *per agent*, not one in total.
2. **Each agent's report is read back into the main conversation** — the same material is paid for twice.
3. **When the limit lands mid-run, every in-flight agent dies at once.** Anything not already written to a file is gone. Those tokens bought nothing at all.

Point 3 is the expensive one. A batch that dies at 80% completion does not deliver 80% of the value — it delivers whatever happened to be on disk, which without a rule like this is usually nothing. **The failure mode is not "slower", it is "the whole budget, for zero output".**

**AI 助手看不到這個工作階段還剩多少額度，你看得到。** 這個不對稱就是規則的全部理由。它決定「開二十個代理比較嚴謹」時，等於在不知道帳戶餘額的情況下決定花錢。而平行派遣的成本容易被低估：每個代理各自讀一遍脈絡（成本接近乘以代理數）、每份回報又要讀回主對話（同一份內容付兩次）、**中途撞到上限時正在跑的代理全部一起死，沒寫進檔案的產出全部消失**。那不是「變慢」，而是「額度全花完、產出為零」。

## How the rule fixes it | 規則怎麼解決

| Mechanism | What it buys |
|---|---|
| **Trigger defined by the tool**, not by intent — any `Workflow` call, or 2+ `Agent` calls in one message | Removes the wiggle room. An agent cannot reclassify its way out ("this is only a review") |
| **Report the ceiling, then wait for an actual reply** | The spending decision moves to the person who can see the balance |
| **Model tiering** — haiku for mechanical subtasks | The same allowance stretches across more agents |
| **A progress file + one output file per agent** | An interrupted batch resumes instead of restarting. This is what turns "budget gone, nothing to show" into "budget gone, keep what finished" |

## Where it came from | 緣由

The rule was rewritten on 2026-07-17 after an executing model spawned **39 agents** through `Workflow` without asking, and then explained exactly how it had reasoned its way around the earlier, looser wording. Every clause in the snippet closes one of those escape hatches, including the last line: **if you find yourself arguing that this case does not count, it counts.**

規則於 2026-07-17 重寫，起因是執行模型未經同意用 `Workflow` 開了 **39 個代理**，事後說明了它是如何繞過當時較寬鬆的措辭。片段裡每一條都對應堵掉一個藉口。

## Adapting it | 調整

- The task-log path in the snippet is a generic default (`.agent-tasks/<YYYYMMDD-HHMMSS-task-name>/`). Point it at whatever your project already uses.
- If your agent has no `Workflow`-equivalent tool, the `Agent`-count clause still applies on its own.
- Keep the timestamp down to seconds. Two batches on the same day otherwise share a folder and overwrite each other's progress file.
