# 程式圖譜 MCP 伺服器 | Code-graph MCP servers

**全新 Windows 主機的安裝與設定指南** — 從零裝好並設定兩台程式圖譜 MCP 伺服器：**GitNexus** 與 **code-review-graph**，包含自動更新索引的 hook。

**Setup guide for a fresh Windows host** — installing and configuring both code-graph MCP servers, **GitNexus** and **code-review-graph**, including the hooks that keep their indexes current.

**VSCode Claude Code 擴充功能與 Claude Code CLI 的步驟完全相同。** 兩者共用同一份使用者設定（`%USERPROFILE%\.claude\settings.json` 與 `%USERPROFILE%\.claude.json`），MCP 伺服器與 hook 都註冊在那裡。裝一次，兩邊都生效。

**The steps are identical for the VSCode Claude Code extension and the Claude Code CLI.** Both read the same user configuration, where the MCP servers and hooks are registered. Install once, and both work.

> 文中所有時間數字都是 2026-08-17 在一個**真實專案**（1084 個檔案，其中 302 個是程式碼檔）上實測的結果，不是估計值。換一台機器或換一個專案，數字會不同。
>
> Every timing here was **measured** on 2026-08-17 against a real project (1084 files, 302 of them code files) — not estimated. Another machine or project will differ.

## 佔位符寫法 | Placeholder convention

被 `<角括號>` 包起來的都是**你要自己替換的值**，替換時**連角括號一起換掉**。
Anything in `<angle-brackets>` is a value **you must replace**, brackets included.

| 佔位符 Placeholder | 代表什麼 Meaning | 範例值（僅為範例）Example only |
|---|---|---|
| `<repo-root>` | 你的專案根目錄絕對路徑 / absolute path to your repository | `C:\code\my-project` |
| `<python-path>` | `python.exe` 的絕對路徑 / absolute path to `python.exe` | `%LOCALAPPDATA%\Programs\Python\Python314\python.exe` |
| `<your-username>` | 你的 Windows 帳號名 / your Windows account name | `alice` |
| `<repo-alias>` | 給 daemon 用的短別名 / short alias for the daemon | `myproj` |
| `<dev-workstation-root>` | 這個工具 repo 簽出的位置 / where this tooling repo is checked out | `C:\code\dev-workstation` |
| `<server-name>` | MCP 伺服器名稱 / an MCP server name | `gitnexus` |

**已經存在的環境變數請直接用，不要替換**：`%USERPROFILE%`（cmd／PowerShell 路徑）、`$env:USERPROFILE`（PowerShell 程式碼）、`$USERPROFILE`（Git Bash）。只有 JSON 檔不會展開環境變數，那裡必須寫絕對路徑（`install.ps1` 會自動填好）。

**Existing environment variables are used as-is — do not replace them.** Only JSON files never expand them, so absolute paths are unavoidable there (`install.ps1` fills them in for you).

---

## 0. 兩台伺服器各管什麼 | What each server owns

**兩台都不是永遠的第一順位。** 依問題性質選工具，不要有預設偏好。這張表要寫進你專案的 `CLAUDE.md` / `AGENTS.md`，AI 助手才會照著選 —— 可直接貼的版本在 [`claude-md-snippet.md`](claude-md-snippet.md)（做法見第 6.4 節）。

**Neither server is always first choice.** Pick by the question, with no default preference. This split belongs in your project's `CLAUDE.md` / `AGENTS.md` so your AI assistant follows it — a paste-ready version is in [`claude-md-snippet.md`](claude-md-snippet.md) (section 6.4).

| | code-review-graph | GitNexus |
|---|---|---|
| 負責 Owns | 找符號、看結構、算影響範圍<br>symbol lookup, structure, impact radius | taint、PDG、execution flow、Cypher |
| 代表工具 Signature tools | `query_graph_tool`、`traverse_graph_tool`、`get_impact_radius_tool`、`get_architecture_overview_tool`、`semantic_search_nodes_tool` | `explain`（汙染流 / taint）、`pdg_query`、`query`/`trace`、`cypher`、`rename` |
| 索引位置 Index location | `<repo-root>\.code-review-graph\graph.db` | `<repo-root>\.gitnexus\lbug` |
| 索引範圍 Coverage | **只吃程式碼檔** / code files only（實測專案 301 個） | 全部檔案 / every file（1084 個，含 `docs/*.md`、JSON） |
| 更新速度 Refresh | 存檔後約 2 秒 / ~2s after a save | 完整重建約 142 秒 / ~142s full pass |
| 更新方式 Trigger | 常駐監看 daemon / watch daemon | commit 後觸發 / after a commit |

兩台的資料庫完全獨立，不共用檔案、不搶鎖，所以並存本身不會出問題。**同一個問題不要兩台都問** —— 重複燒 token，換不到更高的確定性。

Their databases are completely separate — no shared files, no lock contention — so coexistence is safe. **Never ask both servers the same question**: it burns tokens without buying certainty.

---

## 1. 前置需求 | Prerequisites

| 需求 Requirement | 最低版本 Minimum | 下限的來源 Where it comes from | 本機實測 Measured here |
|---|---|---|---|
| Node.js | **22.0.0+** | gitnexus `package.json` → `engines.node: ">=22.0.0"` | 24.18.0 |
| npm | 隨 Node 附帶 / ships with Node | — | 12.0.1 |
| Python | **3.10+** | code-review-graph `Requires-Python: >=3.10` | 3.14.6 |
| Git for Windows | 無宣告 / none declared | 需要它內含的 Git Bash 來跑 `post-commit` hook | 2.55.0 |
| Claude Code | 無宣告 / none declared | — | 2.1.228 |

