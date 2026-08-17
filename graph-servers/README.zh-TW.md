# 程式圖譜 MCP 伺服器 —— 全新 Windows 主機安裝指南

英文版:[`README.en.md`](README.en.md)

本文件說明如何在**一台全新的 Windows 開發主機**上，從零裝好並設定兩台程式圖譜 MCP 伺服器：**GitNexus** 與 **code-review-graph**，包含自動更新索引的 hook。

**VSCode Claude Code 擴充功能與 Claude Code CLI 的安裝步驟完全相同。** 兩者共用同一份使用者設定（`%USERPROFILE%\.claude\settings.json` 與 `%USERPROFILE%\.claude.json`），MCP 伺服器與 hook 都註冊在那裡。裝一次，兩邊都生效。

> 文中所有時間數字都是 2026-08-17 在一個**真實專案**（1084 個檔案，其中 302 個是程式碼檔）上實測的結果，不是估計值。換一台機器或換一個專案，數字會不同。

**佔位符寫法**：文中被 `<角括號>` 包起來的都是**你要自己替換的值**，替換時**連角括號一起換掉**。例如把 `<repo-root>` 換成 `C:\code\my-project`。

| 佔位符 | 代表什麼 | 範例值（僅為範例） |
|---|---|---|
| `<repo-root>` | 你的專案根目錄絕對路徑 | `C:\code\my-project` |
| `<python-path>` | `python.exe` 的絕對路徑 | `%LOCALAPPDATA%\Programs\Python\Python314\python.exe` |
| `<your-username>` | 你的 Windows 帳號名 | `alice` |
| `<repo-alias>` | 給 daemon 用的短別名 | `myproj` |
| `<dev-workstation-root>` | 這個工具 repo 簽出的位置 | `C:\code\dev-workstation` |
| `<server-name>` | MCP 伺服器名稱 | `gitnexus` |

**已經存在的環境變數請直接用，不要替換**：`%USERPROFILE%`（cmd／PowerShell 路徑）、`$env:USERPROFILE`（PowerShell 程式碼）、`$USERPROFILE`（Git Bash）。只有 JSON 檔不會展開環境變數，所以那裡必須寫絕對路徑（`install.ps1` 會自動幫你填好）。

---

## 0. 兩台伺服器各管什麼

**兩台都不是永遠的第一順位。** 依問題性質選工具，不要有預設偏好。這張表要寫進你專案的 `CLAUDE.md` / `AGENTS.md`，AI 助手才會照著選 —— 可直接貼的版本在 [`claude-md-snippet.md`](claude-md-snippet.md)（做法見第 6.4 節）。

| | code-review-graph | GitNexus |
|---|---|---|
| 負責 | 找符號、看結構、算影響範圍 | taint、PDG、execution flow、Cypher |
| 代表工具 | `query_graph_tool`、`traverse_graph_tool`、`get_impact_radius_tool`、`get_architecture_overview_tool`、`semantic_search_nodes_tool` | `explain`（汙染流）、`pdg_query`、`query`/`trace`、`cypher`、`rename` |
| 索引位置 | `<repo-root>\.code-review-graph\graph.db` | `<repo-root>\.gitnexus\lbug` |
| 索引範圍 | **只吃程式碼檔**（實測專案 301 個） | 全部檔案（實測專案 1084 個，含 `docs/*.md`、JSON） |
| 更新速度 | 存檔後約 2 秒 | 完整重建約 142 秒 |
| 更新方式 | 常駐監看 daemon | commit 後觸發 |

兩台的資料庫完全獨立，不共用檔案、不搶鎖，所以並存本身不會出問題。**同一個問題不要兩台都問** —— 重複燒 token，換不到更高的確定性。

---

## 1. 前置需求

| 需求 | 最低版本 | 下限的來源 | 本機實測版本 |
|---|---|---|---|
| Node.js | **22.0.0 以上** | gitnexus 的 `package.json` → `engines.node: ">=22.0.0"` | 24.18.0 |
| npm | 隨 Node 附帶 | —— | 12.0.1 |
| Python | **3.10 以上** | code-review-graph 的 `Requires-Python: >=3.10` | 3.14.6 |
| Git for Windows | 無宣告 | 需要它內含的 Git Bash 來跑 `post-commit` hook | 2.55.0 |
| Claude Code | 無宣告 | —— | 2.1.228 |

