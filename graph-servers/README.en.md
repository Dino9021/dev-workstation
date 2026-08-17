# Code-graph MCP servers — setup guide for a fresh Windows host

Traditional Chinese edition: [`README.zh-TW.md`](README.zh-TW.md)

This document explains how to install and configure both code-graph MCP servers — **GitNexus** and **code-review-graph** — from scratch on a **fresh Windows development host**, including the hooks that keep the indexes current.

**The steps are identical for the VSCode Claude Code extension and the Claude Code CLI.** Both read the same user configuration (`%USERPROFILE%\.claude\settings.json` and `%USERPROFILE%\.claude.json`), where the MCP servers and hooks are registered. Install once, and both work.

> Every timing in this document was measured on 2026-08-17 against a **real project** (1084 files, 302 of them code files). They are measurements, not estimates. Another machine or another project will differ.

**Placeholder convention**: anything wrapped in `<angle-brackets>` is a value **you must replace**, and you replace **the brackets too**. For example, `<repo-root>` becomes `C:\code\my-project`.

| Placeholder | Meaning | Example value (example only) |
|---|---|---|
| `<repo-root>` | absolute path to your repository | `C:\code\my-project` |
| `<python-path>` | absolute path to `python.exe` | `%LOCALAPPDATA%\Programs\Python\Python314\python.exe` |
| `<your-username>` | your Windows account name | `alice` |
| `<repo-alias>` | short alias used by the daemon | `myproj` |
| `<dev-workstation-root>` | where this tooling repo is checked out | `C:\code\dev-workstation` |
| `<server-name>` | an MCP server name | `gitnexus` |

**Environment variables that already exist are used as-is — do not replace them**: `%USERPROFILE%` (cmd/PowerShell paths), `$env:USERPROFILE` (PowerShell code), `$USERPROFILE` (Git Bash). Only JSON files never expand environment variables, so absolute paths are unavoidable there (`install.ps1` fills them in for you).

---

## 0. What each server owns

**Neither server is always first choice.** Pick by the question, with no default preference. This split belongs in your project's `CLAUDE.md` / `AGENTS.md` so your AI assistant follows it — a paste-ready version is in [`claude-md-snippet.md`](claude-md-snippet.md) (see section 6.4).

| | code-review-graph | GitNexus |
|---|---|---|
| Owns | symbol lookup, structure, impact radius | taint, PDG, execution flow, Cypher |
| Signature tools | `query_graph_tool`, `traverse_graph_tool`, `get_impact_radius_tool`, `get_architecture_overview_tool`, `semantic_search_nodes_tool` | `explain` (taint), `pdg_query`, `query`/`trace`, `cypher`, `rename` |
| Index location | `<repo-root>\.code-review-graph\graph.db` | `<repo-root>\.gitnexus\lbug` |
| Index coverage | **code files only** (301 in the measured project) | every file (1084 in the measured project, including `docs/*.md` and JSON) |
| Refresh speed | ~2s after a save | ~142s for a full pass |
| Refresh trigger | watch daemon | after a commit |

Their databases are completely separate — no shared files, no lock contention — so coexistence itself is safe. **Never ask both servers the same question**: it burns tokens without buying certainty.

---

## 1. Prerequisites

| Requirement | Minimum | Where the minimum comes from | Version measured here |
|---|---|---|---|
| Node.js | **22.0.0+** | gitnexus `package.json` → `engines.node: ">=22.0.0"` | 24.18.0 |
| npm | ships with Node | — | 12.0.1 |
| Python | **3.10+** | code-review-graph `Requires-Python: >=3.10` | 3.14.6 |
| Git for Windows | none declared | needed for the Git Bash that runs the `post-commit` hook | 2.55.0 |
| Claude Code | none declared | — | 2.1.228 |

These minimums are what the packages themselves declare, not guesses. **`install.ps1` compares the actual versions** and blocks on a mismatch (see the next section).

**Python install note**: install it **per-user** (the default `%LOCALAPPDATA%\Programs\Python\Python3xx`) rather than into `C:\Program Files`, which needs administrator rights for `pip install`. Tick "Add python.exe to PATH".

⚠️ **Do not use the Microsoft Store build of Python.** It is a shim, `python -m <module>` frequently fails to see installed packages, and when the MCP server dies Claude Code only reports `MCP error -32000: Connection closed`, which hides the real cause.