下限不是猜的，是這兩個套件自己宣告的值。**`install.ps1` 會實際比對版本**，不合就擋下來。
These minimums are what the packages declare, not guesses. **`install.ps1` compares the actual versions** and blocks on a mismatch.

**Python 安裝注意**：裝在**使用者目錄**（預設的 `%LOCALAPPDATA%\Programs\Python\Python3xx`）比裝在 `C:\Program Files` 好，後者需要管理員權限才能 `pip install`。安裝時勾選「Add python.exe to PATH」。

**Python install note**: install it **per-user** rather than into `C:\Program Files`, which needs administrator rights for `pip install`. Tick "Add python.exe to PATH".

⚠️ **不要用 Microsoft Store 版的 Python。** 那個是轉接殼，`python -m <module>` 常常抓不到套件，而 MCP 伺服器啟動失敗時只會回報 `MCP error -32000: Connection closed`，完全看不出真因。

⚠️ **Do not use the Microsoft Store build of Python.** It is a shim, `python -m <module>` frequently fails to see installed packages, and the resulting `-32000: Connection closed` hides the real cause.

---

## 2. 最快的做法：跑安裝腳本 | Fastest path: run the installer

```powershell
cd <dev-workstation-root>\graph-servers
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly     # 只檢查環境 / check only
powershell -ExecutionPolicy Bypass -File .\install.ps1                # 機器層級 / machine-wide
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root>   # 專案層級 / per-repo
```

### 前置需求檢查 | The prerequisite gate

**缺什麼就擋下來並給你安裝指令。** 五項工具逐一比對版本，狀態分成 `OK` / `TOO OLD` / `MISSING`；只要有一項不合，它**在安裝任何東西之前就停**（exit code 1），並印出每一項的 `winget install` 指令與官方下載連結。理由：半套設定好的機器比乾淨地停下來更難查。

**It blocks with install instructions if anything is missing.** All five tools are version-compared and reported as `OK` / `TOO OLD` / `MISSING`; a single failure **stops the run before anything is installed** (exit code 1), printing the `winget install` command and download URL for each. A half-configured machine is harder to diagnose than a clean stop.

**它會問你要不要幫你裝** | **It offers to install them**:

```
   Install node, python, git now with winget? [y/N]
```

回答 `y` 就用 winget 裝，裝完**在同一個行程內重建 PATH 並重新檢查**，通過就繼續往下跑，不必重開終端機。按 Enter 或 `n` 就停下來（預設 No，誤按 Enter 不會裝東西）。答了看不懂的字（例如 `yep`）它會再問一次，不會猜。想跳過詢問直接裝就加 `-InstallPrereqs`。**沒有任何情況會默默自動裝。**

Answer `y` and it installs through winget, then **rebuilds PATH in-process and re-checks** — if everything passes it carries on, with no "re-open your terminal" round trip. Enter or `n` stops it (default No). An unrecognised answer such as `yep` is re-asked, never guessed. `-InstallPrereqs` skips the question. **Nothing is ever installed silently.**

⚠️ **stdin 被重導向時（管線、CI、被其他工具啟動）它不會問**，直接當成 No 並印出安裝指令後退出。問一個沒人能回答的問題會永遠卡住，「卡住」比「告訴你要裝什麼」糟糕得多。那種情境請用 `-InstallPrereqs`（把 `y` 用管線餵進去**沒有用**，這是刻意的）。

⚠️ **When stdin is redirected it does not ask** — it treats that as No and exits with the instructions. A prompt nobody can answer would hang forever, and "it hung" is a far worse failure. Use `-InstallPrereqs` there; piping `y` deliberately does **not** work.

### 它怎麼動你的設定檔 | How it edits your config

腳本可重複執行，並且**會自動改好 `settings.json` 與專案的 `CLAUDE.md`**，所以沒有需要手動貼的步驟。做法是保守的：

The script is idempotent and **patches `settings.json` and the project's `CLAUDE.md` for you**, so there is nothing left to paste. It does so conservatively:

1. 先備份成 `<檔名>.bak-<時間戳>`。 / Backs the file up to `<name>.bak-<timestamp>`.
2. 用 `ConvertTo-Json -Depth 100` 寫回。**深度一定要指定** —— 預設只有 2，會把巢狀的 hooks 結構寫成字面的 `System.Object[]`，整個檔案就毀了。 / Writes with `-Depth 100`; the default of 2 serialises nested hooks as the literal string `System.Object[]` and destroys the file.
3. **寫完自我驗證**：能不能解析、`SessionStart` 還是不是 JSON 陣列、有沒有出現 `System.Object[]`、有沒有掉掉任何原本的頂層鍵。任何一項不過就**自動回滾並回報失敗**：原本就有的檔案還原備份；原本不存在、由它新建的檔案則直接刪掉（刪掉才是新建檔案的正確回滾）。 / **Verifies its own output** and on any failure **rolls back**: a pre-existing file is restored from its backup, and a file it had just created is deleted — deleting it IS the correct rollback for a creation.
4. **已存在的值一律保留不覆蓋**，只補缺的。你刻意設過的值不會被改掉，重跑也不會有第二份備份。 / **Never overwrites an existing value**; a re-run produces no second backup.