下限不是我猜的，是這兩個套件自己宣告的值。**`install.ps1` 會實際比對版本**，不合就擋下來（見下節）。

**Python 安裝注意**：裝在**使用者目錄**（預設的 `%LOCALAPPDATA%\Programs\Python\Python3xx`）比裝在 `C:\Program Files` 好，後者需要管理員權限才能 `pip install`。安裝時勾選「Add python.exe to PATH」。

⚠️ **不要用 Microsoft Store 版的 Python。** 那個是轉接殼，`python -m <module>` 常常抓不到套件，而 MCP 伺服器啟動失敗時只會回報 `MCP error -32000: Connection closed`，完全看不出真因。

---

## 2. 最快的做法：跑安裝腳本

```powershell
cd <dev-workstation-root>\graph-servers
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly     # 先只檢查環境
powershell -ExecutionPolicy Bypass -File .\install.ps1                # 機器層級安裝
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root>   # 再做專案層級
```

**它會先檢查前置需求，缺什麼就擋下來並給你安裝指令。** 五項工具逐一比對版本，狀態分成 `OK` / `TOO OLD` / `MISSING`；只要有一項不合，它**在安裝任何東西之前就停**（exit code 1），並印出每一項的 `winget install` 指令與官方下載連結。理由：半套設定好的機器比乾淨地停下來更難查。

**它會問你要不要幫你裝**：偵測到缺少時顯示

```
   Install node, python, git now with winget? [y/N]
```

回答 `y` 就用 winget 裝，裝完**在同一個行程內重建 PATH 並重新檢查**，通過就繼續往下跑，不必重開終端機。按 Enter 或 `n` 就照原樣停下來（預設是 No，所以誤按 Enter 不會裝東西）。答了看不懂的字（例如 `yep`）它會再問一次，不會猜。

想跳過詢問直接裝就加 `-InstallPrereqs`。**沒有任何情況會默默自動裝** —— 在別人的機器上不問就裝系統層級的 runtime 不是好行為，而且可能跟既有的 nvm／pyenv 或公司政策衝突。

⚠️ **stdin 被重導向時（管線、CI、被其他工具啟動）它不會問**，直接當成 No 並印出安裝指令後退出。理由：問一個沒人能回答的問題會永遠卡住，「卡住」比「告訴你要裝什麼」糟糕得多。那種情境請用 `-InstallPrereqs`（把 `y` 用管線餵進去**沒有用**，這是刻意的）。

腳本可重複執行，包含**自動改好 `settings.json`**（第 5 節那些環境變數與 SessionStart hook），所以沒有需要手動貼 JSON 的步驟。

它動設定檔的方式是**保守的**：

1. 先備份成 `settings.json.bak-<時間戳>`。
2. 用 `ConvertTo-Json -Depth 100` 寫回。**深度一定要指定** —— 預設只有 2，會把巢狀的 hooks 結構寫成字面的 `System.Object[]`，整個檔案就毀了。
3. **寫完自我驗證**：能不能解析、`SessionStart` 還是不是 JSON 陣列、有沒有出現 `System.Object[]`、有沒有掉掉任何原本的頂層鍵。任何一項不過就**自動回滾並回報失敗**:原本就有的檔案還原備份;原本不存在、由它新建的檔案則直接刪掉(刪掉才是新建檔案的正確回滾)。
4. **已存在的值一律保留不覆蓋**，只補缺的。所以你刻意設過的值不會被它改掉，重跑也不會有第二份備份。

| 旗標 | 作用 |
|---|---|
| `-CheckOnly` | 只檢查前置需求版本，不安裝任何東西 |
| `-InstallPrereqs` | 缺少的前置需求用 winget 自動裝（預設不自動裝） |
| `-SelfTest` | 跑腳本自己的版本解析與比較測試（18 項斷言），不碰系統 |
| `-Repo <repo-root>` | 額外做該專案的步驟（post-commit hook、首次索引、向量、daemon） |
| `-Pdg` | 首次索引時加 `--pdg`，`explain`（taint）與 `pdg_query` 需要它。會慢很多 |
| `-PatchOnly` | 只補 `settings.json`，跳過所有安裝 |
| `-NoSettingsPatch` | 不動設定檔，改成把 JSON 印出來讓你自己合併 |
| `-NoAgentDoc` | 不要寫入專案的 `CLAUDE.md`（見第 6.4 節） |
| `-AgentDocName AGENTS.md` | 改寫入 `AGENTS.md` 而非 `CLAUDE.md` |
| `-SettingsPath <settings-path>` | 指定要改的設定檔（測試用） |
| `-SnippetPath <path>` | 改用自訂的規則檔取代 `claude-md-snippet.md` |

