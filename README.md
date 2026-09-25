# dev-workstation

Repeatable setup for a development machine: the install guides and scripts I re-run on every new host, instead of rediscovering the same pitfalls.

開發機的可重複設定：每次換新機器要重跑的安裝指南與腳本，不必再把同樣的坑踩一遍。

---

## What is here | 內容

| Folder | Sets up | 設定什麼 |
|---|---|---|
| [`graph-servers/`](graph-servers/) | Two code-graph MCP servers for Claude Code — **GitNexus** and **code-review-graph** — plus hooks that keep both indexes current | 兩台給 Claude Code 用的程式圖譜 MCP 伺服器，含自動更新索引的 hook |
| [`claude-mem/`](claude-mem/) | **claude-mem** — cross-session memory for the agent, installed by default: the four commands a scripted install needs (one of which everybody leaves out), and the rule that stops it being confused with the project's own `Memory/` folder | **claude-mem** — 跨 session 的記憶，預設就裝：腳本化安裝需要的四條指令（其中一條大家都漏掉），以及避免它跟專案自己的 `Memory/` 搞混的規則 |
| [`parallel-agent-operations/`](parallel-agent-operations/) | A `CLAUDE.md` rule that stops an agent fanning out into dozens of subagents on its own — it cannot see the session budget it would burn | 一段 `CLAUDE.md` 規則，阻止 AI 助手自作主張派出幾十個子代理（它看不到自己會燒掉多少額度） |

Each folder carries its own step-by-step guide in Traditional Chinese and English.

每個資料夾都有自己的 step-by-step 指南，正體中文與英文各一份。

---

## Conventions | 慣例

- **Windows first.** The scripts are PowerShell; the git hooks are `sh` (Git Bash ships with Git for Windows).
- **`<angle-brackets>` mean "replace this"**, brackets included — `<repo-root>` becomes `C:\code\my-project`. Real environment variables (`%USERPROFILE%`, `$env:USERPROFILE`, `$USERPROFILE`) are used as-is.
- **Idempotent.** Every installer is safe to re-run; it fills in what is missing and leaves existing values alone.
- **No machine-specific values, no secrets.** Anything host-specific is a placeholder or an environment variable. Nothing here reads a credential.
- **Measurements, not guesses.** Where a guide quotes a duration, it was measured, and it says when and on what.

<!-- -->

- **以 Windows 為主。** 腳本是 PowerShell；git hook 是 `sh`（Git for Windows 內含 Git Bash）。
- **`<角括號>` 代表「請替換」**，連括號一起換掉。真實存在的環境變數直接用，不要替換。
- **可重複執行。** 每個安裝器都能重跑，只補缺的、不覆蓋你已經設好的值。
- **沒有機器專屬值、沒有祕密。** 主機專屬的東西一律是佔位符或環境變數，這裡不讀任何帳密。
- **數字都是量出來的。** 指南裡出現的耗時都附上量測日期與對象。

---

## Getting started | 開始使用

```powershell
git clone https://github.com/Dino9021/dev-workstation.git
cd dev-workstation
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly   # report only
powershell -ExecutionPolicy Bypass -File .\install.ps1              # do it
```

⚠ **On a host with no `git` yet, that first line cannot run** — and installing git is one
of the things this script does. Download the repository as a ZIP from GitHub
(*Code → Download ZIP*), unpack it, and run `install.ps1` from there; it installs git, and
you can re-clone properly afterwards if you want the history.

⚠ **沒有 `git` 的新主機跑不了上面第一行** —— 而裝 git 正是這支腳本的工作之一。先從 GitHub
下載 ZIP（*Code → Download ZIP*）解開後直接跑 `install.ps1`，它會把 git 裝好；想要 git
歷史的話，之後再重新 clone 一次。