| 旗標 Flag | 作用 Effect |
|---|---|
| `-CheckOnly` | 只檢查前置需求版本，不安裝任何東西 / check versions only |
| `-InstallPrereqs` | 缺少的前置需求用 winget 自動裝（跳過詢問）/ install missing prerequisites via winget, skipping the question |
| `-SelfTest` | 跑腳本自己的版本解析與答覆判讀測試（18 項斷言），不碰系統 / run the script's own tests (18 assertions), touching nothing |
| `-Repo <repo-root>` | 額外做該專案的步驟（post-commit hook、首次索引、向量、daemon、`CLAUDE.md`）/ also run the per-repo steps |
| `-Pdg` | 首次索引時加 `--pdg`，`explain`（taint）與 `pdg_query` 需要它。會慢很多 / needed by `explain` and `pdg_query`; much slower |
| `-PatchOnly` | 只補設定檔，跳過所有安裝 / patch config files only |
| `-NoSettingsPatch` | 不動 `settings.json`，改成印出 JSON 讓你自己合併 / print the JSON instead |
| `-NoAgentDoc` | 不要寫入專案的 `CLAUDE.md`（見第 6.4 節）/ do not touch the project's `CLAUDE.md` |
| `-AgentDocName AGENTS.md` | 改寫入 `AGENTS.md` / write into `AGENTS.md` instead |
| `-SettingsPath <settings-path>` | 指定要改的設定檔（測試用）/ target another settings file |
| `-SnippetPath <path>` | 改用自訂的規則檔 / use a custom rule file |

⚠️ **它會用 PowerShell 的 JSON 寫入器重排整個檔案的縮排。** 內容不變，但排版會變（PowerShell 5.1 是對齊格式，pwsh 7 是 2 空格）。在意手寫排版就用 `-NoSettingsPatch`。

⚠️ **It reformats the whole JSON file** through PowerShell's writer. Content is preserved, layout changes. Use `-NoSettingsPatch` if you care about your hand-written layout.

想知道每一步在做什麼，或腳本失敗要手動接手，就照第 3～5 節做。
To understand each step, or to take over after a failure, follow sections 3–5.

---

## 3. 安裝 GitNexus（機器層級，做一次）| Install GitNexus (machine-wide, once)

### 3.1 全域安裝 | Global install

```powershell
npm install -g gitnexus
gitnexus --version
```

⚠️ **不要用 `npx gitnexus`。** npm 11.x 有時會在 `npx` 安裝過程中崩潰（`node.target is null`，GitNexus issue #1939）。全域安裝可以完全避開。