⚠️ **它會用 PowerShell 的 JSON 寫入器重排整個檔案的縮排。** 內容不變，但排版會變（Windows PowerShell 5.1 排出來的對齊格式比較醜；用 pwsh 7 跑是 2 空格）。如果你很在意手寫的排版，就用 `-NoSettingsPatch` 自己貼。

想知道每一步在做什麼，或腳本失敗要手動接手，就照下面第 3～5 節做。

---

## 3. 安裝 GitNexus（機器層級，做一次）

### 3.1 全域安裝

```powershell
npm install -g gitnexus
gitnexus --version
```

⚠️ **不要用 `npx gitnexus`。** npm 11.x 有時會在 `npx` 安裝過程中崩潰（`node.target is null`，GitNexus issue #1939）。全域安裝可以完全避開。

### 3.2 註冊到 Claude Code

```powershell
gitnexus setup -c claude-code
```

這一個指令做三件事：

1. 在 `%USERPROFILE%\.claude.json` 註冊 MCP 伺服器（User 範圍，指令是 `gitnexus.cmd mcp`）。
2. 在 `%USERPROFILE%\.claude\settings.json` 寫入兩條 hook（`PreToolUse` 與 `PostToolUse`，跑 `gitnexus-hook.cjs`）。它們的作用是**幫 Grep/Glob/Bash 補上圖譜脈絡**，以及**偵測索引過期並通知**。
3. 在專案內產生 `.claude\skills\gitnexus\*`（六個 SKILL.md 使用說明）。

驗證：

```powershell
claude mcp get gitnexus        # 應顯示 Scope: User config / Status: Connected
gitnexus doctor               # 顯示執行環境與 embedding 設定
```

### 3.3 設定 WAL 檢查點門檻（**重要，別跳過**）

```powershell
# 這行寫進 %USERPROFILE%\.claude\settings.json 的 env 區塊（見第 5 節）
"GITNEXUS_WAL_CHECKPOINT_THRESHOLD": "67108864"
```

**為什麼**：GitNexus 的索引檔（實測專案 215～285 MB）遠大於它預設的自動檢查點門檻（約 16 MB）。門檻太小時，WAL 檢查點輪替會失敗，症狀是：

