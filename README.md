# dev-workstation

一條指令，把一台全新的 Windows 主機變成可以工作的 Claude Code 開發環境。

One command turns a bare Windows host into a working Claude Code development environment.

---

# 正體中文

## 這個專案是什麼

這是一份**可重複執行的開發機設定**：換新機器、重灌、或多開一台工作站時，要安裝的工具、要放的設定檔、要掛的 hook，全部寫成腳本與指南收在這裡。

主程式是根目錄的 [`install.ps1`](install.ps1)。它會檢查工具鏈、補上缺的，然後依序呼叫各個子安裝器，把下面這些東西裝好接起來：

- 兩台給 Claude Code 用的程式圖譜 MCP 伺服器，以及讓它們索引自動保持最新的 hook
- 跨 session 的記憶系統
- 給 AI 代理讀的指令檔（使用者層級與專案層級各一套）

## 為什麼需要它

同一組安裝步驟，在第三台機器上還是會踩到第一台踩過的坑：某個工具要加旗標才不會卡在互動式提問、某個索引器在中文系統上會輸出亂碼、某個 hook 在舊版 PowerShell 上會無聲失敗。這些經驗如果只留在腦子裡，換台機器就歸零。

所以這裡的每一份指南都附上**量測到的數字與日期**，每一個安裝器都**可以重複執行**，而每一個曾經出錯的地方都在原始碼註解裡寫明當時量到什麼。目標不是「能裝起來」，而是「三個月後在另一台機器上，照著跑還是能裝起來」。

## 內容

| 資料夾 | 裝什麼 |
|---|---|
| [`graph-servers/`](graph-servers/) | 兩台程式圖譜 MCP 伺服器：**GitNexus** 與 **code-review-graph**。含自動更新索引的 refresh hook、每次 commit 後觸發的 post-commit hook，以及第一次建索引與背景監看服務 |
| [`claude-mem/`](claude-mem/) | **claude-mem**，跨 session 的記憶。預設就裝。腳本化安裝需要三條指令，其中一條幾乎所有人都會漏掉；也說明它跟專案自己的 `Memory/` 資料夾要怎麼區分 |
| [`general-claude-md/`](general-claude-md/) | 三份給 AI 代理讀的指令檔：`user-CLAUDE.md` 放到 `~/.claude/CLAUDE.md`（整台機器每個專案都載入）、`VERIFICATION-LESSONS.md` 放到 `~/.claude/docs/`、`project-CLAUDE.md` 是每個專案自己的 `CLAUDE.md` 範本 |
| [`parallel-agent-operations/`](parallel-agent-operations/) | 一段可貼進 `CLAUDE.md` 的規則，阻止 AI 代理自作主張一次派出幾十個子代理——它看不到自己會燒掉多少額度 |
| [`Tools/`](Tools/) | [`deploy.py`](Tools/deploy.py) 負責放置上面那三份指令檔：有 manifest 記錄、會先備份、**不會覆蓋你自己改過的檔案**。[`test_deploy.py`](Tools/test_deploy.py) 是它的測試 |

每個資料夾都有自己的逐步指南。某一步失敗、或想手動接手時，要讀的是那幾份。

## 使用方式

### 需要系統管理員的項目

**大部分的安裝不需要任何權限。** 以下五項是例外——它們一定要有系統管理員才裝得起來，因為
它們寫進 `C:\Program Files`、`System32` 或 `HKEY_LOCAL_MACHINE`，而一般使用者帳戶對這三個
地方都沒有寫入權。

| 項目 | 為什麼一定要管理員 | 下載來源 |
|---|---|---|
| PowerShell 7 | 全機器安裝的 MSI，裝進 `C:\Program Files\PowerShell`。要 `-win-x64.msi` 那一個檔 | https://github.com/PowerShell/PowerShell/releases |
| Node.js | 全機器安裝的 MSI，裝進 `C:\Program Files\nodejs`。要 `-x64.msi` 那一個檔 | https://nodejs.org/en/download |
| Microsoft Visual C++ Redistributable 2015–2022（x64） | 系統執行階段，檔案放進 `System32`，並寫 `HKLM` | https://aka.ms/vs/17/release/vc_redist.x64.exe |
| Microsoft Visual C++ Redistributable 2015–2022（x86） | 同上，放進 `SysWOW64` | https://aka.ms/vs/17/release/vc_redist.x86.exe |
| TortoiseGit | 它是檔案總管的 shell extension，而 shell extension 就是一筆 `HKLM` 註冊，沒有「只裝給我自己」的版本 | https://download.tortoisegit.org/ |

⚠ 上表第三欄刻意寫**來源**而不是釘住版本的完整檔案網址。腳本擋下來的時候，會把它這一版真正
要下載的完整網址逐項印在畫面上——那份才是權威，因為它直接來自腳本裡的 `$DEPS` 表。這裡再抄一
份釘住版本的網址，只會多出一個會過期而且沒人檢查的副本。

