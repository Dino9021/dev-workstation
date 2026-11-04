# Graphify 評估：不納入 | Graphify evaluation: not adopted

**結論：[Graphify](https://github.com/Graphify-Labs/graphify) 評估過，決定不加進這套工具。**
它能在 VS Code 的 Claude Code 擴充功能上正常運作，但取代不了 GitNexus，也不足以取代
code-review-graph；以第三台圖譜伺服器的身分加進來，帶來的麻煩比幫助多。

**Verdict: [Graphify](https://github.com/Graphify-Labs/graphify) was evaluated and is NOT
part of this toolchain.** It works on the VS Code Claude Code extension, but it cannot
replace GitNexus, does not fully replace code-review-graph, and as a third graph server
beside them it costs more than it adds.

> 評估日期 2026-11-04，讀的是 Graphify 原始碼 commit `59b5ab1`（2026-11-03），PyPI 套件名
> `graphifyy`。下面的檔名與行號都指那個版本；之後的版本可能已經改了。**這是讀原始碼的
> 評估，沒有在真實專案上實際安裝量測。**
>
> Evaluated 2026-11-04 by reading Graphify's source at commit `59b5ab1` (2026-11-03), PyPI
> package `graphifyy`. File and line references point at that commit; later releases may
> differ. **This is a source-reading evaluation — nothing was installed and measured on a
> real project.**

---

## 1. 能不能在 VS Code 擴充功能上用 | Does it work on the VS Code extension

可以。它只用到擴充功能與 CLI 共通的機制：

Yes. It relies only on mechanisms the extension shares with the CLI:

| 機制 Mechanism | 用途 Used for | 擴充功能可用？ Extension? |
|---|---|---|
| `~/.claude/skills/graphify/` 的 skill | `/graphify` 指令 | 可以 / yes |
| `.claude/settings.json` 的 `PreToolUse` hook | 引導 AI 先查圖 / nudge toward the graph | 可以 / yes |
| PATH 上的 `graphify` CLI | `graphify query` / `path` / `explain` / `update` | 可以 / yes |
| PATH 上的 `claude` | 只有選用的 `claude-cli` 後端需要 / only the optional `claude-cli` backend | 視安裝而定 / if installed |

它也解析這套工具主要用的語言：`.ps1`、`.sh`、`.py` 都在 `CODE_EXTENSIONS`
（`graphify/detect.py:48`），而且有專門的 PowerShell 解析器。程式碼分析在本機用
tree-sitter 完成，不呼叫 AI、不上網。

It parses this toolchain's languages — `.ps1`, `.sh` and `.py` are all in `CODE_EXTENSIONS`
(`graphify/detect.py:48`), with a dedicated PowerShell extractor. Code is parsed locally with
tree-sitter: no LLM, no network.

---

## 2. 能不能取代現有兩台 | Can it replace either server we already run

| 能力 Capability | GitNexus | code-review-graph | Graphify |
|---|---|---|---|
| 資料流 / taint、PDG（「這個值流到哪」） | ✅ | — | ❌ 沒有 / none |
| 逐步執行流程 / execution flow | ✅ | — | ❌ |
| Cypher 原生查詢 / raw graph queries | ✅ | — | ❌ |
| 依呼叫圖跨檔改名 / call-graph-aware rename | ✅ | — | ❌ |
| 分群、核心節點 / communities, hubs | — | ✅ | ✅ |
| 影響範圍 / impact radius | ✅ | ✅ | ✅ (`affected.py`, `get_pr_impact`) |
| 存檔後約 2 秒自動更新 / live refresh on save | — | ✅ 常駐程式 / daemon | ❌ commit 或手動 / on commit or by hand |
| 語意向量搜尋 / embedding search | — | ✅ | ❌ 設計上不用向量 / no embeddings by design |
| 文件與程式在同一張圖、每條邊標明來源可信度 / docs and code in one graph, each edge tagged EXTRACTED or INFERRED | 有索引 `.md` / indexes `.md` | ❌ | ✅ |
| 兩個概念之間的最短路徑 / shortest path between two concepts | 可用 Cypher 寫 / via Cypher | — | ✅ `graphify path A B` |
| 給人看的互動式圖 / interactive HTML graph for humans | — | — | ✅ |

- **取代不了 GitNexus。** 我們用 GitNexus 的理由（資料流、執行流程、Cypher、改名）Graphify
  一項都沒有。
- **和 code-review-graph 大幅重疊，但缺它的即時更新與語意搜尋。** 換掉它是架構層級的決定，
  前提是先實測證明 Graphify 找呼叫者找得更準——而兩台現有伺服器都曾經在這件事上少報過，
  所以重要時本來就要用 `git grep` 核對。多一張圖，只是多一個可能答錯的來源。

- **It cannot replace GitNexus.** None of the reasons we run GitNexus — data flow, execution
  flow, Cypher, rename — exist in Graphify.
- **It overlaps code-review-graph heavily but lacks its live refresh and semantic search.**
  Swapping it out is an architectural decision that would first need a measurement showing
  Graphify finds callers more accurately. Both existing servers have under-reported callers,
  so a load-bearing caller list is checked with `git grep` anyway; a third graph adds a third
  source that can be wrong, not a replacement for that check.

---

## 3. 照它預設方式安裝會撞到什麼 | What its default install collides with

如果你自己還是想裝，**下面每一項都要先處理**。

If you install it anyway, **handle every item below first**.

**C1 — 寫進全域 `~/.claude/CLAUDE.md`。** 在 Windows 上，`graphify install` 自動選
`windows` 平台（`install.py:2673`），它的設定 `claude_md: True`，會把一段登記寫進
`~/.claude/CLAUDE.md`（`install.py:1075-1086`）。這套工具的
[`user-CLAUDE.md`](../general-claude-md/user-CLAUDE.md) 規定任何安裝程式都不得寫入那個檔。
**不要直接跑 `graphify install`。**

**C1 — Writes into the global `~/.claude/CLAUDE.md`.** On Windows `graphify install` picks
the `windows` platform (`install.py:2673`), whose config has `claude_md: True`, and registers
itself in `~/.claude/CLAUDE.md` (`install.py:1075-1086`). This toolchain's
[`user-CLAUDE.md`](../general-claude-md/user-CLAUDE.md) forbids any installer writing there.
**Do not run bare `graphify install`.**

**C2 — 寫進專案、受版本控制的 `CLAUDE.md`。** `graphify claude install` 會加一段
「查程式前一律先跑 `graphify query`」（`install.py:2296-2313`，內容在
`graphify/always_on/claude-md.md`）。和 GitNexus 的 `analyze` 不加 `--skip-agents-md`
時會做的事同一類。

**C2 — Writes into the project's version-controlled `CLAUDE.md`.** `graphify claude install`
appends a "run `graphify query` before your first grep" section (`install.py:2296-2313`, text
in `graphify/always_on/claude-md.md`) — the same class of side effect GitNexus's `analyze`
has without `--skip-agents-md`.

**C3 — 第三個搶先指路的 hook。** 它在 `Bash|Grep` 與 `Read|Glob` 上各加一個
`PreToolUse` hook（`install.py:559-596`、`2326-2348`）。合併方式很守規矩（只拿掉自己的、
保留別人的，並先備份），但最常用的四個工具前面會出現第二個「先問我」的提示，和
[`claude-md-snippet.md`](claude-md-snippet.md) 裡兩台伺服器「依問題分工」的規則互搶。
`--strict` 模式還會每個 session 直接拒絕一次讀檔或搜尋（`cli.py:59-80`）。

**C3 — A third "ask me first" hook.** It adds `PreToolUse` hooks on `Bash|Grep` and
`Read|Glob` (`install.py:559-596`, `2326-2348`). The merge is careful (it strips only its own
entries and backs the file up), but the four most frequent tools then carry a second
"graph first" nudge, competing with the split in [`claude-md-snippet.md`](claude-md-snippet.md).
`--strict` goes further and denies one Read or Grep per session (`cli.py:59-80`).

**C4 — git hook 互相抵銷，而且都不報錯。**
- `graphify hook install` 會把自己的段落**接在**既有的 `post-commit` 後面
  （`hooks.py:880-909`）。這套工具的 [`post-commit`](post-commit) 最後一行是 `exit 0`，
  所以接上去的段落永遠不會執行，圖就悄悄過時。
- 反過來，下次跑 [`install.ps1`](install.ps1) 時，它發現 hook 內容不同，會用這裡的版本蓋掉
  （舊的備份在旁邊），Graphify 的段落就消失了。
- 它另外還會加 `post-checkout`、`post-merge`、`post-rewrite`，在 git 設定裡登記
  `merge.graphify.*`，並在 `.gitattributes` 加一行（`hooks.py:1003-1048`、`1116-1153`）。

**C4 — The git hooks cancel each other out, silently.**
- `graphify hook install` APPENDS to an existing `post-commit` (`hooks.py:880-909`). This
  toolchain's [`post-commit`](post-commit) ends with `exit 0`, so the appended block never
  runs and the graph goes stale with no error.
- In reverse, the next [`install.ps1`](install.ps1) run sees a different hook and replaces it
  with the master (backup beside it), removing Graphify's block.
- It also adds `post-checkout`, `post-merge` and `post-rewrite`, registers `merge.graphify.*`
  in git config, and appends to `.gitattributes` (`hooks.py:1003-1048`, `1116-1153`).

**C5 — `/graphify` 規定一次平行派出多個子代理。** Windows 版 skill 寫明「必須用 Agent
工具」、「所有子代理在同一則訊息裡派出」（`skill-windows.md:252`、`303-313`），用來分析
文件、PDF、圖片。這和 [`parallel-agent-operations/`](../parallel-agent-operations/) 的規則
正面衝突；有裝 dispatch-guard 的機器會直接擋下。純程式碼的專案會跳過這一步。

**C5 — `/graphify` mandates parallel sub-agents.** The Windows skill says "MANDATORY: You
MUST use the Agent tool" and "Dispatch ALL subagents in a single message"
(`skill-windows.md:252`, `303-313`) for docs, PDFs and images. That contradicts
[`parallel-agent-operations/`](../parallel-agent-operations/), and dispatch-guard refuses it.
A code-only corpus skips this step.

**C6 — `graphify-out/` 放在專案根目錄，沒有被 ignore。** 安裝程式不會幫你加 `.gitignore`。

**C6 — `graphify-out/` lands in the project root, unignored.** The installer adds no
`.gitignore` rule.

**C7 — Windows 上可能和 code-review-graph 的監看程式搶資料夾。** 那個常駐程式會握住它監看
目錄的 handle；Graphify 重建時會改寫專案內的 `graphify-out/`。**未量測**，只是推測。

**C7 — Possible directory-handle contention on Windows.** code-review-graph's watch daemon
holds handles on the tree it watches, and Graphify rewrites `graphify-out/` inside it.
**Not measured** — a hypothesis only.

**C8 — 查詢紀錄寫在專案外。** 每次查詢都追加到 `~/.cache/graphify-queries.log`；設
`GRAPHIFY_QUERY_LOG_DISABLE=1` 可以關掉。

**C8 — Query log outside the project.** Every query is appended to
`~/.cache/graphify-queries.log`; `GRAPHIFY_QUERY_LOG_DISABLE=1` turns it off.

**沒有衝突的部分 / No conflict:** 三台的資料完全分開（`graphify-out/graph.json`、
`.gitnexus/`、`.code-review-graph/graph.db`）；`uv tool install` 是獨立環境；它的 MCP
伺服器是選用套件（`graphifyy[mcp]`），安裝程式不會自動登記。
Storage is fully separate; `uv tool install` is isolated; its MCP server is an optional extra
that the installer does not register.

---

## 4. 如果你還是要裝 | If you install it anyway

衝突最少的裝法——只裝 CLI，不讓它改任何設定：

The least-conflict route — the CLI only, nothing allowed to touch your configuration:

```
uv tool install graphifyy        # 只裝 CLI / the CLI only
# 不要跑 / do NOT run:  graphify install · graphify claude install · graphify hook install
graphify update .                # 只分析程式碼，不派子代理、不呼叫 AI / AST only: no sub-agents, no LLM
```

再把 `/graphify-out/` 加進 `.gitignore`，並在 `CLAUDE.local.md` 寫清楚三台各管什麼，
**再**讓 AI 依賴它。

Then add `/graphify-out/` to `.gitignore`, and write the three-way split into
`CLAUDE.local.md` **before** any agent relies on it.

## 什麼情況值得重新評估 | When to reconsider

- 有一次實測顯示 Graphify 在同一個函式上找到的呼叫者，比 code-review-graph 更接近
  `git grep` 的結果。
- Graphify 加入即時更新，或提供不寫入 `CLAUDE.md`、不裝 hook 的 skill 安裝選項。
- 專案大到搜尋本身變貴，而且主要需求是「文件與程式一起查」。

- A measurement on one function shows Graphify's caller list closer to `git grep` than
  code-review-graph's.
- Graphify gains live refresh, or a skill-install option that writes no `CLAUDE.md` and no
  hooks.
- A project large enough that searching is expensive, whose main need is querying docs and
  code together.