⚠️ **Do not rely on `npx gitnexus`.** npm 11.x sometimes crashes during the `npx` install (`node.target is null`, GitNexus issue #1939). A global install avoids it entirely.

### 3.2 註冊到 Claude Code | Register with Claude Code

```powershell
gitnexus setup -c claude-code
```

這一個指令做三件事 | That single command does three things:

1. 在 `%USERPROFILE%\.claude.json` 註冊 MCP 伺服器（User 範圍，指令是 `gitnexus.cmd mcp`）。 / Registers the MCP server (User scope, command `gitnexus.cmd mcp`).
2. 在 `%USERPROFILE%\.claude\settings.json` 寫入兩條 hook（`PreToolUse` 與 `PostToolUse`，跑 `gitnexus-hook.cjs`）：**幫 Grep/Glob/Bash 補上圖譜脈絡**，以及**偵測索引過期並通知**。 / Writes two hook entries that **enrich Grep/Glob/Bash with graph context** and **detect a stale index and notify**.
3. 在專案內產生 `.claude\skills\gitnexus\*`（六個 SKILL.md 使用說明）。 / Generates six SKILL.md usage guides in the project.

驗證 | Verify:

```powershell
claude mcp get gitnexus        # 應顯示 / expect: Scope: User config / Status: Connected
gitnexus doctor               # 執行環境與 embedding 設定 / runtime capabilities and embedding config
```

### 3.3 設定 WAL 檢查點門檻（**重要，別跳過**）| Set the WAL checkpoint threshold (**do not skip**)

```powershell
# 這行寫進 %USERPROFILE%\.claude\settings.json 的 env 區塊（見第 5.2 節）
# goes into the env block of settings.json (section 5.2)
"GITNEXUS_WAL_CHECKPOINT_THRESHOLD": "67108864"
```

**為什麼**：GitNexus 的索引檔（實測專案 215～285 MB）遠大於它預設的自動檢查點門檻（約 16 MB）。門檻太小時，WAL 檢查點輪替會失敗，症狀是：

**Why**: the index file (215–285 MB in the measured project) is far larger than the default auto-checkpoint threshold (~16 MB). Below threshold, checkpoint rotation fails, and the symptoms are:

- `.gitnexus\` 裡不斷長出 `lbug.wal.missing-shadow.*` 這種孤兒檔。 / orphan `lbug.wal.missing-shadow.*` files keep appearing.
- **索引更新會中止，但行程仍然回傳 exit code 0**，看起來像成功。 / **the update aborts while the process still exits 0**, so it looks successful.
- 久了搜尋索引也會壞：`FTS index 'file_fts' is inconsistent`。 / eventually the search index breaks.

2026-08-17 實測：用預設門檻跑 analyze 兩次，兩次都留下 `missing-shadow` 檔且 `meta.json` 的 `lastCommit` 沒更新；改成 64 MiB 之後一次成功，節點數從 14,013 增加到 14,022，也不再產生孤兒檔。

Measured: two analyze runs at the default threshold both left a `missing-shadow` file behind and never updated `lastCommit`; with 64 MiB the next run succeeded, node count rose from 14,013 to 14,022, and no orphan appeared.

[`graph-refresh.ps1`](graph-refresh.ps1) 內部也會自己設這個變數，所以由 git hook 觸發（在 Claude Code 之外）的 analyze 同樣受保護。
[`graph-refresh.ps1`](graph-refresh.ps1) sets it internally too, so an analyze launched by the git hook is protected as well.

---

## 4. 安裝 code-review-graph（機器層級，做一次）| Install code-review-graph (machine-wide, once)

### 4.1 用 extras 安裝 | Install with extras

```powershell
python -m pip install --upgrade "code-review-graph[embeddings,communities]"
python -m pip show code-review-graph
```

| Extra | 帶進什麼 Brings in | 不裝的後果 Consequence of skipping |
|---|---|---|
| `embeddings` | numpy + sentence-transformers | **語意搜尋完全不能用**（向量數 0）/ semantic search does not work at all |
| `communities` | igraph | 退化成較慢的檔案式社群偵測（log 寫 `igraph not available`）/ falls back to slower file-based detection |

其他可選 / other extras：`enrichment`（jedi）、`wiki`（ollama）、`google-embeddings`、`all`。

🔴 **裝了 `embeddings` 就一定要調高 MCP 啟動上限，否則伺服器會連不上。** 這是因果關係，不是巧合：MCP 伺服器**啟動時就會把 sentence-transformer 模型載進記憶體**（實測 27～31 秒），Claude Code 預設只等 **30 秒**，於是報：

🔴 **If you install `embeddings` you MUST raise the MCP startup timeout, or the server fails to connect.** Causal, not coincidental: the server **loads the model at startup** (measured 27–31 s) while Claude Code waits only **30 s**, so it reports:

```
Failed to connect — MCP server "code-review-graph" connection timed out after 30000ms
```

沒裝 embeddings 之前，同一台機器的握手只要 **4.98 秒**。
Before embeddings were installed, the handshake took **4.98 s** on the same machine.

**不能改成延後載入。** 那個預載是作者刻意的，`embeddings.py` 的 `prewarm_local_embeddings()` 註解寫明：Windows 上若讓 `sentence_transformers` + `torch` 在 FastMCP 的工作執行緒裡延後載入，會在 DLL 初始化 / OpenMP 執行緒池註冊時**永久卡死**。正解是把等待上限調高（見第 5.2 節的 `MCP_TIMEOUT`）。

**Lazy loading is not an option.** The eager preload is deliberate: `prewarm_local_embeddings()` documents that on Windows, lazy-loading `sentence_transformers` + `torch` inside a FastMCP executor thread **blocks indefinitely** on DLL init / OpenMP registration. The fix is to raise the client's wait (`MCP_TIMEOUT`, section 5.2).

設 `HF_HUB_OFFLINE=1` 只省 3.5 秒（31.33 → 27.83 秒），主要成本是模型載入本身不是網路；而且新機器上模型還沒下載時設它會直接壞掉，所以本指南不建議設。

`HF_HUB_OFFLINE=1` saves only 3.5 s (31.33 → 27.83) — the cost is the model load, not the network — and it breaks the first run on a host where the model is not cached. Not recommended.

### 4.2 確認是「同一個」Python 能 import | Confirm the SAME python can import it

```powershell
python -c "import code_review_graph, sentence_transformers; print('import ok')"
where.exe python
```

⚠️ **這是最常見的失敗點。** MCP 伺服器是用**寫死在設定裡的那個 python.exe 絕對路徑**啟動的。如果那個路徑不存在，或那個 Python 沒裝套件，Claude Code 只會說 `MCP error -32000: Connection closed`。本機就踩過一次：設定裡寫 `C:\Program Files\Python314\python.exe`，實際卻裝在 `%LOCALAPPDATA%\Programs\Python\Python314\`。

⚠️ **This is the most common failure.** The server launches from an **absolute python.exe path stored in the config**; if it does not exist or lacks the package, Claude Code only says `MCP error -32000: Connection closed`. It happened here: the config said `C:\Program Files\Python314\python.exe` while the real install was elsewhere.

如果 `python` 指到錯的解譯器，設使用者環境變數 `CRG_PYTHON` 指向正確的 `python.exe`，[`graph-refresh.ps1`](graph-refresh.ps1) 會優先採用它。
If `python` resolves to the wrong interpreter, set `CRG_PYTHON`; [`graph-refresh.ps1`](graph-refresh.ps1) prefers it.

### 4.3 註冊到 Claude Code（**手動，別用它的 installer**）| Register by hand, not with its installer

```powershell
claude mcp add -s user code-review-graph -- "<python-path>" -m code_review_graph serve
claude mcp get code-review-graph
```

⚠️ **不要跑 `code-review-graph install --platform claude-code`。** 它的 dry-run 顯示會做兩件你不想要的事：在**專案根目錄寫一個 `.mcp.json`**（進版控、影響其他人），以及**把它自己的說明文字 append 到 `CLAUDE.md`**。手動註冊在 User 範圍就沒有這些副作用。

⚠️ **Do not run `code-review-graph install --platform claude-code`.** Its dry-run shows it would write a **`.mcp.json` in the project root** (version-controlled, affects everyone) and **append its own instructions to `CLAUDE.md`**. A manual User-scope registration has neither side effect.

---

## 5. 設定自動更新（機器層級）| Configure automatic refresh (machine-wide)

> 跑過第 2 節的 `install.ps1` 就**整節都做完了**。本節是手動等價步驟，供你想自己來、或想看懂它改了什麼時參考。
>
> `install.ps1` **completes this entire section**. What follows is the manual equivalent, for doing it yourself or understanding what the script changed.

### 5.1 安裝 hook 腳本 | Install the hook script

```powershell
copy graph-servers\graph-refresh.ps1 %USERPROFILE%\.claude\hooks\
```

### 5.2 合併進 settings.json | Merge into settings.json

把下面內容**合併**（不是覆寫）進 `%USERPROFILE%\.claude\settings.json`，並把路徑換成你的。
**Merge** (do not overwrite) this into `%USERPROFILE%\.claude\settings.json`, fixing the path.

```json
{
  "env": {
    "GITNEXUS_WAL_CHECKPOINT_THRESHOLD": "67108864",
    "MCP_TIMEOUT": "120000",
    "MCP_CONNECT_TIMEOUT_MS": "120000"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\<your-username>\\.claude\\hooks\\graph-refresh.ps1\" -Which both -Detach",
            "timeout": 10,
            "statusMessage": "Queueing code-graph refresh..."
          }
        ]
      }
    ]
  }
}
```

| 變數 Variable | 為什麼要設 Why it is needed |
|---|---|
| `GITNEXUS_WAL_CHECKPOINT_THRESHOLD` | 見第 3.3 節。不設會靜靜損壞 GitNexus 索引 / without it the index corrupts silently |
| `MCP_TIMEOUT` | 見第 4.1 節。不設，code-review-graph 會因為載入模型超時而連不上 / without it code-review-graph times out while loading its model |
| `MCP_CONNECT_TIMEOUT_MS` | 同上。兩個都設是因為我沒能從程式裡確定是哪一個在管那 30 秒；兩個都是 Claude Code 認得的變數，多設一個無害 / both are set because I could not confirm which one governs the 30 s timeout; both are recognised, so the extra one is harmless |

`gitnexus setup` 已經在同一個檔案寫了它自己的 `PreToolUse` / `PostToolUse` 條目，**不要覆蓋掉**。改完確認 JSON 沒壞：
`gitnexus setup` already wrote its own entries there — **do not overwrite them**. Check the JSON afterwards:

```powershell
Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json | Out-Null; "JSON OK"
```

### 5.3 為什麼沒有「每次 Edit 就更新」的 hook | Why there is no per-Edit hook

實測結論：**`cmd /c start /b` 在 Windows 上不會真的斷開。** 子行程繼承了 hook 的 stdin 管線，呼叫方還是得等整個更新跑完。

Measured: **`cmd /c start /b` does not truly detach on Windows.** The child inherits the hook's stdin pipe, so the caller waits for the whole refresh anyway.

| 寫法 Approach | 每次 Edit 的阻塞 Blocking per Edit |
|---|---|
| 完全同步 / fully synchronous | 3940 ms |
| `cmd /c start /b`（看起來像背景，其實不是 / looks detached, is not） | 3960 ms |
| `Start-Process -WindowStyle Hidden`（本腳本採用 / used by this script） | **804 ms** |
| **改用常駐 daemon（現行做法）/ watch daemon instead (current design)** | **0 ms** |

所以 `Edit`/`Write` 的 PostToolUse hook 整條拿掉了，改由 code-review-graph 自己的監看 daemon 負責。防抖 0.3 秒，存檔後約 2 秒反映到圖譜。

So the `Edit`/`Write` PostToolUse hook was removed entirely; the watch daemon does the job with a 0.3s debounce, reaching the graph about 2 seconds after a save.

### 5.4 三個觸發點 | The three triggers

| 時機 When | 觸發者 Trigger | 做什麼 What | 阻塞 Cost |
|---|---|---|---|
| 存檔（任何編輯器）/ save, any editor | code-review-graph daemon | 更新 code-review-graph | **0 ms** |
| `git commit` | `.git\hooks\post-commit` | 跑 GitNexus analyze | ~1.2 s |
| 開新 session / new session | `SessionStart` hook | 確保 daemon 活著 + 補跑遺漏 + GitNexus 閘門 / ensure daemon, catch-up, gated analyze | ~0.9 s |

GitNexus 那條有**閘門**：只有 `.gitnexus\meta.json` 的 `lastCommit` 不等於 `HEAD` 時才真的跑。索引已是最新時，它 820 毫秒就返回、不啟動任何 node 行程 —— 不會每開一個 session 白燒 142 秒。SessionStart 那條要留著，因為 `git pull` 帶進新 commit 時沒有本地 commit，`post-commit` 不會被觸發。

The GitNexus path is **gated** on `lastCommit` differing from `HEAD`: with a current index it returns in 820 ms and starts no node process, so a new session never wastes 142 seconds. Keep the SessionStart entry — `git pull` brings in commits without a local commit, so `post-commit` never fires for them.

---

## 6. 每個專案要做的事 | Per-repository steps

### 6.1 第一次索引 | First index

```powershell
cd <repo-root>
gitnexus analyze                     # 需要 taint/PDG 就加 --pdg / add --pdg for taint/PDG
python -m code_review_graph build --repo .
python -m code_review_graph embed --repo .
```

⚠️ **`gitnexus analyze` 就算失敗也回傳 exit code 0。** 一定要看輸出文字，找 `Analysis failed`。本機踩過兩次：exit 0，但索引根本沒更新。

⚠️ **`gitnexus analyze` exits 0 even when it fails.** Read the output text for `Analysis failed`. It happened twice here: exit 0, index untouched.

### 6.2 安裝 post-commit hook | Install the post-commit hook

```powershell
copy graph-servers\post-commit <repo-root>\.git\hooks\post-commit
bash -c "chmod +x .git/hooks/post-commit"
```

先確認沒有覆蓋別的東西 | Check you are not clobbering something:

```powershell
git config core.hooksPath          # 有輸出就代表 hook 目錄被改到別處 / any output means hooks live elsewhere
dir .git\hooks | findstr /v sample
```

⚠️ **`.git\hooks\` 不進版控。** 別台機器 clone 之後不會有這個 hook，要在那邊重裝。
⚠️ **`.git\hooks\` is not version-controlled.** A fresh clone will not have it; re-install there.

### 6.3 啟動監看 daemon | Start the watch daemon

```powershell
python -m code_review_graph daemon add <repo-root> --alias <repo-alias>
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\hooks\graph-refresh.ps1" -Which crg -Repo <repo-root> -Detach
python -m code_review_graph daemon status
```

⚠️ **不要直接跑 `daemon start`。** 它會印「Forking is not supported on Windows — running in foreground」然後卡在前景，終端機一關它就死。要透過 `graph-refresh.ps1 -Detach`（內部用 `Start-Process -WindowStyle Hidden`）啟動，它才能跨 session 存活。重開機後會死，下一次 SessionStart 會自動復活。

⚠️ **Do not run `daemon start` directly.** It prints "Forking is not supported on Windows — running in foreground" and blocks; closing the terminal kills it. Launch it through `graph-refresh.ps1 -Detach` so it survives across sessions. It dies on reboot, and the next SessionStart revives it.

### 6.4 告訴 AI 助手怎麼用這兩台（**別跳過**）| Tell your AI agent how to use them (**do not skip**)

裝好伺服器**不等於** AI 助手會正確使用它們。沒有明文規則，它會挑先看到的那台、把同一個問題問兩台燒雙倍 token、並且相信一份過期的索引給你錯答案。

Installing the servers does **not** mean an agent uses them correctly. Without a written rule it picks whichever tool it saw first, asks both the same question at double the token cost, and trusts a stale index to give you a wrong answer.

**`install.ps1 -Repo <repo-root>` 會自動寫進去** | **the installer writes it for you**:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -PatchOnly -Repo <repo-root>
```