這五項只需要請管理員裝**一次**。裝完之後，這支腳本就不會再擋你，其餘項目都可以用自己的一般
帳戶安裝。

⚠ 但「裝好了」不等於「會自動更新」。這支腳本只檢查某個工具**在不在**，不會把已經裝好的工具
升級到新版。所以上表五項日後要升級，仍然需要管理員。

**不需要管理員的項目**，分成兩類寫，因為兩類的證據強度不一樣：

*已經在一般使用者帳戶上實測成功*（2026-10-07，全新的 Windows 11）：

- **Git for Windows**——沒有管理員權限時它會自動改成只裝給目前使用者，裝進
  `~\AppData\Local\Programs\Git`，並且自己把路徑加進使用者的 PATH。實測結束碼 0
- **VS Code**——本專案用的是使用者版安裝檔，裝進 `~\AppData\Local\Programs`。實測結束碼 0

*設計上就屬於使用者範圍，但還沒有在一般使用者帳戶上從頭跑完一次*：

- **Python**——以 `InstallAllUsers=0` 安裝，整包都只裝給目前使用者。
  ⚠ 目前唯一一次在一般使用者帳戶上的實測是**失敗的**（結束碼 1601），但那是測試環境的問題
  而不是權限問題：測試是透過 SSH 進行的，而 SSH 的登入權杖沒有 `INTERACTIVE` 這個群組，
  Windows Installer 服務的存取權限只開給系統管理員、`INTERACTIVE` 與服務帳戶三者。直接坐在
  機器前面登入的一般使用者是屬於 `INTERACTIVE` 的，所以預期可以正常安裝。完整的推論與反證
  過程在 `Memory/tasks/20261007-010000-non-admin-install/RESULT.md` 第 3 節
- **uv** 與 **claude**——原廠安裝指令碼，裝進 `~\.local\bin`
- 其後所有階段：`Tools/deploy.py`、圖譜伺服器、claude-mem、Claude Code 外掛

### 沒有管理員權限時腳本會怎麼做

它會在**最開始、還沒下載任何東西之前**先檢查一次：

1. 判斷目前這個行程有沒有系統管理員權限
2. 檢查上表五項裡，哪些是這台機器上**還缺的**（已經裝好的不算）
3. 如果一項都不缺，就直接往下跑，不會攔你。（其餘項目在設計上都屬於使用者範圍；但「一般
   使用者帳戶從頭到尾跑完整套安裝」目前還沒有實際完整跑過一次——見上面 Python 那一條）
4. 如果有缺，就把缺的那幾項連同下載位址列出來，告訴你兩條路（自己用系統管理員身分重跑，
   或請管理員裝那幾項），然後**停下來**

停下來的時候它只寫了一樣東西——它自己的執行紀錄，`Debug\install-<時間戳>.log`，而且路徑會
印在畫面上。沒有下載任何安裝檔、沒有安裝任何東西、沒有改 PATH、沒有建立其他任何資料夾。
結束碼是 1。

⚠ 這個檢查只看「缺的」項目。如果 PowerShell 7、Node.js、VC++ 執行階段和 TortoiseGit 都已經
在這台機器上了，那麼一個完全沒有管理員權限的帳戶執行這支腳本，不會被這個檢查擋下來。

### 第一次安裝

**全新主機（什麼都還沒裝、連 `git` 都沒有）**——只下載 `install.ps1` 這一個檔案，直接執行：

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/Dino9021/dev-workstation/main/install.ps1 -OutFile install.ps1 -UseBasicParsing
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

