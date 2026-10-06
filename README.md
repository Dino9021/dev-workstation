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

### 第一次安裝

```powershell
git clone https://github.com/Dino9021/dev-workstation.git
cd dev-workstation
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly   # 只檢查，不動手
powershell -ExecutionPolicy Bypass -File .\install.ps1              # 真的安裝
```

⚠ **全新主機上，第一行跑不起來**，因為它還沒有 `git`——而裝 `git` 正是這支腳本的工作之一。請先到 GitHub 用 *Code → Download ZIP* 下載壓縮檔，解開後直接跑 `install.ps1`。它會把 `git` 裝好，之後想要完整歷史再重新 clone 一次即可。

用 Windows PowerShell 5.1 直接跑就好。腳本會自己安裝 PowerShell 7，再把工作交棒過去。

### 安裝順序

1. **PowerShell 7**——先裝它，然後整支腳本重新在它底下執行
2. **工具鏈**——`git`、`node`、`python`、`claude`。有 winget 套件的走 winget，沒有的用原廠靜默安裝檔
3. **指令檔**——`Tools/deploy.py` 放置使用者層級的兩份與專案層級的範本
4. **圖譜伺服器**——`graph-servers/install.ps1` 裝兩台伺服器、註冊 MCP、掛 refresh hook 與 post-commit hook、建第一次索引、啟動背景監看服務
5. **claude-mem**——跨 session 記憶，純本機

加上 `-All` 會多裝第六項 `dispatch-guard`。它預設不裝，因為它伸手到這個專案以外：會為整台機器裝一條狀態列和一個背景額度監看工作。不加 `-All` 時，腳本會在最後把那三條指令印出來讓你自己決定。

### 常用參數

| 參數 | 作用 |
|---|---|
| `-CheckOnly` | 只報告會做什麼，除了自己的 log 以外什麼都不寫 |
| `-Repo <路徑>` | **指定要套用的專案**。見下方說明 |
| `-Pdg` | 建索引時多建 PDG 層。`explain`（汙染分析）與 `pdg_query` 需要它，但慢很多，而且**必須在第一次執行時就加**：索引那一步無條件執行，事後才想要就得整個再跑一次 |
| `-SkipDeps` | 不安裝任何缺少的工具，只做設定 |
| `-LogPath <路徑>` | 改變 log 位置 |
| `-All` | 連 `dispatch-guard` 一起裝 |
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

### First install

```powershell
git clone https://github.com/Dino9021/dev-workstation.git
cd dev-workstation
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly   # report only
powershell -ExecutionPolicy Bypass -File .\install.ps1              # do it
```

⚠ **On a fresh host that first line cannot run**, because there is no `git` yet — and
installing `git` is one of the things this script does. Download the repository as a ZIP
from GitHub (*Code → Download ZIP*), unpack it and run `install.ps1` from there. It
installs `git`, and you can re-clone properly afterwards if you want the history.

Run it from Windows PowerShell 5.1. The script installs PowerShell 7 itself and hands over
to it.

### The order it installs in

1. **PowerShell 7** — first, then the whole script relaunches under it
2. **Toolchain** — `git`, `node`, `python`, `claude`: winget where there is a package, the
   vendor's own silent installer where there is not
3. **Instruction files** — `Tools/deploy.py` places the user-scope pair and the project
   template
4. **Graph servers** — `graph-servers/install.ps1` installs both servers, registers the MCP
   entries, wires the refresh and post-commit hooks, builds the first index and starts the
   watch daemon
5. **claude-mem** — cross-session memory, local only

`-All` adds a sixth: `dispatch-guard`. It is off by default because it reaches past this
project — it installs a statusline and a background usage watcher for the whole machine.
Without `-All` the script prints its three commands at the end instead of running them.

### The flags you will actually use

| Flag | What it does |
|---|---|
| `-CheckOnly` | Reports what it would do and writes nothing but its own log |
| `-Repo <path>` | **Which project to apply the per-repo work to.** See below |
| `-Pdg` | Also build the PDG layers. `explain` (taint) and `pdg_query` need them, they are much slower, and it has to be on the **first** run: the index step runs unconditionally, so asking later means paying for the whole pass again |
| `-SkipDeps` | Install no missing tools; configure only |
| `-LogPath <path>` | Move the transcript |
| `-All` | Also install `dispatch-guard` |
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