- `.gitnexus\` 裡不斷長出 `lbug.wal.missing-shadow.*` 這種孤兒檔。
- **索引更新會中止，但行程仍然回傳 exit code 0**，看起來像成功。
- 久了搜尋索引也會壞：`FTS index 'file_fts' is inconsistent`。

本機 2026-08-17 實測：用預設門檻跑 analyze 兩次，兩次都留下 `missing-shadow` 檔且 `meta.json` 的 `lastCommit` 沒更新；改成 64 MiB 之後一次成功，節點數從 14,013 增加到 14,022，也不再產生孤兒檔。

[`graph-refresh.ps1`](graph-refresh.ps1) 內部也會自己設這個變數，所以由 git hook 觸發（在 Claude Code 之外）的 analyze 同樣受保護。

---

## 4. 安裝 code-review-graph（機器層級，做一次）

### 4.1 用 extras 安裝

```powershell
python -m pip install --upgrade "code-review-graph[embeddings,communities]"
python -m pip show code-review-graph
```

| Extra | 帶進什麼 | 不裝的後果 |
|---|---|---|
| `embeddings` | numpy + sentence-transformers | **語意搜尋完全不能用**（向量數 0） |
| `communities` | igraph | 退化成較慢的檔案式社群偵測（log 會寫 `igraph not available`） |

其他可選：`enrichment`（jedi）、`wiki`（ollama）、`google-embeddings`、`all`。

🔴 **裝了 `embeddings` 就一定要調高 MCP 啟動上限，否則伺服器會連不上。** 這是因果關係，不是巧合：

裝了之後，MCP 伺服器**啟動時就會把 sentence-transformer 模型載進記憶體**（實測 27～31 秒），Claude Code 預設只等 **30 秒**，於是報：

```
Failed to connect — MCP server "code-review-graph" connection timed out after 30000ms
```

沒裝 embeddings 之前，同一台機器的握手只要 **4.98 秒**。

**不能改成延後載入。** 那個預載是作者刻意的，`embeddings.py` 的 `prewarm_local_embeddings()` 註解寫明：Windows 上若讓 `sentence_transformers` + `torch` 在 FastMCP 的工作執行緒裡延後載入，會在 DLL 初始化 / OpenMP 執行緒池註冊時**永久卡死**。所以正解是把等待上限調高（見第 5.2 節的 `MCP_TIMEOUT`）。

設 `HF_HUB_OFFLINE=1` 只省 3.5 秒（31.33 → 27.83 秒），主要成本是模型載入本身，不是網路。而且新機器上模型還沒下載時設它會直接壞掉，所以本指南不建議設。

### 4.2 確認是「同一個」Python 能 import

```powershell
python -c "import code_review_graph, sentence_transformers; print('import ok')"
where.exe python
```

⚠️ **這是最常見的失敗點。** MCP 伺服器是用**寫死在設定裡的那個 python.exe 絕對路徑**啟動的。如果那個路徑不存在，或那個 Python 沒裝套件，Claude Code 只會說：

```
MCP error -32000: Connection closed
```

本機就踩過一次：設定裡寫 `C:\Program Files\Python314\python.exe`，但實際安裝在 `%LOCALAPPDATA%\Programs\Python\Python314\`。

如果 `python` 指到錯的解譯器，設一個使用者環境變數 `CRG_PYTHON` 指向正確的 `python.exe`，[`graph-refresh.ps1`](graph-refresh.ps1) 會優先採用它。

### 4.3 註冊到 Claude Code（**手動，別用它的 installer**）

```powershell
claude mcp add -s user code-review-graph -- "<python-path>" -m code_review_graph serve
claude mcp get code-review-graph
```

⚠️ **不要跑 `code-review-graph install --platform claude-code`。** 它的 dry-run 顯示會做兩件你不想要的事：

1. 在**專案根目錄寫一個 `.mcp.json`**（進版控、會影響其他人）。
2. **把它自己的說明文字 append 到 `CLAUDE.md`**。

手動註冊在 User 範圍就沒有這些副作用。

---

## 5. 設定自動更新（機器層級）

> 跑過第 2 節的 `install.ps1` 就**整節都做完了**（它會複製 hook 腳本並改好 `settings.json`）。本節是手動等價步驟，供你想自己來、或想看懂它改了什麼時參考。

### 5.1 安裝 hook 腳本

```powershell
copy graph-servers\graph-refresh.ps1 %USERPROFILE%\.claude\hooks\
```

### 5.2 合併進 settings.json

把下面內容**合併**（不是覆寫）進 `%USERPROFILE%\.claude\settings.json`，並把路徑換成你的：

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

三個環境變數的用途：

| 變數 | 為什麼要設 |
|---|---|
| `GITNEXUS_WAL_CHECKPOINT_THRESHOLD` | 見第 3.3 節。不設會靜靜損壞 GitNexus 索引 |
| `MCP_TIMEOUT` | 見第 4.1 節。不設，code-review-graph 會因為載入模型超時而連不上 |
| `MCP_CONNECT_TIMEOUT_MS` | 同上。兩個都設是因為我沒能從程式裡確定是哪一個在管那個 30 秒；兩個都是 Claude Code 認得的變數，多設一個無害 |

`gitnexus setup` 已經在同一個檔案寫了它自己的 `PreToolUse` / `PostToolUse` 條目，**不要覆蓋掉**。改完用這行確認 JSON 沒壞：

```powershell
Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json | Out-Null; "JSON OK"
```

### 5.3 為什麼沒有「每次 Edit 就更新」的 hook

實測結論：**`cmd /c start /b` 在 Windows 上不會真的斷開。** 子行程繼承了 hook 的 stdin 管線，呼叫方還是得等整個更新跑完。

| 寫法 | 每次 Edit 的阻塞時間 |
|---|---|
| 完全同步 | 3940 ms |
| `cmd /c start /b`（看起來像背景，其實不是） | 3960 ms |
| `Start-Process -WindowStyle Hidden`（本腳本採用） | **804 ms** |
| **改用常駐 daemon（現行做法）** | **0 ms** |

所以 `Edit`/`Write` 的 PostToolUse hook 整條拿掉了，改由 code-review-graph 自己的監看 daemon 負責。它的防抖是 0.3 秒，存檔後約 2 秒反映到圖譜。

### 5.4 三個觸發點

| 時機 | 觸發者 | 做什麼 | 阻塞成本 |
|---|---|---|---|
| 存檔（任何編輯器） | code-review-graph daemon | 更新 code-review-graph | **0 ms** |
| `git commit` | `.git\hooks\post-commit` | 跑 GitNexus analyze | 約 1.2 秒 |
| 開新 session | `SessionStart` hook | 確保 daemon 活著 + 補跑遺漏 + GitNexus 閘門 | 約 0.9 秒 |

GitNexus 那條有**閘門**：只有 `.gitnexus\meta.json` 的 `lastCommit` 不等於 `HEAD` 時才真的跑。索引已是最新時，它 820 毫秒就返回、不啟動任何 node 行程。這樣就不會每開一個 session 白燒 142 秒。

SessionStart 那條要留著，因為 `git pull` 帶進新 commit 時沒有本地 commit，`post-commit` 不會被觸發。

---

## 6. 每個專案要做的事

### 6.1 第一次索引

```powershell
cd <repo-root>
gitnexus analyze                     # 需要 taint/PDG 就加 --pdg
python -m code_review_graph build --repo .
python -m code_review_graph embed --repo .
```

⚠️ **`gitnexus analyze` 就算失敗也回傳 exit code 0。** 一定要看輸出文字，找 `Analysis failed`。本機踩過兩次：exit 0，但索引根本沒更新。

### 6.2 安裝 post-commit hook

```powershell
copy graph-servers\post-commit <repo-root>\.git\hooks\post-commit
bash -c "chmod +x .git/hooks/post-commit"
```

先確認沒有覆蓋別的東西：

```powershell
git config core.hooksPath          # 有輸出就代表 hook 目錄被改到別處
dir .git\hooks | findstr /v sample
```

⚠️ **`.git\hooks\` 不進版控。** 別台機器 clone 之後不會有這個 hook，要在那邊重裝。

### 6.3 啟動監看 daemon

```powershell
python -m code_review_graph daemon add <repo-root> --alias <repo-alias>
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\hooks\graph-refresh.ps1" -Which crg -Repo <repo-root> -Detach
python -m code_review_graph daemon status
```

⚠️ **不要直接跑 `daemon start`。** 它會印「Forking is not supported on Windows — running in foreground」然後卡在前景，你的終端機一關它就死。要透過 `graph-refresh.ps1 -Detach`（內部用 `Start-Process -WindowStyle Hidden`）啟動，它才能跨 session 存活。重開機後會死，下一次 SessionStart 會自動復活。

### 6.4 告訴 AI 助手怎麼用這兩台（**別跳過**）

裝好伺服器**不等於** AI 助手會正確使用它們。沒有明文規則，它會挑先看到的那台、把同一個問題問兩台燒雙倍 token、並且相信一份過期的索引給你錯答案。

**`install.ps1 -Repo <repo-root>` 會自動寫進去**，不必手動貼：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -PatchOnly -Repo <repo-root>
```