它發現自己旁邊沒有 repo，就會依序：裝 PowerShell 7 → **先裝 Git for Windows → 再把 repo clone 到它旁邊的 `dev-workstation\`** → 把剩下的工作交給 clone 裡的那份 `install.ps1`。全程自動下載、自動安裝，不必再手動下載 ZIP。重跑時已經 clone 好的資料夾會直接沿用，**不會**幫你 `pull`。

**已經有 `git` 的主機**——照舊 clone 再跑：

```powershell
git clone https://github.com/Dino9021/dev-workstation.git
cd dev-workstation
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly   # 只檢查，不動手
powershell -ExecutionPolicy Bypass -File .\install.ps1              # 真的安裝
```

用 Windows PowerShell 5.1 直接跑就好。腳本會自己安裝 PowerShell 7，再把工作交棒過去。

### 安裝順序

1. **PowerShell 7**——先裝它，然後整支腳本重新在它底下執行。只下載了 `install.ps1` 單檔時，接著**先裝 Git for Windows、再 clone repo**，然後交棒給 clone 裡的那份
2. **工具鏈**——依序檢查並只補缺的：`git`、**VS Code**（使用者版，裝在 `~\AppData\Local`，不需要系統管理員）、**Microsoft Visual C++ Redistributable 2015–2022**（x64 與 x86，TortoiseGit 官方 FAQ 列的先決條件，所以排在它前面）、**TortoiseGit**、`node`、`python`、`claude`。**完全不使用 winget**：每一項都是直接下載原廠安裝檔靜默安裝。（winget 在 Windows Server 上根本沒有，而在全新的 Windows 11 上雖然有卻是壞的——2026-10-07 實測，三個工具三次都是 `Failed when opening source(s)`，白試一次才退回下載。）`git` 與 `TortoiseGit` 都會先向各自專案的來源問出當前版本，釘住的網址只是最後防線；VS Code 與 VC++ 用的是原廠「永遠指向最新版」的固定網址
3. **VS Code 擴充套件**——`anthropic.claude-code`（Claude Code extension），用 VS Code 自己的 `code --install-extension` 安裝
4. **指令檔**——`Tools/deploy.py` 放置使用者層級的兩份與專案層級的範本
5. **圖譜伺服器**——`graph-servers/install.ps1` 裝兩台伺服器、註冊 MCP、掛 refresh hook 與 post-commit hook、建第一次索引、啟動背景監看服務
6. **claude-mem**——跨 session 記憶，純本機
7. **Claude Code 外掛**——`dispatch-guard`（本專案運作所依據的規則，以及強制執行它們的 hook）與 `mattpocock-skills`（TDD、除錯、code review、領域建模等 skills）

⚠ `dispatch-guard` 會伸手到這個專案以外：它會為整台機器裝一條狀態列和一個背景額度監看工作。2026-10-06 起它是預設安裝（原本藏在 `-All` 後面，該參數已取消）。

### 常用參數

| 參數 | 作用 |
|---|---|
| `-CheckOnly` | 只報告會做什麼，除了自己的 log 以外什麼都不寫 |
| `-Repo <路徑>` | **指定要套用的專案**。見下方說明 |
| `-Pdg` | 建索引時多建 PDG 層。`explain`（汙染分析）與 `pdg_query` 需要它，但慢很多，而且**必須在第一次執行時就加**：索引那一步無條件執行，事後才想要就得整個再跑一次 |
| `-SkipDeps` | 不安裝任何缺少的工具，只做設定 |
| `-LogPath <路徑>` | 改變 log 位置 |
| `-Cowork yes` / `-Cowork no` | 直接回答「要不要裝 claude-mem Cowork」，腳本就不會問。見下方說明 |
| `-SelfTest` | 離線自我測試，不碰任何東西，連 log 都不寫 |
| `-CheckUrls` | 檢查釘住的下載網址是否還活著 |

⚠ **`-Repo` 預設值是這個 clone 自己。** 有一部分工作是「對某個專案做」的——掛 post-commit hook、建第一次索引、啟動監看、寫 `CLAUDE.local.md`。不指定 `-Repo` 的話，這些都會做在 dev-workstation 這個 clone 上，而不是你真正要開發的那個專案。要套用到別的專案請明確指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo C:\code\my-project
```

### 它只會問你一件事

整個安裝流程只有一個問題：**要不要裝 claude-mem Cowork（`claude-mem-cowork@thedotmack`）**。

它是 claude-mem 的**雲端**那一半。它自己的 marketplace 說明寫著：hooks「stream tool use to cmem.ai and inject observations into new sessions and agents」——也就是**會把你的工具使用紀錄送到外部服務 cmem.ai**。第 5 步裝的本機 claude-mem 不會，也不需要它。所以它不在預設裡。

這個問題**問在整個安裝的最前面**，在腳本印出它接下來要做哪些事之後、在它動手裝任何東西之前。不會等到跑了四十分鐘才突然冒出來問你。

- 按 `Y` 才裝。按 `N`、按 Enter、按 Esc，或 **30 秒不回答，都是不裝**。
- 用 `-Cowork yes` 或 `-Cowork no` 就完全不會問。
- **stdin 不是終端機時（腳本、CI、被其他工具啟動）它不會問，直接不裝**，也不會卡在那裡等 30 秒。要在無人職守的情況下裝它，請明確加上 `-Cowork yes`。
- 事後要加：`.\install.ps1 -Cowork yes`。事後要移除：`claude plugin uninstall claude-mem-cowork@thedotmack`。

### 它會改動哪些檔案

**這支腳本只擁有一個檔案：它自己的 log。** 其他所有寫入都是它呼叫的子工具做的，而那些子工具各自帶著備份、寫入後檢查與回滾機制。一個檔案有兩個擁有者，就是檔案被覆蓋掉的原因。

每次執行都會完整記錄到腳本旁邊的 `Debug\install-<時間戳>.log`，而且**絕對路徑會在開頭印一次、在每一個結束點再印一次，包含每一種失敗情況**。

⚠ **它只安裝「不存在」的工具，絕不替換你自己選的版本。** 已安裝但版本太舊，會停在前置需求閘門，並印出該閘門自己的升級指令。替換你選定的工具鏈不是這支腳本該做的決定。

