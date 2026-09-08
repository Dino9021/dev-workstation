# CLAUDE.md 片段 — AI 助手該怎麼用這兩台程式圖譜伺服器（正體中文，參考用）

⚠️ **這份是參考翻譯，安裝腳本預設不會注入它。** 實際注入的是英文版
[`claude-md-snippet.md`](claude-md-snippet.md)，那份才是規則的唯一來源。改規則請改英文版，
再把改動同步到這裡。真的要注入中文版，就明確指定
`install.ps1 -PatchOnly -Repo <repo-root> -SnippetPath .\claude-md-snippet.zh-TW.md`。
不要兩種語言注入同一份文件：同一條規則讀兩遍，token 加倍，而且兩邊遲早會走鐘。

安裝完不等於會用。沒有明文規則，AI 助手會挑它先看到的那台、把同一個問題問兩台、
並且相信一份過期的索引。這個檔案就是那條規則。

**怎麼用**：跑 `install.ps1 -PatchOnly -Repo <repo-root>`，安裝腳本會把橫線以下的內容
寫進該專案的 **`CLAUDE.local.md`**，包在自己的標記裡，重跑就地更新。也可以手動複製。

**為什麼是 `CLAUDE.local.md` 而不是 `CLAUDE.md`。** 這條規則是個人環境設定：它點名的
MCP 伺服器只有跑過安裝腳本的人才有，引用的 `.claude/skills/gitnexus/` 與
`.gitnexus/run.cjs` 依慣例都不進版控。放進共用、進版控的 `CLAUDE.md`，等於發給每個
clone 的人一份他們照做不了的指示。Claude Code 原生就讀 `CLAUDE.local.md`，安裝腳本也
會確認 git 真的忽略它。真的要放 `CLAUDE.md` 就加 `-SharedAgentDoc`，完全不要注入就加
`-NoAgentDoc`。

⚠️ **貼在 `<!-- gitnexus:start -->` 標記之外**，標記內的內容下一次 `analyze` 會整段
覆蓋。本 repo 的兩處呼叫都帶 `--skip-agents-md`，所以安裝腳本與 post-commit 都不會
產生或還原那段；只有你自己手動跑沒帶旗標的 `analyze` 才會遇到。

---

## 兩台程式圖譜伺服器：按能力分工

**兩台都不是永遠的第一順位。** 先看你要問什麼，再決定開哪一台，不要有預設偏好。

- **code-review-graph 負責：找符號、看結構、算影響範圍。** `query_graph_tool` /
  `traverse_graph_tool`（結構查詢與走訪）、`get_architecture_overview_tool`、
  `get_hub_nodes_tool` / `get_bridge_nodes_tool` / `get_community_tool`（架構與樞紐）、
  `get_impact_radius_tool` + `get_affected_flows_tool`（影響範圍）、
  `get_review_context_tool` / `get_minimal_context_tool`（審查用最小上下文）、
  `find_large_functions_tool`、`get_knowledge_gaps_tool`、`semantic_search_nodes_tool`
  （語意找符號，先看下方前提）。
- **GitNexus 負責：taint、PDG、execution flow、Cypher。** `explain`（汙染流
  source→sink，需要先跑過 `analyze --pdg`）、`pdg_query`（控制/資料依賴，「誰守住這一
  行」「這個值流去哪」）、`query` / `trace` 與
  `gitnexus://repo/<repo-name>/process/{name}`（執行流程逐步追蹤）、`cypher`（原始圖
  查詢）、`rename`（理解呼叫圖的多檔改名）。
- **同一個問題不要兩台都問。** 重複燒 token，換不到更高的確定性。兩台資料庫完全獨立
  （`.gitnexus/lbug` vs `.code-review-graph/graph.db`），不共用檔案、不搶鎖。
- **唯一刻意重疊的一題：C++ 跨檔呼叫者。** code-review-graph 的呼叫者查詢會把名稱解析
  到「定義所在檔案」的節點，跨編譯單元的呼叫者就漏掉了。這一題改問 GitNexus `impact`，
  並且兩個參數都不能省：`direction` 要給 `'upstream'`（「誰呼叫它」的方向），`target`
  要給 **`.hpp`** 宣告的 `target_uid`（uid 從先前的工具回傳拿，不是直接寫函式名稱）。
  對 `.cpp` 定義問會得到 `impactedCount: 0`。
  ⚠️ **這不表示 `impact` 就沒錯了。** 選對 `.hpp` uid 只排除掉其中一種 0 答案；另一種
  見下方「圖譜可信到哪裡」。