它把規則包在自己的標記裡（`<!-- code-graph-servers:start -->` … `end`）：**重跑會就地更新**，不累積第二份；**標記外的內容一個字都不動**（寫完驗證，不通過就回滾）；`CLAUDE.md` 不存在就幫你建。規則文字**只有一份來源** —— [`claude-md-snippet.md`](claude-md-snippet.md) 橫線以下的部分，改那裡再重跑即可。要寫進 `AGENTS.md` 就加 `-AgentDocName AGENTS.md`；完全不要它動就加 `-NoAgentDoc`。

It wraps the rule in its own markers, so a re-run **updates in place** instead of adding a copy, **nothing outside them changes** (verified, rolled back on failure), and a missing `CLAUDE.md` is created. The rule text has a **single source**: everything below the `---` in [`claude-md-snippet.md`](claude-md-snippet.md). Use `-AgentDocName AGENTS.md` to target that file, `-NoAgentDoc` to skip.

⚠️ **你的專案如果已經手寫過同樣的規則**，腳本不認得那份（沒有標記），會再加一份造成重複。這種情況用 `-NoAgentDoc`，或先把手寫那份刪掉。

⚠️ **If your project already carries the rule written by hand**, the script cannot recognise it (no markers) and adds a second copy. Use `-NoAgentDoc`, or delete the hand-written one first.