⚠ **其中一步可能會問你問題。** 在真正的終端機裡執行時，claude-mem 的安裝程式可能顯示一個比較付費雲端方案與純本機模式的畫面。腳本會在那一步**開始之前**先印出說明，答案是**本機**——那正是它傳進去的旗標已經選好的。無人職守執行時它完全不會問。細節見 [`claude-mem/README.md`](claude-mem/README.md)。

⚠ **`graph-servers/graph-refresh.ps1` 需要 PowerShell 7。** 它是使用者層級的 hook，由 post-commit 與 SessionStart 兩處以 `powershell`（5.1）啟動，所以它會自己重啟到 pwsh；真的找不到 PowerShell 7 就拒絕執行並留下一行 log。正常情況下不會遇到——安裝流程第一步就把 PowerShell 7 裝好了——只有事後被移除才會碰到。它拒絕時 post-commit 仍然回傳 0，**不會讓任何人的 `git commit` 失敗**。

### 在真的需要之前先確認它還能用

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SelfTest    # 離線，什麼都不碰
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckUrls   # 釘住的下載網址還在嗎
```

`-CheckUrls` 建議每隔幾個月重跑。四個釘住的安裝檔網址是這個 repo 裡**沒人動它也會自己壞掉**的部分，而 404 偏偏只在你站在一台沒有工具鏈的機器前面時才會發現。它每個網址發一個 HEAD 請求，外加一個故意會 404 的對照組，什麼都不下載；網址掛掉**或對照組居然通過**都會回傳非 0——一個分辨不出差異的量測工具不算證據。

## 記憶放在哪裡

`~/` 代表你的使用者目錄（`%USERPROFILE%`，例如 `C:\Users\你的帳號`）；`<專案>` 代表某個專案的根目錄。

### 跟著專案走，而且進 git

| 位置 | 放什麼 |
|---|---|
| `<專案>/Memory/notes/` | **專案自己的記憶**：決策筆記 |
| `<專案>/Memory/tasks/<時間戳-任務名>/` | 每個任務一個資料夾：提示詞、結果記錄、驗收腳本、量測證據 |
| `<專案>/CLAUDE.md` | 專案層級的 agent 指令 |

`Memory/` **故意被 git 追蹤**，它是每個 commit 背後的理由。公開快照由 `Tools/publish-public.py` 排除，不是靠 `.gitignore`。

### 跟著專案走，但不進 git

| 位置 | 放什麼 |
|---|---|
| `<專案>/CLAUDE.local.md` | 個人的 harness 設定（圖譜伺服器用法），被 `.gitignore` |
| `<專案>/.gitnexus/` | GitNexus 的索引與圖譜資料庫 |
| `<專案>/.code-review-graph/` | code-review-graph 的圖譜資料庫與 embeddings |

### 只在這台機器上

| 位置 | 放什麼 |
|---|---|
| `~/.claude/CLAUDE.md` | 全機器通用規則，每個專案每個 session 都載入 |
| `~/.claude/docs/VERIFICATION-LESSONS.md` | 通用規則指向的驗證守則 |
| `~/.claude/settings.json` | hook、MCP 伺服器、啟用的外掛 |
| `~/.claude/projects/<專案路徑轉成的名字>/<session-id>.jsonl` | **逐字稿**：每個 session 一個檔，完整對話與工具呼叫 |
| `~/.claude/projects/<同上>/<session-id>/tool-results/` | 大到塞不進逐字稿的工具輸出 |
| `~/.claude/file-history/<session-id>/` | Claude Code 改過的檔案快照，用來還原 |
| `~/.claude/shell-snapshots/`、`~/.claude/sessions/`、`~/.claude/state/` | Claude Code 自己的 session 狀態，本專案不碰 |
| `~/.claude-mem/claude-mem.db` | **claude-mem 的記憶**：跨 session 的觀察與摘要（SQLite） |
| `~/.claude-mem/chroma/` | 同一批記憶的向量索引，給語意搜尋用 |
| `~/.claude-mem/corpora/`、`~/.claude-mem/logs/` | 知識庫與 worker 的 log |
| `~/.code-review-graph/` | watch daemon 的狀態與被監看的專案清單（`watch.toml`、`registry.json`） |

⚠ **`<專案>/Memory/` 和 `~/.claude-mem/` 是兩回事。** 前者是人寫的、跟著 repo 走；後者是 claude-mem 自動記錄的，只在這台機器上。`claude-mem/claude-md-snippet.zh-TW.md` 裡有一條規則就是為了避免 agent 把兩者搞混。

⚠ **這些會長大，而且長得比想像快。** 本機 2026-10-06 量到：`~/.claude-mem` 2.0 GB（其中 `claude-mem.db` 連 WAL 745 MB）、`~/.claude/projects` 1.9 GB 的逐字稿、`~/.code-review-graph` 31.5 GB（`graph.db` 25.2 GB ＋ WAL 6.3 GB）。換機器之前值得先看一眼。

### 換機器的時候要帶什麼

重裝一次 `install.ps1` 就會回來的：`~/.claude/CLAUDE.md`、`~/.claude/docs/`、`<專案>/.gitnexus/`、`<專案>/.code-review-graph/`、`~/.code-review-graph/`——它們都是從別的東西重建出來的。

**重建不回來的只有兩個**：`<專案>/Memory/`（在 git 裡，clone 就有）和 `~/.claude-mem/`（不在任何 repo 裡，要自己複製）。逐字稿 `~/.claude/projects/` 也不在 repo 裡，但 claude-mem 已經把它濃縮過了。

## 慣例

- **以 Windows 為主。** 腳本是 PowerShell；git hook 是 `sh`（Git for Windows 內含 Git Bash）。
- **`<角括號>` 代表「請替換」**，連括號一起換掉。真實存在的環境變數（`%USERPROFILE%`、`$env:USERPROFILE`、`$USERPROFILE`）直接用，不要替換。
- **可重複執行。** 每個安裝器都能重跑，只補缺的、不覆蓋你已經設好的值。第二次跑會跳過已經裝好的東西，不會重裝。
- **沒有機器專屬值、沒有祕密。** 主機專屬的東西一律是佔位符或環境變數，這裡不讀任何帳密。
- **數字都是量出來的。** 指南裡出現的耗時都附上量測日期與量測對象。

## 授權

[MIT](LICENSE)。本 repo 的腳本只是安裝與設定第三方工具，那些工具各自適用它們原本的授權。

---

# English

## What this is

A **repeatable setup for a development machine**: the tools to install, the configuration
files to place and the hooks to wire up, written down as scripts and guides so that a new
host, a rebuild or a second workstation does not mean rediscovering all of it.

The entry point is [`install.ps1`](install.ps1) at the root. It checks the toolchain,
installs what is missing, then calls each sub-installer in order to set up and connect:

- two code-graph MCP servers for Claude Code, plus the hooks that keep both indexes current
- a cross-session memory system
- the instruction files an AI agent reads, at user scope and at project scope

## Why it exists

The same install sequence still hits, on the third machine, every pitfall the first one
hit: a tool that hangs on an interactive prompt unless you pass a flag, an indexer that
emits mojibake on a non-English Windows, a hook that fails silently under an older
PowerShell. Kept only in someone's head, that knowledge resets with every new host.

So every guide here carries **measured numbers with the date they were measured**, every
installer is **safe to re-run**, and every place that once went wrong says in a source
comment what was measured at the time. The goal is not "it installs"; it is "three months
from now, on another machine, it still installs."

## What is here

| Folder | Sets up |
|---|---|
| [`graph-servers/`](graph-servers/) | Two code-graph MCP servers — **GitNexus** and **code-review-graph** — with the refresh hook that keeps their indexes current, the post-commit hook that triggers it, the first index and the watch daemon |
| [`claude-mem/`](claude-mem/) | **claude-mem**, cross-session memory, installed by default. The three commands a scripted install needs, one of which nearly everybody leaves out, and how to keep it from being confused with a project's own `Memory/` folder |
| [`general-claude-md/`](general-claude-md/) | Three instruction files for an AI agent: `user-CLAUDE.md` goes to `~/.claude/CLAUDE.md` (loaded in every project on the machine), `VERIFICATION-LESSONS.md` to `~/.claude/docs/`, and `project-CLAUDE.md` is the template for each project's own `CLAUDE.md` |
| [`parallel-agent-operations/`](parallel-agent-operations/) | A `CLAUDE.md` rule that stops an agent fanning out into dozens of subagents on its own — it cannot see the session budget it would burn |
| [`Tools/`](Tools/) | [`deploy.py`](Tools/deploy.py) places those three instruction files: manifest-tracked, backed up first, and it **never overwrites a file you edited**. [`test_deploy.py`](Tools/test_deploy.py) is its test suite |

Each folder carries its own step-by-step guide. Those are the ones to read when a step
fails or you want to take over by hand.

## How to use it

### What needs an administrator

**Most of this install needs no special rights at all.** These five are the exception.
They cannot be installed without an administrator because they write to
`C:\Program Files`, `System32` or `HKEY_LOCAL_MACHINE`, and a standard user account can
write to none of those.

| Tool | Why it needs an administrator | Where to get it |
|---|---|---|
| PowerShell 7 | A per-machine MSI, into `C:\Program Files\PowerShell`. Take the `-win-x64.msi` | https://github.com/PowerShell/PowerShell/releases |
| Node.js | A per-machine MSI, into `C:\Program Files\nodejs`. Take the `-x64.msi` | https://nodejs.org/en/download |
| Microsoft Visual C++ Redistributable 2015–2022 (x64) | A system runtime: its DLLs go in `System32` and it writes `HKLM` | https://aka.ms/vs/17/release/vc_redist.x64.exe |
| Microsoft Visual C++ Redistributable 2015–2022 (x86) | The same, into `SysWOW64` | https://aka.ms/vs/17/release/vc_redist.x86.exe |
| TortoiseGit | It is an Explorer shell extension, and a shell extension *is* an `HKLM` registration. There is no install-for-me-only form of it | https://download.tortoisegit.org/ |

⚠ That last column names a SOURCE and not a pinned file, deliberately. When the script
stops it prints the full address it would itself have downloaded, for each tool it is
waiting on, and that is the authoritative one because it comes straight out of the `$DEPS`
table. A pinned URL copied in here would be a second copy that rots and that nothing
checks.

An administrator installs those five **once**. After that this script stops blocking you,
and the rest installs from your own ordinary account.

⚠ Installed is not kept up to date. This script only ever asks whether a tool **is
present**; it never upgrades one that is. So upgrading any of those five later still needs
an administrator.

**What does not need an administrator**, in two groups, because the evidence behind them is
not equally strong:

*Already measured working from a plain standard user account* (clean Windows 11,
2026-10-07):

- **Git for Windows** — unelevated, its installer falls back to a per-user install into
  `~\AppData\Local\Programs\Git` and adds that directory to your user PATH itself.
  Measured: exit code 0
- **VS Code** — this project uses the per-user installer, which lands in
  `~\AppData\Local\Programs`. Measured: exit code 0

*User-scope by design, but not yet run end to end from a standard user account*:

- **Python** — installed with `InstallAllUsers=0`, so the whole package is yours alone.
  ⚠ The one measurement from a standard user account **failed**, with exit code 1601 — and
  that is the test environment rather than the privilege. The test ran over SSH, whose
  logon token has no `INTERACTIVE` group, and access to the Windows Installer service on
  that host is granted to administrators, `INTERACTIVE` and service accounts only. A
  standard user signed in at the machine itself is in `INTERACTIVE` and is therefore
  expected to install it. The working, including the control and the mutation that rule out
  the alternatives, is in
  `Memory/tasks/20261007-010000-non-admin-install/RESULT.md` section 3
- **uv** and **claude** — vendor install scripts, into `~\.local\bin`
- And every phase after the toolchain: `Tools/deploy.py`, the graph servers, claude-mem,
  the Claude Code plugins

### What the script does when you are not an administrator

It checks once, at the very start, before downloading anything:

1. Does this process hold administrator rights?
2. Of the five tools above, which are **missing** on this machine? Ones already installed
   do not count.
3. Nothing missing — it carries straight on and does not stop you. (Everything after the
   toolchain is user-scope by design; a standard user account running the whole install
   from end to end has not yet actually been done once — see the Python entry above.)
4. Something missing — it lists exactly those, with the addresses above, gives you the two
   ways forward (re-run it yourself as an administrator, or ask an administrator to
   install that list once), and **stops**.

When it stops it has written exactly one thing — its own run log,
`Debug\install-<timestamp>.log`, whose path it prints on screen. Nothing downloaded,
nothing installed, no PATH changed, no other directory created. It exits 1.

⚠ The check looks only at what is MISSING. On a machine that already has PowerShell 7,
Node.js, the VC++ runtimes and TortoiseGit, an account with no administrator rights at all
is not stopped by this check.

### First install

**A fresh host — nothing installed, not even `git`.** Download `install.ps1` on its own
and run it:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/Dino9021/dev-workstation/main/install.ps1 -OutFile install.ps1 -UseBasicParsing
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Finding no repository around itself, it installs PowerShell 7, then **Git for Windows,
then clones the repository into `dev-workstation\` beside itself**, and hands the rest of
the run to the clone's own `install.ps1`. Everything is downloaded and installed for you;
there is no ZIP to fetch by hand. A clone that is already there is reused on a re-run, and
**not** pulled.

**A host that already has `git`** — clone and run as before:

```powershell
git clone https://github.com/Dino9021/dev-workstation.git
cd dev-workstation
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly   # report only
powershell -ExecutionPolicy Bypass -File .\install.ps1              # do it
```

Run it from Windows PowerShell 5.1. The script installs PowerShell 7 itself and hands over
to it.

### The order it installs in

1. **PowerShell 7** — first, then the whole script relaunches under it. When
   `install.ps1` was downloaded on its own, it then **installs Git for Windows, clones the
   repository**, and hands over to the clone's copy
2. **Toolchain** — checked first and installed only when missing, in this order:
   `git`, **VS Code** (the per-user install, under `~\AppData\Local`, no administrator
   needed), the **Microsoft Visual C++ Redistributable 2015–2022** (x64 and x86 — the
   prerequisite TortoiseGit's own FAQ names, so it comes first), **TortoiseGit**, `node`,
   `python`, `claude`. **winget is not used at all** — every one of them is downloaded
   from its vendor and installed silently. (winget is absent on Windows Server, and
   present-but-broken on a clean Windows 11: measured 2026-10-07, three tools, three
   identical `Failed when opening source(s)` failures before the download anyway.) `git`
   and `TortoiseGit` each ask their own project for the current version first, so the
   pinned URLs are only the last resort; VS Code and the VC++ runtime come from the
   vendor's permanent always-current links
3. **VS Code extensions** — `anthropic.claude-code`, installed through VS Code's own
   `code --install-extension`
4. **Instruction files** — `Tools/deploy.py` places the user-scope pair and the project
   template
5. **Graph servers** — `graph-servers/install.ps1` installs both servers, registers the MCP
   entries, wires the refresh and post-commit hooks, builds the first index and starts the
   watch daemon
6. **claude-mem** — cross-session memory, local only
7. **Claude Code plugins** — `dispatch-guard` (the rules this repository runs on and the
   hook that enforces them) and `mattpocock-skills` (skills: TDD, diagnosing bugs, code
   review, domain modelling)

⚠ `dispatch-guard` reaches past this project — it installs a statusline and a background
usage watcher for the whole machine. It became a default on 2026-10-06; it used to sit
behind `-All`, and that flag is gone. Passing it does nothing and the script says so.

### The flags you will actually use

| Flag | What it does |
|---|---|
| `-CheckOnly` | Reports what it would do and writes nothing but its own log |
| `-Repo <path>` | **Which project to apply the per-repo work to.** See below |
| `-Pdg` | Also build the PDG layers. `explain` (taint) and `pdg_query` need them, they are much slower, and it has to be on the **first** run: the index step runs unconditionally, so asking later means paying for the whole pass again |
| `-SkipDeps` | Install no missing tools; configure only |
| `-LogPath <path>` | Move the transcript |
| `-Cowork yes` / `-Cowork no` | Answers the one question up front, so the script does not ask. See below |
| `-SelfTest` | Offline self-test. Touches nothing, not even the log |
| `-CheckUrls` | Are the pinned download URLs still alive? |

⚠ **`-Repo` defaults to this clone.** Part of the work is done *for a project*: the
post-commit hook, the first index, the watch daemon, `CLAUDE.local.md`. Leave `-Repo` out
and all of that lands on the dev-workstation clone itself rather than on the project you
actually want to work in. Name it explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo C:\code\my-project
```