- ⚠️ **下方 `<!-- gitnexus:start -->` … `<!-- gitnexus:end -->` 之間的段落由 gitnexus
  CLI 自動產生。** 它寫「改任何符號前一律先跑 GitNexus `impact`」——**那一句以本條為
  準**：影響範圍走 code-review-graph 的 `get_impact_radius_tool`。標記內的文字不要手
  改，下次 `analyze` 會整段覆蓋。

### 查之前先確認索引夠新

| | 更新時機 | 涵蓋範圍 | 伺服器何時看得到新索引 |
|---|---|---|---|
| code-review-graph | 存檔後約 2 秒（常駐 daemon） | **只有程式碼檔** | **當場**（每次呼叫重讀資料庫） |
| GitNexus | `git commit` 後（post-commit hook，約 142 秒） | 全部檔案，含 `.md`、JSON | **下一個工作階段**（索引快取在伺服器啟動的瞬間） |

五個會讓你得到錯答案的前提，動手前先確認：

1. **只改了工作區、還沒 commit 的程式，GitNexus 圖譜裡沒有。** 需要它進圖譜就先
   commit，或手動跑 **`gitnexus analyze --skip-agents-md`**。—— **那個旗標不能省。**
   沒帶的話，`analyze` 會把自己那段 `<!-- gitnexus:start -->` 區塊 append 進專案的
   `CLAUDE.md` 與 `AGENTS.md`，改掉共用、進版控的檔案。
2. **`docs/*.md` 這類非程式碼內容只有 GitNexus 有**，code-review-graph 完全看不到。
3. **`semantic_search_nodes_tool` 需要向量。** 向量數 0 就等於不能用，而且**常駐
   daemon 不會替新程式補向量**——大幅改動後要手動 `code-review-graph embed`。五秒確認：
   `python -c "import sqlite3;print(sqlite3.connect(r'.code-review-graph/graph.db').execute('select count(*) from embeddings').fetchone())"`
4. **`gitnexus analyze` 失敗也回傳 exit code 0。** 判斷成功要看輸出文字有沒有
   `Analysis failed`，以及 `.gitnexus/meta.json` 的 `lastCommit` 是否等於 `HEAD`——
   **不要看 exit code**。
5. **別用 `graph.db` 的檔案時間（mtime）判斷索引有沒有更新。** SQLite 可能在既有頁面
   內寫入，主檔 mtime 不一定改變——看起來像「完全沒跑」。要判斷新鮮度看
   `code-review-graph status --repo .` 的 `Last updated` 那一行。

### 圖譜可信到哪裡

圖譜回答結構問題很便宜，也給得出純文字搜尋給不了的上下文，所以「先問圖譜」是划算的。
但**「誰呼叫這個函式」不要以圖譜為最終答案**。同一天、同一個 C++ 函式，兩台都少報了呼
叫者：code-review-graph 回報 1 個（實際 7 個），GitNexus `impact` 回報
`impactedCount: 0, epistemic: "exact"`（實際 4 個）。`epistemic: "exact"` 描述的是圖譜
自己，不是程式碼——一個錯答案會讀起來像確定的答案。

這份清單會左右你的動作時（要改簽章、要刪東西、要判斷「還有沒有人用」），就用 `git grep`
自己確認一次，並且**加一個陽性對照**：在同一次執行裡搜一個你已經知道存在的呼叫點，
證明樣式和路徑都對。搜不到東西和搜錯地方，在畫面上長得一模一樣。

**搬移或改名資料夾被拒（`being used by another process`）不是你的錯。**
code-review-graph 的監看 daemon 在 Windows 上持有目錄句柄，被監看樹裡的資料夾不能改名
或搬移。先 `code-review-graph daemon stop`，搬完再重新啟動 daemon。這也會擋掉
`git worktree remove` 與刪除資料夾。

**別用 `code-review-graph search` 的輸出判斷符號存不存在。** 它的 JSON 會回顯查詢字串
（`"query": "..."`），所以拿字串比對輸出時，一個根本不存在的符號也會「命中」。要判斷
就查資料庫的 `nodes` 表。