### Checking it still works before you need it | 在真的需要之前先確認它還能用

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SelfTest    # offline, touches nothing
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckUrls   # are the pinned downloads alive?
```

`-CheckUrls` is the one to re-run every few months: the four pinned installer URLs are the
part of this repository that decays without anyone touching it, and a 404 only shows up
when you are standing in front of a machine with no toolchain. It sends a HEAD request per
URL plus a deliberate 404 control, downloads nothing, and exits non-zero if a URL died
**or if the control passed** (a probe that cannot discriminate is not evidence).

`-CheckUrls` 建議每隔幾個月重跑：四個釘住的安裝檔網址是這個 repo 裡**沒人動它也會自己壞掉**
的部分，而 404 偏偏只在你站在一台沒有工具鏈的機器前面時才會發現。它每個網址發一個 HEAD，
外加一個故意會 404 的對照組，什麼都不下載；網址掛掉**或對照組居然通過**都會回傳非 0
（一個分辨不出差異的量測工具不算證據）。

The root [`install.ps1`](install.ps1) is the whole setup in one command: it checks the
toolchain and installs what is **missing**, then calls [`Tools/deploy.py`](Tools/deploy.py)
for the `CLAUDE.md` files, [`graph-servers/install.ps1`](graph-servers/install.ps1) for the
two graph servers, and installs [`claude-mem/`](claude-mem/) — all four steps by default.
Add `-All` and it also installs the `dispatch-guard` plugin, which is off by default because
it reaches past this project. The only file the script owns is its own log; everything else
is written by one of the tools it calls. Run it from Windows PowerShell 5.1 on a bare host;
it installs PowerShell 7 and hands over to it. A re-run is safe — and cheap: a second run
skips anything already installed rather than reinstalling it.

Every run is transcribed to `Debug\install-<stamp>.log` beside the script (`-LogPath`
moves it), and the **absolute path is printed at the top of the run and again on every
exit, including every failure**. So `-CheckOnly` writes exactly one thing, that log, and
nothing else; `-SelfTest` exits before the log starts and writes nothing at all.

⚠ It installs a tool that is **absent**; it never replaces one you chose. A toolchain
that is present but too old stops the run in the prerequisite gate, with that gate's own
upgrade command.

⚠ **One step may ask you a question.** Run from a real terminal, the claude-mem installer
can show a screen comparing its paid cloud tier with local-only mode. The script prints an
explanation immediately **before** that step, and the answer is **local** — which is what
the flags it passes already select. Run unattended it does not ask at all. Details in
[`claude-mem/README.md`](claude-mem/README.md).

Each folder still carries its own README, and those are the ones to read when a step
fails or you want to take over by hand.

根目錄的 [`install.ps1`](install.ps1) 就是一條指令跑完整套：檢查工具鏈、**只補缺的**，
再呼叫 [`Tools/deploy.py`](Tools/deploy.py) 放 `CLAUDE.md`、
[`graph-servers/install.ps1`](graph-servers/install.ps1) 裝兩台圖譜伺服器，以及裝
[`claude-mem/`](claude-mem/) —— 這四步都是預設就做。加上 `-All` 會連 `dispatch-guard`
plugin 也裝（它預設關，因為它伸手到這個專案以外）。這支腳本唯一擁有的檔案是它自己的 log，
其他都是它呼叫的工具寫的。全新主機上用 Windows PowerShell 5.1 直接跑即可 —— 它會自己裝
PowerShell 7 再把工作交給它。重跑安全，而且便宜：第二次跑會跳過已經裝好的東西，不會重裝。

每次執行都會完整記錄到旁邊的 `Debug\install-<時間戳>.log`（`-LogPath` 可改位置），
而且**絕對路徑會在開頭印一次、每一個結束點再印一次，包含每一種失敗**。所以
`-CheckOnly` 只寫這一份 log，別的什麼都不寫；`-SelfTest` 在 log 開始之前就結束，一個字都不寫。

⚠ 它只裝**不存在**的工具，絕不替換你自己選的版本。已安裝但版本太舊會停在前置需求閘門，
並印出該閘門自己的升級指令。

⚠ **其中一步可能會問你問題。** 在真正的終端機裡執行時，claude-mem 的安裝程式可能顯示一個
比較付費雲端方案與純本機模式的畫面。腳本會在那一步**開始之前**先印出說明，答案是**本機** ——
那正是它傳進去的旗標已經選好的。無人職守執行時它完全不會問。細節見
[`claude-mem/README.md`](claude-mem/README.md)。

每個資料夾仍有自己的 README；某一步失敗、或想手動接手時，要讀的是那幾份。

---

## License | 授權

[MIT](LICENSE). The scripts install and configure third-party tools; those tools keep their own licences.

[MIT](LICENSE)。本 repo 的腳本只是安裝與設定第三方工具，那些工具各自適用它們原本的授權。