規則內容包含 | The rule covers:

- 按能力分工，並明寫**兩台都不是永遠的第一順位**。 / the split by capability, stating neither is always first choice.
- 兩台的**新鮮度差異**：code-review-graph 每次呼叫重讀資料庫（當場生效）；GitNexus 把索引快取在伺服器啟動那一刻（要下一個工作階段）。 / the freshness difference: live per call vs cached at server startup.
- 五個會導致錯答案的前提：未 commit 的程式不在 GitNexus 圖譜裡、非程式碼檔只有 GitNexus 有、語意搜尋需要向量而 daemon 不補向量、`analyze` 失敗也回傳 exit 0、`search` 的輸出會回顯查詢字串。 / five preconditions that otherwise produce wrong answers.

⚠️ **必須在 `<!-- gitnexus:start -->` … `<!-- gitnexus:end -->` 標記之外。** 那段是 `gitnexus setup` 產生的，下一次 `analyze` 會**整段覆蓋**。腳本會**附加在該段之後**（實測驗證過位置），而且如果偵測到我們的標記已經落在 gitnexus 標記裡面（起點或終點任一），它會**拒絕寫入並要你先搬出來**。那段還寫著「改任何符號前一律先跑 GitNexus `impact`」，跟本分工牴觸 —— snippet 裡已明寫「那一句以本條為準」。