---

## 2. Fastest path: run the installer

```powershell
cd <dev-workstation-root>\graph-servers
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly     # environment check only
powershell -ExecutionPolicy Bypass -File .\install.ps1                # machine-wide steps
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root>   # per-repo steps
```

**It checks the prerequisites first and blocks with install instructions if anything is missing.** All five tools are version-compared and reported as `OK` / `TOO OLD` / `MISSING`; a single failure **stops the run before anything is installed** (exit code 1) and prints the `winget install` command plus the official download URL for each. Reason: a half-configured machine is harder to diagnose than a clean stop.

**It offers to install them for you.** When something is missing it asks:

```
   Install node, python, git now with winget? [y/N]
```

Answer `y` and it installs through winget, then **rebuilds PATH inside the same process and re-checks** — if everything passes it carries on, with no "re-open your terminal" round trip. Press Enter or `n` and it stops as before (the default is No, so a stray Enter installs nothing). An unrecognised answer such as `yep` is re-asked rather than guessed.

Pass `-InstallPrereqs` to skip the question and install straight away. **Nothing is ever installed silently** — installing system-level runtimes on someone's machine without asking is not acceptable behaviour, and it can conflict with an existing nvm/pyenv setup or a corporate policy.

⚠️ **When stdin is redirected (a pipe, CI, or a run launched by another tool) it does not ask** — it treats that as No, prints the install commands, and exits. A prompt nobody can answer would hang forever, and "it hung" is a far worse failure than "it told me what to install". Use `-InstallPrereqs` in those contexts; piping `y` into it deliberately does **not** work.

The script is idempotent and it **does patch `settings.json` for you** (the environment variables and the SessionStart hook from section 5), so there is no JSON left to paste by hand.

It edits that file conservatively:

1. Backs it up to `settings.json.bak-<timestamp>` first.
2. Writes with `ConvertTo-Json -Depth 100`. **The depth is mandatory** — the default of 2 serialises the nested hooks structures as the literal string `System.Object[]` and destroys the file.
3. **Verifies its own output**: does it parse, is `SessionStart` still a JSON array, did `System.Object[]` appear, did any pre-existing top-level key disappear. Any failure **restores the backup and reports failure**.
4. **Never overwrites an existing value** — it only fills in what is missing. A value you set deliberately survives, and a re-run produces no second backup.

| Flag | Effect |
|---|---|
| `-CheckOnly` | check prerequisite versions only, install nothing |
| `-InstallPrereqs` | install missing prerequisites through winget (never automatic) |
| `-SelfTest` | run the script's own version-parsing/comparison tests (10 assertions), touching nothing |
| `-Repo <repo-root>` | also run the per-repo steps (post-commit hook, first index, embeddings, daemon) |
| `-Pdg` | add `--pdg` to the first index; required by `explain` (taint) and `pdg_query`. Much slower |
| `-PatchOnly` | patch `settings.json` only, skip every install step |
| `-NoSettingsPatch` | leave the settings file alone and print the JSON to merge yourself |
| `-NoAgentDoc` | do not write the rule into the project's `CLAUDE.md` (section 6.4) |
| `-AgentDocName AGENTS.md` | write into `AGENTS.md` instead of `CLAUDE.md` |
| `-SettingsPath <settings-path>` | target a different settings file (used for testing) |

⚠️ **It reformats the whole file through PowerShell's JSON writer.** The content is preserved but the layout changes (Windows PowerShell 5.1 produces an aligned style; pwsh 7 produces 2-space indentation). Use `-NoSettingsPatch` if you care about your hand-written layout.

To understand each step, or to take over after a failure, follow sections 3–5.

---

## 3. Install GitNexus (machine-wide, once)

### 3.1 Global install

```powershell
npm install -g gitnexus
gitnexus --version
```