它把規則包在自己的標記裡（`<!-- code-graph-servers:start -->` … `end`），所以：**重跑會就地更新**，不會累積第二份；**標記外的內容一個字都不動**(寫完會驗證,不通過就回滾——有備份就還原,是新建的就刪掉)；CLAUDE.md 不存在就幫你建。規則文字**只有一份來源** —— [`claude-md-snippet.md`](claude-md-snippet.md) 橫線以下的部分，改那裡再重跑即可。

要寫進 `AGENTS.md` 而不是 `CLAUDE.md`：加 `-AgentDocName AGENTS.md`。完全不要它動：加 `-NoAgentDoc`。

⚠️ **你的專案如果已經手寫過同樣的規則**，腳本不認得那份（沒有標記），會再加一份造成重複。這種情況請用 `-NoAgentDoc`，或先把手寫那份刪掉。

想手動貼也可以，內容就是 [`claude-md-snippet.md`](claude-md-snippet.md) 橫線以下的部分。內容包含：

- 按能力分工（哪台管找符號／哪台管 taint 與執行流程），並明寫**兩台都不是永遠的第一順位**。
- 兩台的**新鮮度差異**：code-review-graph 每次呼叫重讀資料庫（當場生效）；GitNexus 把索引快取在伺服器啟動那一刻（要下一個工作階段）。
- 四個會導致錯答案的前提：未 commit 的程式不在 GitNexus 圖譜裡、非程式碼檔只有 GitNexus 有、語意搜尋需要向量而 daemon 不補向量、`gitnexus analyze` 失敗也回傳 exit code 0。