⚠️ **It must live OUTSIDE the `<!-- gitnexus:start/end -->` markers**, which `gitnexus setup` regenerates and the next `analyze` overwrites. The script appends **after** that block (position verified by test) and **refuses to write** if our markers already sit inside the gitnexus ones (either end). That block also says "always run GitNexus `impact` before editing a symbol", which the snippet explicitly supersedes.

### 6.5 不用改 `.gitignore` | No `.gitignore` edit needed

兩個工具都會在自己的資料夾裡放一個內容為 `*` 的 `.gitignore`，自我忽略。`git status` 看不到它們，**不要再手動加規則**。

Both tools drop a `.gitignore` containing `*` inside their own folder, so they ignore themselves. `git status` never shows them — **do not add rules by hand**.

---

## 7. 驗證清單（每項都是 5 秒指令）| Verification checklist (five seconds each)

```powershell
# 兩台都連上了嗎 / are both servers connected
claude mcp list

# GitNexus 索引跟得上 HEAD 嗎 / is the GitNexus index level with HEAD
python -c "import json;print(json.load(open('.gitnexus/meta.json',encoding='utf-8'))['lastCommit'][:12])"
git rev-parse HEAD

# 有沒有 WAL 孤兒檔（正常 0 個）/ any WAL orphans (expect none)
dir .gitnexus\lbug.wal.missing-shadow.* 2>nul

# code-review-graph 統計 + 是否對齊 HEAD / stats and whether it matches HEAD
python -m code_review_graph status --repo .

# 語意搜尋的向量數（0 就是不能用）/ vector count (0 means unusable)
python -c "import sqlite3;print(sqlite3.connect(r'.code-review-graph/graph.db').execute('select count(*) from embeddings').fetchone())"

# daemon 活著嗎 / is the daemon alive
python -m code_review_graph daemon status

# hook 腳本的失敗記錄 / failure log from the hook script
type %TEMP%\claude-graph-refresh.log
```

---

## 8. 踩過的坑（全部 2026-08-17 實證）| Pitfalls (all evidenced 2026-08-17)

### 8.1 `MCP error -32000: Connection closed`
設定裡的 `python.exe` 路徑不存在。用 `claude mcp get <server-name>` 看實際路徑，再用 `where.exe python` 對照。
The `python.exe` path in the config does not exist. Compare `claude mcp get <server-name>` against `where.exe python`.

### 8.2 `connection timed out after 30000ms`
**先問：有沒有裝 `embeddings` extra？** 有的話這就是原因（見第 4.1 節）：載入模型要 27～31 秒，超過預設的 30 秒。修法是把 `MCP_TIMEOUT` / `MCP_CONNECT_TIMEOUT_MS` 設成 `120000`。

**First question: is the `embeddings` extra installed?** If yes, that is the cause (section 4.1): the model load takes 27–31 s, past the 30 s default. Set `MCP_TIMEOUT` / `MCP_CONNECT_TIMEOUT_MS` to `120000`.

沒裝 embeddings 卻還是超時：實測正常握手只要 **4.98 秒**，遠低於上限，別急著改設定。這種情況本機重現不出來，最可能是啟動那一刻 CPU/硬碟被其他工作（Gradle build、Defender 掃描）佔滿。要抓真因就跑 `claude --debug mcp`。自己量握手時間的方法：用 stdio 送一個 `initialize` 請求，量到第一行 stdout 的時間。

Without embeddings, a normal handshake measured **4.98 s**, so do not rush to change the config; that case was not reproducible here and the likeliest cause is CPU/disk saturation at startup. Run `claude --debug mcp` for the real cause. To measure it yourself: write one `initialize` request to the server's stdin and time the first stdout line.