⚠️ **Do not rely on `npx gitnexus`.** npm 11.x sometimes crashes during the `npx` install (`node.target is null`, GitNexus issue #1939). A global install avoids it entirely.

### 3.2 Register with Claude Code

```powershell
gitnexus setup -c claude-code
```

That single command does three things:

1. Registers the MCP server in `%USERPROFILE%\.claude.json` (User scope, command `gitnexus.cmd mcp`).
2. Writes two hook entries into `%USERPROFILE%\.claude\settings.json` (`PreToolUse` and `PostToolUse`, both running `gitnexus-hook.cjs`) that **enrich Grep/Glob/Bash with graph context** and **detect a stale index and notify**.
3. Generates `.claude\skills\gitnexus\*` in the project (six SKILL.md usage guides).

Verify:

```powershell
claude mcp get gitnexus        # expect Scope: User config / Status: Connected
gitnexus doctor               # runtime capabilities and embedding configuration
```

### 3.3 Set the WAL checkpoint threshold (**important, do not skip**)

```powershell
# goes into the env block of %USERPROFILE%\.claude\settings.json (section 5)
"GITNEXUS_WAL_CHECKPOINT_THRESHOLD": "67108864"
```

**Why**: the GitNexus index file (215-285 MB in the measured project) is far larger than its default auto-checkpoint threshold (~16 MB). Below threshold, WAL checkpoint rotation fails, and the symptoms are:

- `.gitnexus\` keeps growing orphan files named `lbug.wal.missing-shadow.*`.
- **The index update aborts while the process still exits 0**, so it looks successful.
- Eventually the search index breaks: `FTS index 'file_fts' is inconsistent`.

Measured here on 2026-08-17: two analyze runs at the default threshold both left a `missing-shadow` file behind and never updated `lastCommit` in `meta.json`; with 64 MiB the very next run succeeded, node count rose from 14,013 to 14,022, and no orphan file appeared.

[`graph-refresh.ps1`](graph-refresh.ps1) also sets this variable internally, so an analyze launched by the git hook (outside Claude Code) is protected too.

---

## 4. Install code-review-graph (machine-wide, once)

### 4.1 Install with extras

```powershell
python -m pip install --upgrade "code-review-graph[embeddings,communities]"
python -m pip show code-review-graph
```

| Extra | Brings in | Consequence of skipping it |
|---|---|---|
| `embeddings` | numpy + sentence-transformers | **semantic search does not work at all** (zero vectors) |
| `communities` | igraph | falls back to slower file-based community detection (logged as `igraph not available`) |

Other optional extras: `enrichment` (jedi), `wiki` (ollama), `google-embeddings`, `all`.

🔴 **If you install `embeddings` you MUST raise the MCP startup timeout, or the server will fail to connect.** This is causal, not coincidental:

with the extra installed, the MCP server **loads the sentence-transformer model at startup** (measured 27–31 s), while Claude Code waits only **30 s** by default, so it reports:

```
Failed to connect — MCP server "code-review-graph" connection timed out after 30000ms
```

Before embeddings were installed, the handshake on this same machine took **4.98 s**.

**Lazy loading is not an option.** The eager preload is deliberate: the docstring of `prewarm_local_embeddings()` in `embeddings.py` states that on Windows, lazy-loading `sentence_transformers` + `torch` inside a FastMCP executor thread **blocks indefinitely** on DLL init / OpenMP thread-pool registration. The fix is to raise the client's wait (see `MCP_TIMEOUT` in section 5.2).

`HF_HUB_OFFLINE=1` only saves 3.5 s (31.33 → 27.83 s) — the cost is the model load, not the network — and it breaks the first run on a host where the model is not cached yet, so this guide does not recommend it.

### 4.2 Confirm the SAME python can import it

```powershell
python -c "import code_review_graph, sentence_transformers; print('import ok')"
where.exe python
```

⚠️ **This is the most common failure.** The MCP server is launched from an **absolute python.exe path stored in the config**. If that path does not exist, or that Python lacks the package, Claude Code only says:

```
MCP error -32000: Connection closed
```

It happened here once: the config said `C:\Program Files\Python314\python.exe` while the real install was in `%LOCALAPPDATA%\Programs\Python\Python314\`.

If `python` resolves to the wrong interpreter, set a user environment variable `CRG_PYTHON` pointing at the correct `python.exe`; [`graph-refresh.ps1`](graph-refresh.ps1) prefers it.

### 4.3 Register with Claude Code (**by hand — not with its own installer**)

```powershell
claude mcp add -s user code-review-graph -- "<python-path>" -m code_review_graph serve
claude mcp get code-review-graph
```

⚠️ **Do not run `code-review-graph install --platform claude-code`.** Its dry-run shows it would do two things you do not want:

1. Write a **`.mcp.json` in the project root** (version-controlled, affects everyone else).
2. **Append its own instructions to `CLAUDE.md`**.

A manual User-scope registration has neither side effect.

---

## 5. Configure automatic refresh (machine-wide)

> Running `install.ps1` from section 2 **completes this entire section** (it copies the hook script and patches `settings.json`). What follows is the manual equivalent, for doing it yourself or for understanding exactly what the script changed.

### 5.1 Install the hook script

```powershell
copy graph-servers\graph-refresh.ps1 %USERPROFILE%\.claude\hooks\
```

### 5.2 Merge into settings.json

**Merge** (do not overwrite) the following into `%USERPROFILE%\.claude\settings.json`, fixing the path:

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

What the three environment variables are for:

| Variable | Why it is needed |
|---|---|
| `GITNEXUS_WAL_CHECKPOINT_THRESHOLD` | See section 3.3. Without it the GitNexus index corrupts silently |
| `MCP_TIMEOUT` | See section 4.1. Without it code-review-graph fails to connect while loading its model |
| `MCP_CONNECT_TIMEOUT_MS` | Same reason. Both are set because I could not confirm from the binary which one governs the 30 s connect timeout; both are recognised Claude Code variables, so setting the extra one is harmless |

`gitnexus setup` already wrote its own `PreToolUse` / `PostToolUse` entries into that same file — **do not overwrite them**. Check the JSON afterwards:

```powershell
Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json | Out-Null; "JSON OK"
```

### 5.3 Why there is no "refresh on every Edit" hook

Measured finding: **`cmd /c start /b` does not truly detach on Windows.** The child inherits the hook's stdin pipe, so the caller waits for the whole refresh anyway.

| Approach | Blocking time per Edit |
|---|---|
| Fully synchronous | 3940 ms |
| `cmd /c start /b` (looks detached, is not) | 3960 ms |
| `Start-Process -WindowStyle Hidden` (used by this script) | **804 ms** |
| **Watch daemon instead (current design)** | **0 ms** |

So the `Edit`/`Write` PostToolUse hook was removed entirely; code-review-graph's own watch daemon does the job. Its debounce is 0.3s and a save reaches the graph in about 2 seconds.

### 5.4 The three triggers

| When | Trigger | What it does | Blocking cost |
|---|---|---|---|
| Save (any editor) | code-review-graph daemon | refresh code-review-graph | **0 ms** |
| `git commit` | `.git\hooks\post-commit` | run GitNexus analyze | ~1.2 s |
| New session | `SessionStart` hook | ensure the daemon is alive + catch-up pass + GitNexus gate | ~0.9 s |

The GitNexus path is **gated**: it only runs when `lastCommit` in `.gitnexus\meta.json` differs from `HEAD`. With a current index it returns in 820 ms and starts no node process, so a new session never wastes 142 seconds.

Keep the SessionStart entry: `git pull` brings in new commits without a local commit, so `post-commit` never fires for them.

---

## 6. Per-repository steps

### 6.1 First index

```powershell
cd <repo-root>
gitnexus analyze                     # add --pdg if you need taint/PDG
python -m code_review_graph build --repo .
python -m code_review_graph embed --repo .
```

⚠️ **`gitnexus analyze` exits 0 even when it fails.** Always read the output text and look for `Analysis failed`. It happened twice here: exit 0, index untouched.

### 6.2 Install the post-commit hook

```powershell
copy graph-servers\post-commit <repo-root>\.git\hooks\post-commit
bash -c "chmod +x .git/hooks/post-commit"
```

Check first that you are not clobbering something:

```powershell
git config core.hooksPath          # any output means hooks live elsewhere
dir .git\hooks | findstr /v sample
```

⚠️ **`.git\hooks\` is not version-controlled.** A fresh clone will not have this hook; re-install it there.

### 6.3 Start the watch daemon

```powershell
python -m code_review_graph daemon add <repo-root> --alias <repo-alias>
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\hooks\graph-refresh.ps1" -Which crg -Repo <repo-root> -Detach
python -m code_review_graph daemon status
```

⚠️ **Do not run `daemon start` directly.** It prints "Forking is not supported on Windows — running in foreground" and blocks; closing the terminal kills it. Launch it through `graph-refresh.ps1 -Detach` (which uses `Start-Process -WindowStyle Hidden`) so it survives across sessions. It dies on reboot, and the next SessionStart revives it.

### 6.4 Tell your AI agent how to use the two servers (**do not skip**)

Installing the servers does **not** mean an agent uses them correctly. Without a written rule it picks whichever tool it saw first, asks both the same question at double the token cost, and trusts a stale index to give you a wrong answer.

**`install.ps1 -Repo <repo-root>` writes it for you** — no pasting required:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -PatchOnly -Repo <repo-root>
```

It wraps the rule in its own markers (`<!-- code-graph-servers:start -->` … `end`), so a re-run **updates in place** instead of adding a second copy, **nothing outside those markers changes** (verified after the write; the backup is restored if it did), and a missing CLAUDE.md is created. The rule text has a **single source** — everything below the `---` in [`claude-md-snippet.md`](claude-md-snippet.md). Edit it there and re-run.

Target `AGENTS.md` instead with `-AgentDocName AGENTS.md`. Skip this step entirely with `-NoAgentDoc`.

⚠️ **If your project already carries the same rule written by hand**, the script cannot recognise it (no markers) and will add a second copy. Use `-NoAgentDoc`, or delete the hand-written one first.

Pasting by hand also works — take everything below the `---` in the snippet. Either way it covers:

- the split by capability (which server owns symbol lookup, which owns taint and execution flow), stating explicitly that **neither is always first choice**;
- the **freshness difference**: code-review-graph re-reads the database per call (live), while GitNexus caches its index at server startup (next session only);
- the four preconditions that otherwise produce wrong answers: uncommitted code is absent from the GitNexus graph, non-code files exist only in GitNexus, semantic search needs embeddings that the daemon never computes, and `gitnexus analyze` exits 0 even when it failed.

⚠️ **It must live OUTSIDE the `<!-- gitnexus:start -->` … `<!-- gitnexus:end -->` markers.** That block comes from `gitnexus setup` and the next `analyze` **overwrites all of it**, so anything inside is lost. The script appends **after** that block (position verified by test), and if it finds our markers already sitting inside the gitnexus ones it **refuses to write and tells you to move them out** rather than quietly writing into a region that gets wiped.

That block also says "always run GitNexus `impact` before editing a symbol", which contradicts this split — the snippet explicitly supersedes that line.

### 6.5 No `.gitignore` edit needed

Both tools drop a `.gitignore` containing `*` inside their own folder, so they ignore themselves. `git status` never shows them — **do not add rules by hand**.

---

## 7. Verification checklist (each is a five-second command)

```powershell
# are both servers connected
claude mcp list

# is the GitNexus index level with HEAD
python -c "import json;print(json.load(open('.gitnexus/meta.json',encoding='utf-8'))['lastCommit'][:12])"
git rev-parse HEAD

# any WAL orphans left behind (expect none)
dir .gitnexus\lbug.wal.missing-shadow.* 2>nul

# code-review-graph stats and whether it matches HEAD
python -m code_review_graph status --repo .

# vector count for semantic search (0 means unusable)
python -c "import sqlite3;print(sqlite3.connect(r'.code-review-graph/graph.db').execute('select count(*) from embeddings').fetchone())"

# is the daemon alive
python -m code_review_graph daemon status

# failure log from the hook script
type %TEMP%\claude-graph-refresh.log
```

---

## 8. Pitfalls (all evidenced on 2026-08-17)

### 8.1 `MCP error -32000: Connection closed`
The `python.exe` path in the config does not exist. Compare `claude mcp get <server-name>` against `where.exe python`.

### 8.2 `connection timed out after 30000ms`
**First question: is the `embeddings` extra installed?** If yes, that is the cause (see section 4.1): the MCP server spends 27–31 s loading its model at startup, past the 30 s default. Fix it by setting `MCP_TIMEOUT` / `MCP_CONNECT_TIMEOUT_MS` to `120000`.

If embeddings are not installed and it still times out: a normal handshake measured **4.98 s**, far below the ceiling, so do not rush to change the config. That case was not reproducible here; the likeliest cause is CPU/disk saturation at startup (a Gradle build, a Defender scan). Run `claude --debug mcp` to capture the real cause.

To measure the handshake yourself: write one `initialize` request to the server's stdin and time the first stdout line.

### 8.3 `FTS index 'file_fts' is inconsistent`
```powershell
gitnexus analyze --repair-fts
```
No need to delete the whole index. `gitnexus clean` removes all of `.gitnexus\` including `run.cjs`, which costs far more.

### 8.4 `lbug.wal.missing-shadow.*` files keep appearing
The WAL checkpoint threshold is too small. See section 3.3. Make sure no analyze is running before deleting the orphans.

### 8.5 Exit code 0 lies
`gitnexus analyze` returns 0 on failure. Judge success from the **output text** and from `lastCommit` in `meta.json`, never from the exit code.

### 8.6 `daemon start` hangs
Windows cannot fork. See section 6.3.

### 8.7 Semantic search misses freshly changed code
**The daemon does not compute embeddings.** Measured: a new function reached the `nodes` table within 15 s while the `embeddings` table stayed at **0 rows**. It does not error — it silently misses. Re-run by hand after substantial changes:
```powershell
python -m code_review_graph embed --repo .
```

### 8.8 Judging "does this symbol exist" from `search` output gives false positives
`code-review-graph search` **echoes the query string** in its JSON (`"query": "<your-query>"`), so a string match against the output "finds" a symbol that does not exist. Query the database instead:
```powershell
python -c "import sqlite3;print(sqlite3.connect(r'.code-review-graph/graph.db').execute(\"select count(*) from nodes where name like '%your_symbol%'\").fetchone())"
```

### 8.9 Do not judge "did it update" from the `graph.db` file timestamp
SQLite can write inside existing pages, so the main file's mtime does not always change. Measured: the metadata already read `10:41:07` while the file mtime still read `10:18:18` — which looks exactly like "it never ran". Read the metadata instead:

```powershell
python -m code_review_graph status --repo .    # look at the Last updated line
```

This class of mistake happened three times in a single day (the others are 8.8 and 5.3). The lesson: **before trusting a check, confirm the instrument measures what you think it measures.**

### 8.10 Do not hand-edit the GitNexus section of CLAUDE.md
It sits between `<!-- gitnexus:start -->` and `<!-- gitnexus:end -->` and is **generated by the gitnexus CLI**; the next `analyze` overwrites the whole block. Put rule changes outside the markers.

### 8.11 The two MCP servers cache their index differently
| | After the index is refreshed |
|---|---|
| code-review-graph | **live** (re-reads the database per call) |
| GitNexus | **next session only** (index cached at server startup) |

So a GitNexus analyze that finishes after a commit is invisible to the current session; reconnect with `/mcp` or start a new session.

---

### 8.12 Renaming or moving a folder fails with `being used by another process`
**The watch daemon holds directory handles on Windows.** It watches the whole repo recursively through watchdog, so no folder inside the watched tree can be renamed or moved — `Move-Item` reports that another process is using it.

Stop, move, restart:

```powershell
python -m code_review_graph daemon stop
Move-Item <old-path> <new-path>
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\hooks\graph-refresh.ps1" -Which crg -Repo <repo-root> -Detach
```

The same cause blocks `git worktree remove`, folder deletion, and some IDE refactor-move operations.

---

## 9. Uninstall

```powershell
gitnexus uninstall                        # removes MCP entries, skills, hooks
claude mcp remove code-review-graph -s user
python -m code_review_graph daemon stop
python -m code_review_graph uninstall     # removes its data, configs, hooks, skills
```

Then remove by hand: `%USERPROFILE%\.claude\hooks\graph-refresh.ps1`, `<repo-root>\.git\hooks\post-commit`, and the `SessionStart` entry plus the `env` line in `settings.json`.

---

## 10. Files in this directory

| File | Purpose |
|---|---|
| [`install.ps1`](install.ps1) | machine-wide + per-repo install in one go, idempotent |
| [`graph-refresh.ps1`](graph-refresh.ps1) | the refresh script used by the hooks (master copy; installed to `~\.claude\hooks\`) |
| [`post-commit`](post-commit) | git hook master copy (installed to `<repo-root>\.git\hooks\`) |
| [`claude-md-snippet.md`](claude-md-snippet.md) | the usage rule to paste into your project's `CLAUDE.md` (section 6.4) |
| [`README.zh-TW.md`](README.zh-TW.md) / `README.en.md` | this document |