⚠️ **必須在 `<!-- gitnexus:start -->` … `<!-- gitnexus:end -->` 標記之外。** 那段是 `gitnexus setup` 產生的，下一次 `analyze` 會**整段覆蓋**，寫在裡面的東西會消失。腳本會**附加在該段之後**（實測驗證過位置），而且如果偵測到我們的標記已經被塞進 gitnexus 標記裡面，它會**拒絕寫入並要你先搬出來**，不會默默把規則寫進一個會被清掉的地方。

那段還寫著「改任何符號前一律先跑 GitNexus `impact`」，跟本分工牴觸 —— snippet 裡已經明寫「那一句以本條為準」。

### 6.5 不用改 `.gitignore`

兩個工具都會在自己的資料夾裡放一個內容為 `*` 的 `.gitignore`，自我忽略。`git status` 看不到它們，**不要再手動加規則**。

---

## 7. 驗證清單（每項都是 5 秒指令）

```powershell
# 兩台都連上了嗎
claude mcp list

# GitNexus 索引跟得上 HEAD 嗎
python -c "import json;print(json.load(open('.gitnexus/meta.json',encoding='utf-8'))['lastCommit'][:12])"
git rev-parse HEAD

# GitNexus 有沒有 WAL 孤兒檔（正常應該是 0 個）
dir .gitnexus\lbug.wal.missing-shadow.* 2>nul

# code-review-graph 統計 + 是否對齊 HEAD
python -m code_review_graph status --repo .

# 語意搜尋的向量數（0 就是不能用）
python -c "import sqlite3;print(sqlite3.connect(r'.code-review-graph/graph.db').execute('select count(*) from embeddings').fetchone())"

# daemon 活著嗎
python -m code_review_graph daemon status

# hook 腳本的失敗記錄
type %TEMP%\claude-graph-refresh.log
```

---

## 8. 踩過的坑（全部 2026-08-17 實證）

### 8.1 `MCP error -32000: Connection closed`
設定裡的 `python.exe` 路徑不存在。用 `claude mcp get <server-name>` 看實際路徑，再用 `where.exe python` 對照。

### 8.2 `connection timed out after 30000ms`
**先問：有沒有裝 `embeddings` extra？** 有的話這就是原因（見第 4.1 節）：MCP 伺服器啟動時載入模型要 27～31 秒，超過預設的 30 秒。修法是把 `MCP_TIMEOUT` / `MCP_CONNECT_TIMEOUT_MS` 設成 `120000`。

沒裝 embeddings 卻還是超時：實測正常握手只要 **4.98 秒**，遠低於上限，所以別急著改設定。這種情況本機重現不出來，最可能是啟動那一刻 CPU/硬碟被其他工作（例如 Gradle build、Defender 掃描）佔滿。要抓真因就跑 `claude --debug mcp`。

自己量握手時間的方法：用 stdio 送一個 `initialize` 請求進去，量到第一行 stdout 的時間。