### The one question it asks

The whole install asks exactly one thing: **install claude-mem Cowork
(`claude-mem-cowork@thedotmack`) or not?**

It is the **cloud** half of claude-mem. Its own marketplace entry says its hooks "stream
tool use to cmem.ai and inject observations into new sessions and agents" — it **sends your
tool use to an external service**. The local claude-mem from step 5 does not, and does not
need it. So it is not part of the default.

The question comes **at the very start**, after the script has printed what it is about to
do and before it installs anything. It does not surface forty minutes in.

- Only `Y` installs it. `N`, Enter, Esc, and **no answer for 30 seconds all mean no**.
- `-Cowork yes` or `-Cowork no` skips the question entirely.
- **With stdin not a terminal** — a script, CI, launched by another tool — **it does not
  ask and does not install it**, and it does not stall for the countdown either. To install
  it unattended, pass `-Cowork yes` explicitly.
- Add it later with `.\install.ps1 -Cowork yes`; remove it with
  `claude plugin uninstall claude-mem-cowork@thedotmack`.

### What it writes

**This script owns exactly one file: its own log.** Every other write is done by one of
the tools it calls, each of which already carries its own backup, post-write check and
rollback. Two owners for one file is how a file gets clobbered by the owner that lost
track.

Every run is transcribed to `Debug\install-<stamp>.log` beside the script, and the
**absolute path is printed at the top of the run and again on every exit, including every
failure**.

