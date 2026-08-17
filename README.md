# dev-workstation

Repeatable setup for a development machine: the install guides and scripts I re-run on every new host, instead of rediscovering the same pitfalls.

開發機的可重複設定：每次換新機器要重跑的安裝指南與腳本，不必再把同樣的坑踩一遍。

---

## What is here | 內容

| Folder | Sets up | 設定什麼 |
|---|---|---|
| [`graph-servers/`](graph-servers/) | Two code-graph MCP servers for Claude Code — **GitNexus** and **code-review-graph** — plus hooks that keep both indexes current | 兩台給 Claude Code 用的程式圖譜 MCP 伺服器，含自動更新索引的 hook |
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
git clone https://github.com/<your-github-username>/dev-workstation.git
cd dev-workstation\graph-servers
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
```

Then read that folder's README before running the real install.

跑真正的安裝之前，先讀該資料夾的 README。

---

## License | 授權

[MIT](LICENSE). The scripts install and configure third-party tools; those tools keep their own licences.

[MIT](LICENSE)。本 repo 的腳本只是安裝與設定第三方工具，那些工具各自適用它們原本的授權。