### 8.3 `FTS index 'file_fts' is inconsistent`
```powershell
gitnexus analyze --repair-fts
```
不必刪整個索引。`gitnexus clean` 會把 `.gitnexus\` 整個刪掉（包含 `run.cjs`），代價大得多。

### 8.4 `lbug.wal.missing-shadow.*` 一直長出來
WAL 檢查點門檻太小。見第 3.3 節。刪掉那些孤兒檔前先確認沒有 analyze 正在跑。

### 8.5 exit code 0 會騙人
`gitnexus analyze` 失敗時仍回傳 0。判斷成功要看**輸出文字**與 `meta.json` 的 `lastCommit`，不要看 exit code。

### 8.6 `daemon start` 卡住不放
Windows 不支援 fork。見第 6.3 節。

### 8.7 語意搜尋抓不到剛改的程式
**daemon 不會補向量。** 實測：新函式 15 秒內進 `nodes` 表，同一時間 `embeddings` 表是 **0 筆**。它不報錯，只會安靜地漏掉。大幅改動後手動重跑：
```powershell
python -m code_review_graph embed --repo .
```

### 8.8 用 `search` 的輸出判斷「符號存不存在」會得到假陽性
`code-review-graph search` 的 JSON 會**回顯查詢字串**（`"query": "你查的字"`），所以拿字串比對輸出時，一個根本不存在的符號也會「命中」。要判斷節點在不在，直接查資料庫：
```powershell
python -c "import sqlite3;print(sqlite3.connect(r'.code-review-graph/graph.db').execute(\"select count(*) from nodes where name like '%你的符號%'\").fetchone())"
```

### 8.9 別用 `graph.db` 的檔案時間判斷「有沒有更新」
SQLite 可能在既有頁面內寫入，主檔的 mtime 不一定改變。實測：metadata 已寫入 `10:41:07`，但檔案 mtime 還停在 `10:18:18`，看起來像「完全沒跑」。要判斷新鮮度請看 metadata：

```powershell
python -m code_review_graph status --repo .    # 看 Last updated 那一行
```

同一類錯誤今天發生三次（另外兩次見 8.8 與 5.3），共同教訓是：**確認一件事之前，先確認你的量測工具真的在量那件事。**

### 8.10 CLAUDE.md 裡的 GitNexus 段落不要手改
它夾在 `<!-- gitnexus:start -->` 與 `<!-- gitnexus:end -->` 之間，**由 gitnexus CLI 自動產生**，下一次 `analyze` 會整段覆蓋。要改規則就改標記之外的地方。

### 8.11 MCP 伺服器的索引快取行為不一樣
| | 索引更新後 |
|---|---|
| code-review-graph | **當場生效**（每次呼叫重讀資料庫） |
| GitNexus | **要到下一個 session**（索引快取在伺服器啟動的瞬間） |

所以 commit 後跑完的 GitNexus analyze，當前 session 看不到新結果，要 `/mcp` 重連或開新 session。

---

### 8.12 資料夾改名或搬移被拒（`being used by another process`）
**監看 daemon 在 Windows 上持有目錄句柄。** 它用 watchdog 遞迴監看整個 repo，所以被監看樹裡的任何資料夾都不能改名或搬移，`Move-Item` 會回報「正由另一個處理程序使用」。

先停、再搬、再啟動：

```powershell
python -m code_review_graph daemon stop
Move-Item <舊路徑> <新路徑>
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\hooks\graph-refresh.ps1" -Which crg -Repo <repo-root> -Detach
```

同樣的原因也會擋掉 `git worktree remove`、刪除資料夾、以及部分 IDE 的重構搬檔操作。

---

## 9. 移除

```powershell
gitnexus uninstall                        # 移除 MCP 條目、skills、hooks
claude mcp remove code-review-graph -s user
python -m code_review_graph daemon stop
python -m code_review_graph uninstall     # 移除它的資料、設定、hooks、skills
```

再手動清掉：`%USERPROFILE%\.claude\hooks\graph-refresh.ps1`、`<repo-root>\.git\hooks\post-commit`、`settings.json` 裡的 `SessionStart` 條目與 `env` 那一行。

---

## 10. 本目錄的檔案

| 檔案 | 用途 |
|---|---|
| [`install.ps1`](install.ps1) | 一次做完機器層級 + 專案層級安裝，可重複執行 |
| [`graph-refresh.ps1`](graph-refresh.ps1) | hook 用的更新腳本（主複本；安裝到 `~\.claude\hooks\`） |
| [`post-commit`](post-commit) | git hook 主複本（安裝到 `<repo-root>\.git\hooks\`） |
| [`claude-md-snippet.md`](claude-md-snippet.md) | 貼進你專案 `CLAUDE.md` 的分工規則（見第 6.4 節） |
| `README.zh-TW.md` / [`README.en.md`](README.en.md) | 本文件 |