⚠ **It installs a tool that is absent; it never replaces one you chose.** A toolchain that
is present but too old stops the run at the prerequisite gate, with that gate's own upgrade
command. Replacing a toolchain you picked is not this script's call.

⚠ **One step may ask you a question.** Run from a real terminal, the claude-mem installer
can show a screen comparing its paid cloud tier with local-only mode. The script prints an
explanation immediately **before** that step, and the answer is **local** — which is what
the flags it passes already select. Run unattended it does not ask at all. Details in
[`claude-mem/README.md`](claude-mem/README.md).

⚠ **`graph-servers/graph-refresh.ps1` needs PowerShell 7.** It is a user-scope hook,
started as `powershell` (5.1) by both post-commit and SessionStart, so it relaunches itself
under pwsh and refuses with a log line when no PowerShell 7 is installed. You should never
meet that refusal — step 1 of the install puts PowerShell 7 there — only a host where it
was removed afterwards. post-commit exits 0 either way, so **no `git commit` ever fails
over it**.

### Checking it still works before you need it

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SelfTest    # offline, touches nothing
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckUrls   # are the pinned downloads alive?
```

`-CheckUrls` is the one to re-run every few months. The four pinned installer URLs are the
part of this repository that decays without anyone touching it, and a 404 only shows up
when you are standing in front of a machine with no toolchain. It sends one HEAD request
per URL plus a deliberate 404 control, downloads nothing, and exits non-zero if a URL died
**or if the control passed** — a probe that cannot discriminate is not evidence.

## Where the memory lives

`~/` is your user directory (`%USERPROFILE%`, e.g. `C:\Users\you`); `<project>` is a
project's root.

### Travels with the project, and is in git

| Location | What |
|---|---|
| `<project>/Memory/notes/` | **the project's own memory**: decision notes |
| `<project>/Memory/tasks/<stamp-task-name>/` | one folder per task: prompts, result records, acceptance harnesses, captured evidence |
| `<project>/CLAUDE.md` | project-scope agent instructions |

`Memory/` is **tracked on purpose** — it is the reasoning behind every commit. The public
snapshot excludes it through `Tools/publish-public.py`, by rule, not through `.gitignore`.

### Travels with the project, but is not in git

| Location | What |
|---|---|
| `<project>/CLAUDE.local.md` | personal harness config (how to use the graph servers); git-ignored |
| `<project>/.gitnexus/` | GitNexus's index and graph database |
| `<project>/.code-review-graph/` | code-review-graph's graph database and embeddings |

### This machine only

| Location | What |
|---|---|
| `~/.claude/CLAUDE.md` | universal rules, loaded in every session of every project |
| `~/.claude/docs/VERIFICATION-LESSONS.md` | the verification rules those universal rules point at |
| `~/.claude/settings.json` | hooks, MCP servers, enabled plugins |
| `~/.claude/projects/<project path as a name>/<session-id>.jsonl` | **the transcripts**: one file per session, the whole conversation and every tool call |
| `~/.claude/projects/<same>/<session-id>/tool-results/` | tool output too large to sit in the transcript |
| `~/.claude/file-history/<session-id>/` | snapshots of files Claude Code edited, for undo |
| `~/.claude/shell-snapshots/`, `~/.claude/sessions/`, `~/.claude/state/` | Claude Code's own session state; nothing here touches it |
| `~/.claude-mem/claude-mem.db` | **claude-mem's memory**: cross-session observations and summaries (SQLite) |
| `~/.claude-mem/chroma/` | the vector index over the same memory, for semantic search |
| `~/.claude-mem/corpora/`, `~/.claude-mem/logs/` | knowledge corpora and the worker's log |
| `~/.code-review-graph/` | the watch daemon's state and the list of watched projects (`watch.toml`, `registry.json`) |

⚠ **`<project>/Memory/` and `~/.claude-mem/` are not the same thing.** The first is written
by people and travels with the repository; the second is recorded automatically by
claude-mem and never leaves this machine. `claude-mem/claude-md-snippet.md` carries a rule
whose only job is to stop an agent confusing them.

⚠ **These grow, faster than you would guess.** Measured on one machine, 2026-10-06:
`~/.claude-mem` 2.0 GB (of which `claude-mem.db` with its WAL is 745 MB), `~/.claude/projects`
1.9 GB of transcripts, `~/.code-review-graph` 31.5 GB (`graph.db` 25.2 GB plus a 6.3 GB WAL).
Worth a look before moving to a new machine.

### What to carry to a new machine

Re-running `install.ps1` brings these back, because each is rebuilt from something else:
`~/.claude/CLAUDE.md`, `~/.claude/docs/`, `<project>/.gitnexus/`,
`<project>/.code-review-graph/`, `~/.code-review-graph/`.

**Only two cannot be rebuilt**: `<project>/Memory/` (it is in git, so a clone has it) and
`~/.claude-mem/` (it is in no repository — copy it yourself). The transcripts under
`~/.claude/projects/` are not in a repository either, but claude-mem has already distilled
them.

## Conventions

- **Windows first.** The scripts are PowerShell; the git hooks are `sh` (Git Bash ships
  with Git for Windows).
- **`<angle-brackets>` mean "replace this"**, brackets included — `<repo-root>` becomes
  `C:\code\my-project`. Real environment variables (`%USERPROFILE%`, `$env:USERPROFILE`,
  `$USERPROFILE`) are used as-is.
- **Idempotent.** Every installer is safe to re-run; it fills in what is missing and leaves
  existing values alone. A second run skips what is already installed rather than
  reinstalling it.
- **No machine-specific values, no secrets.** Anything host-specific is a placeholder or an
  environment variable. Nothing here reads a credential.
- **Measurements, not guesses.** Where a guide quotes a duration, it says when it was
  measured and on what.

## License

[MIT](LICENSE). The scripts install and configure third-party tools; those tools keep their
own licences.
