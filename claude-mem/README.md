# claude-mem — 跨 session 的持久記憶 | persistent memory across sessions

[`claude-mem`](https://github.com/thedotmack/claude-mem) 被動記錄每個 session 的觀察，並在之後的 session 開始時把相關的注入回來。它和 [`graph-servers/`](../graph-servers/) 的兩台程式圖譜伺服器同一類：**開發過程中協助 Claude Code agent 的工具**，所以根目錄的 [`install.ps1`](../install.ps1) 預設就會把它裝好。

[`claude-mem`](https://github.com/thedotmack/claude-mem) passively records observations from each session and injects the relevant ones at the start of later ones. It belongs to the same family as the two code-graph servers in [`graph-servers/`](../graph-servers/) — **tooling that assists the Claude Code agent while you develop** — so the root [`install.ps1`](../install.ps1) installs it by default.

| File | Contents |
|---|---|
| [`claude-md-snippet.md`](claude-md-snippet.md) | The agent-facing rule, English. Paste everything below its `---`. |
| [`claude-md-snippet.zh-TW.md`](claude-md-snippet.zh-TW.md) | 同一條規則的正體中文版 / the same rule in Traditional Chinese. |

---

## 1. 安裝 | Installing

根目錄的 `install.ps1` 會做這四步。手動做的話：

The root `install.ps1` runs these four steps. By hand:

```powershell
npx claude-mem install --provider claude --runtime worker
claude plugin marketplace add thedotmack/claude-mem
claude plugin install claude-mem-cowork@thedotmack
npx claude-mem start
```

### ⚠️ 第一行在真正的終端機裡**可能會問你問題** | The first line MAY ask you a question

**這不是故障，也不需要避開 —— 但要先知道。** claude-mem 的安裝程式在**互動式終端機**裡會顯示一個畫面，比較它的付費雲端方案與純本機模式。根目錄的 `install.ps1` 會在執行它**之前**先把這段說明印出來。

**It is not a fault and does not need to be avoided — but know it first.** In an **interactive terminal** claude-mem's installer shows a screen comparing its paid cloud tier with local-only mode. The root `install.ps1` prints this explanation **before** it runs.

| 問到的時候 If it asks | 怎麼答 What to answer |
|---|---|
| 雲端方案 vs 純本機 / cloud tier vs local-only | **選本機 / choose local.** 那正是 `--provider claude` 已經設定的；不需要帳號，不會上傳任何東西 / that is what `--provider claude` already selects — no account, nothing uploaded |

兩個旗標就是為了讓其他選擇不會變成問題：

The two flags exist so the other choices can never become questions:

- `--provider claude` —— 用你已登入的 Claude 帳號、本機處理、不開雲端同步。**在非互動式終端機裡這個旗標是必要的**，沒有它會直接中止（見下）。 / uses your logged-in Claude account, processes locally, cloud sync off. **Required when stdin is not interactive.**
- `--runtime worker` —— 選小型的本機 worker，**不是** `server` 執行環境。這一個比看起來重要：`--runtime server` 會拉起 Docker 帶 postgres 與 redis。 / picks the small local worker, **not** the `server` runtime — which would bring up Docker with postgres and redis.

⚠️ **無人職守執行時它完全不會問。** stdin 不是終端機（腳本、CI、被其他工具啟動）時，它自己走腳本路徑。本文件所有量測都是在那個情況下取得的 —— **「在真正的終端機裡它到底會問什麼」我們沒有實測過**，所以上面寫的是「可能會問」而不是斷言。

⚠️ **Run unattended it does not ask at all.** With stdin not a terminal it takes the scripted path by itself. Every measurement in this file was taken that way — **what it actually prompts for in a real terminal has NOT been measured here**, which is why this says "may ask" rather than asserting.

### ⚠️ 第四行不是多餘的 | The fourth line is not redundant

**在非互動式終端機（腳本、CI、被其他工具啟動）裡，安裝程式不會自動啟動 worker。** 實測 2026-09-22，它就是這樣說的：

**In a non-interactive terminal — a script, CI, or launched by another tool — the installer does not auto-start the worker.** Measured 2026-09-22, it says so itself:

```
! Worker autostart skipped — start it manually with npx claude-mem start
```

**worker 沒跑 = 什麼都沒記錄**，而且不會有任何錯誤。所以腳本化安裝一定要自己補 `npx claude-mem start`。

**No worker means nothing is captured**, and nothing errors. A scripted install must therefore run `npx claude-mem start` itself.

### ⚠️ `--provider claude` 在腳本裡是必要的，不是偏好

沒有它，安裝程式在 stdin 不是互動式的時候會直接中止：

Without it the installer aborts outright when stdin is not interactive:

```
Installation Aborted: unknown-install-error
provider-selection failed during non-interactive-validation:
A provider must be explicit when stdin is not interactive.
```

`--provider claude` 表示用你已登入的 Claude 帳號，本機處理，不開雲端同步。

`--provider claude` means it uses your logged-in Claude account, processes locally, and leaves cloud sync off.

---

## 2. ⚠️ 安裝程式會停掉正在跑的 worker | The installer STOPS a running worker

**重跑 `npx claude-mem install` 不是沒有代價的。** 它在設定切換之前會先把正在跑的 worker 停掉：

**Re-running `npx claude-mem install` is not free.** It stops the running worker before its configuration cutover:

```
claude-mem v13.25.3 · reinstall
Stopped running worker before configuration cutover.
```

所以根目錄的 `install.ps1` **會先檢查再決定**，三種狀態三種做法：

So the root `install.ps1` **checks first**, with three states and three answers:

| 狀態 State | 做什麼 What it does |
|---|---|
| worker 正在跑 / running | **完全跳過安裝程式**，worker 一秒都不中斷 / **skips the installer entirely**; the worker is never interrupted |
| 已安裝但 worker 停著 / installed, worker stopped | 只跑 `npx claude-mem start` —— 重裝會是一把大鎚，它還會先停掉它正要啟動的那個 worker / runs only `npx claude-mem start` — a reinstall would be a sledgehammer that also stops the worker it is about to start |
| 沒安裝 / absent | 印出說明（見上一節），然後才安裝 / prints the explanation above, then installs |

實測 2026-09-22：完整重跑一次 `install.ps1`，worker 的 **PID 前後相同（7600）** —— 它沒有被重啟。

Measured 2026-09-22: across a full re-run of `install.ps1` the worker's **PID was identical before and after (7600)** — it was never restarted.

⚠️ **`--help` 在這個 CLI 上不是安全的探測方式。** 只要前面已經有別的旗標，`npx claude-mem install --provider claude --help` **不會印說明，它會直接跑安裝**，而且順手把 worker 停掉。這個坑是實際踩到才知道的。

⚠️ **`--help` is not a safe probe on this CLI.** With other flags already present, `npx claude-mem install --provider claude --help` does **not** print help — it runs an install, stopping the worker on the way through. Found by walking into it.

想自己確認狀態，用唯讀的那兩個： / To check the state yourself, use the two read-only commands:

```powershell
npx claude-mem status     # "Worker is running" / "Worker is not running"
npx claude-mem doctor
```

---

## 3. 可重複執行嗎？可以，實測過 | Is it idempotent? Yes, measured

在一台**已經裝好**的機器上重跑 `npx claude-mem install --provider claude`（2026-09-22）：

Re-running `npx claude-mem install --provider claude` on a host that already had it (2026-09-22):

| 量測 Measurement | 結果 Result |
|---|---|
| exit code | `0` |
| 耗時 elapsed | 19.5 s |
| `settings.json` 的 **JSON 內容** / its JSON **content** | **完全相同 / identical** (parsed and compared) |
| `settings.json` 的**位元組** / its **bytes** | 變了：2948 → 2843，CRLF 改成 LF / changed: it rewrites CRLF as LF |
| `npx claude-mem start` 在 worker 已經在跑時 / when the worker is already up | exit 0，PID 不變 / same PID |

⚠️ **最後一列那個位元組差異值得知道。** `~/.claude/settings.json` 現在有三個工具會重寫它，各自的慣例不同（`gitnexus setup` 會留 UTF-8 BOM、PowerShell 寫 CRLF、claude-mem 寫 LF）。**內容每次都保住了**，那才是重點；但任何嚴格的 JSON 讀取器都必須容忍 BOM —— 這個 repo 的 [`Tools/deploy.py`](../Tools/deploy.py) 就是為此用 `utf-8-sig` 讀它。

⚠️ **That last row is worth knowing.** Three different tools now rewrite `~/.claude/settings.json`, each with its own convention (`gitnexus setup` leaves a UTF-8 BOM, PowerShell writes CRLF, claude-mem writes LF). **The content survived every time**, which is what matters — but any strict JSON reader has to tolerate the BOM, which is why this repo's [`Tools/deploy.py`](../Tools/deploy.py) reads it with `utf-8-sig`.

---

## 4. 裝完之後怎麼確認 | Checking it afterwards

```powershell
npx claude-mem status     # 一行說 worker 在不在 / one line: is the worker up
npx claude-mem doctor     # 診斷 bun / uv / worker
```

`status` 會印出 PID、port（37777）、版本與 uptime。**記憶注入從一個專案的第二個 session 才開始** —— 第一個 session 正是產生觀察的那個，所以它看不到注入的內容並不是故障。

`status` prints the PID, port (37777), version and uptime. **Memory injection starts from the second session in a project** — the first one is what creates the observations, so seeing nothing injected there is not a fault.

---

## 5. 給 agent 的規則 | The rule for your agent

把 [`claude-md-snippet.zh-TW.md`](claude-md-snippet.zh-TW.md) 或 [`claude-md-snippet.md`](claude-md-snippet.md) 橫線以下的內容貼進專案的 `CLAUDE.md`。它講清楚一件最容易搞錯的事：

Paste everything below the `---` in [`claude-md-snippet.md`](claude-md-snippet.md) into your project's `CLAUDE.md`. It settles the one thing that is easiest to get wrong:

**claude-mem 不是專案的 `Memory/` 資料夾。** 它是本機的、單一帳號的、不進版控的、diff 裡看不到的。待辦、決策、交接一律寫進檔案；claude-mem「記得」不能滿足任何要求書面記錄的規則。

**claude-mem is not the project's `Memory/` folder.** It is local, single-account, not version-controlled and invisible in a diff. Pending items, decisions and handovers go in files; claude-mem having "remembered" something satisfies no rule that asks for a written record.

---

## 6. 移除 | Uninstall

```powershell
npx claude-mem uninstall
```

資料留在 `~/.claude-mem`，要自己刪。 / The data stays in `~/.claude-mem`; remove it yourself if you want it gone.