### 8.3 `FTS index 'file_fts' is inconsistent`
```powershell
gitnexus analyze --repair-fts
```
不必刪整個索引。`gitnexus clean` 會把 `.gitnexus\` 整個刪掉（包含 `run.cjs`），代價大得多。
No need to delete the whole index. `gitnexus clean` removes all of `.gitnexus\` including `run.cjs`, which costs far more.

### 8.4 `lbug.wal.missing-shadow.*` 一直長出來 | files keep appearing
WAL 檢查點門檻太小。見第 3.3 節。刪掉那些孤兒檔前先確認沒有 analyze 正在跑。
The WAL checkpoint threshold is too small (section 3.3). Make sure no analyze is running before deleting the orphans.

### 8.5 exit code 0 會騙人 | Exit code 0 lies
`gitnexus analyze` 失敗時仍回傳 0。判斷成功要看**輸出文字**與 `meta.json` 的 `lastCommit`，不要看 exit code。
It returns 0 on failure. Judge success from the **output text** and `lastCommit` in `meta.json`, never from the exit code.

### 8.6 `daemon start` 卡住不放 | hangs
Windows 不支援 fork。見第 6.3 節。 / Windows cannot fork. See section 6.3.

### 8.7 語意搜尋抓不到剛改的程式 | Semantic search misses fresh code
**daemon 不會補向量。** 實測：新函式 15 秒內進 `nodes` 表，同一時間 `embeddings` 表是 **0 筆**。它不報錯，只會安靜地漏掉。大幅改動後手動重跑：

**The daemon does not compute embeddings.** Measured: a new function reached `nodes` within 15 s while `embeddings` stayed at **0 rows**. It does not error — it silently misses. Re-run after substantial changes:

```powershell
python -m code_review_graph embed --repo .
```

### 8.8 用 `search` 輸出判斷符號存不存在會得到假陽性 | search output gives false positives
`code-review-graph search` 的 JSON 會**回顯查詢字串**（`"query": "你查的字"`），所以拿字串比對輸出時，一個根本不存在的符號也會「命中」。要判斷節點在不在，直接查資料庫：

Its JSON **echoes the query string**, so a string match against the output "finds" a symbol that does not exist. Query the database instead:

```powershell
python -c "import sqlite3;print(sqlite3.connect(r'.code-review-graph/graph.db').execute(\"select count(*) from nodes where name like '%your_symbol%'\").fetchone())"
```

### 8.9 別用 `graph.db` 的檔案時間判斷有沒有更新 | Do not judge freshness from the file timestamp
SQLite 可能在既有頁面內寫入，主檔的 mtime 不一定改變。實測：metadata 已寫入 `10:41:07`，但檔案 mtime 還停在 `10:18:18`，看起來像「完全沒跑」。要判斷新鮮度看 metadata：

SQLite can write inside existing pages, so the mtime does not always change. Measured: the metadata read `10:41:07` while the mtime still read `10:18:18` — which looks exactly like "it never ran". Read the metadata instead:

```powershell
python -m code_review_graph status --repo .    # 看 / read the Last updated line
```

同一類錯誤今天發生三次（另外兩次見 8.8 與 5.3），共同教訓：**確認一件事之前，先確認你的量測工具真的在量那件事。**
This class of mistake happened three times in one day (see also 8.8 and 5.3). The lesson: **before trusting a check, confirm the instrument measures what you think it measures.**

### 8.10 CLAUDE.md 裡的 GitNexus 段落不要手改 | Do not hand-edit the generated GitNexus block
它夾在 `<!-- gitnexus:start -->` 與 `<!-- gitnexus:end -->` 之間，**由 gitnexus CLI 自動產生**，下一次 `analyze` 會整段覆蓋。要改規則就改標記之外的地方。
It sits between the markers, is **generated by the gitnexus CLI**, and the next `analyze` overwrites the whole block. Put rule changes outside the markers.

### 8.11 兩台伺服器的索引快取行為不一樣 | The two servers cache differently

| | 索引更新後 After the index is refreshed |
|---|---|
| code-review-graph | **當場生效**（每次呼叫重讀資料庫）/ **live** (re-reads the database per call) |
| GitNexus | **要到下一個 session**（索引快取在伺服器啟動的瞬間）/ **next session only** (cached at server startup) |

所以 commit 後跑完的 GitNexus analyze，當前 session 看不到新結果，要 `/mcp` 重連或開新 session。
So a GitNexus analyze that finishes after a commit is invisible to the current session; reconnect with `/mcp` or start a new one.

### 8.12 資料夾改名或搬移被拒（`being used by another process`）| Renaming or moving a folder fails
**監看 daemon 在 Windows 上持有目錄句柄。** 它用 watchdog 遞迴監看整個 repo，所以被監看樹裡的任何資料夾都不能改名或搬移。

**The watch daemon holds directory handles on Windows.** It watches the whole repo recursively, so nothing inside the watched tree can be renamed or moved.

先停、再搬、再啟動 | Stop, move, restart:

```powershell
python -m code_review_graph daemon stop
Move-Item <old-path> <new-path>
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\hooks\graph-refresh.ps1" -Which crg -Repo <repo-root> -Detach
```

同樣的原因也會擋掉 `git worktree remove`、刪除資料夾、以及部分 IDE 的重構搬檔操作。
The same cause blocks `git worktree remove`, folder deletion, and some IDE refactor-move operations.

---

## 9. 移除 | Uninstall

```powershell
gitnexus uninstall                        # 移除 MCP 條目、skills、hooks / removes MCP entries, skills, hooks
claude mcp remove code-review-graph -s user
python -m code_review_graph daemon stop
python -m code_review_graph uninstall     # 移除它的資料、設定、hooks、skills / removes its data, configs, hooks, skills
```

再手動清掉：`%USERPROFILE%\.claude\hooks\graph-refresh.ps1`、`<repo-root>\.git\hooks\post-commit`、`settings.json` 裡的 `SessionStart` 條目與 `env` 那幾行、以及專案 `CLAUDE.md` 裡 `<!-- code-graph-servers:start/end -->` 之間的區塊。

Then remove by hand: `%USERPROFILE%\.claude\hooks\graph-refresh.ps1`, `<repo-root>\.git\hooks\post-commit`, the `SessionStart` entry and `env` lines in `settings.json`, and the `<!-- code-graph-servers:start/end -->` block in the project's `CLAUDE.md`.

---

## 10. 本目錄的檔案 | Files in this directory

| 檔案 File | 用途 Purpose |
|---|---|
| [`install.ps1`](install.ps1) | 一次做完機器層級 + 專案層級安裝，可重複執行 / machine-wide + per-repo install, idempotent |
| [`graph-refresh.ps1`](graph-refresh.ps1) | hook 用的更新腳本（主複本；安裝到 `~\.claude\hooks\`）/ the refresh script used by the hooks (master copy) |
| [`post-commit`](post-commit) | git hook 主複本（安裝到 `<repo-root>\.git\hooks\`）/ git hook master copy |
| [`claude-md-snippet.md`](claude-md-snippet.md) | 貼進你專案 `CLAUDE.md` 的分工規則（見第 6.4 節）/ the usage rule for your project's `CLAUDE.md` (section 6.4) |
| `README.md` | 本文件（中英雙語）/ this document (bilingual) |
