#!/bin/sh
# graph-servers/install.sh - GitNexus + code-review-graph for Claude Code, macOS.
#
# The macOS sibling of graph-servers/install.ps1, written in POSIX sh with the jq that
# macOS ships (owner, 2026-10-15; ADR Memory/tasks/20261015-194453-os-detect/
# ADR-macos-sh-installer.md). Same steps, same end state; the reasons behind each step are
# written up at length in install.ps1 and are not repeated here. Called by the root
# install.sh; runnable on its own.
#
# Usage: sh graph-servers/install.sh [--repo PATH] [--pdg] [--check-only] [--self-test]
#   --repo        the repository for the per-repo steps (default: this clone)
#   --pdg         build the GitNexus PDG layers too (explain, pdg_query) - a slower index
#   --check-only  the prerequisite gate only; writes nothing
#   --self-test   offline tests of the file-editing functions in a sandbox; writes nothing
#
# Exit: 0 every step ok · 1 a prerequisite blocks, or a step FAILED · 2 not macOS / bad usage

unset CDPATH   # with CDPATH exported, `cd x && pwd` prints two lines (review agent-04, F9)

START_MARK='<!-- code-graph-servers:start -->'
END_MARK='<!-- code-graph-servers:end -->'
GN_START='<!-- gitnexus:start -->'
GN_END='<!-- gitnexus:end -->'

# The packages whose npm lifecycle scripts may run - the same literal list as
# install.ps1's $script:GitNexusAllowScripts. No space inside: npm would read the rest as
# a package name.
GITNEXUS_ALLOW_SCRIPTS='gitnexus,@ladybugdb/core,@scarf/scarf,onnxruntime-node,tree-sitter,tree-sitter-c-sharp,tree-sitter-cpp,tree-sitter-go,tree-sitter-java,tree-sitter-javascript,tree-sitter-php,tree-sitter-python,tree-sitter-ruby,tree-sitter-rust,tree-sitter-typescript,protobufjs'

# Minimums are what the packages declare: gitnexus "engines" node >= 22, code-review-graph
# Requires-Python >= 3.10.
NODE_MIN=22.0.0
PYTHON_MIN=3.10

say() { printf '%s\n' "$*"; }
stamp() { date '+%Y%m%d%H%M%S'; }

# ---------------------------------------------------------------- pure-ish helpers

version_ge() {
    have=$1; want=$2
    while [ -n "$want" ]; do
        h=${have%%.*}; w=${want%%.*}
        case $h in ''|*[!0-9]*) h=0 ;; esac
        case $w in ''|*[!0-9]*) w=0 ;; esac
        if [ "$h" -gt "$w" ]; then return 0; fi
        if [ "$h" -lt "$w" ]; then return 1; fi
        case $have in *.*) have=${have#*.} ;; *) have='' ;; esac
        case $want in *.*) want=${want#*.} ;; *) want='' ;; esac
    done
    return 0
}

# backup_name FILE SUFFIX -> FILE.SUFFIX-<stamp>, never an existing name (two backups in
# one second must not overwrite each other - that would delete the edit being preserved)
backup_name() {
    b="$1.$2-$(stamp)"; n=1
    while [ -e "$b" ]; do b="$1.$2-$(stamp)-$n"; n=$((n + 1)); done
    echo "$b"
}

# copy_master SOURCE TARGET -> one status line. Identical is a no-op; different keeps the
# old file as TARGET.local-<stamp> and says so, then installs the master.
copy_master() {
    [ -f "$1" ] || { say "master file not found: $1"; return 1; }
    name=$(basename "$2")
    if [ -e "$2" ]; then
        if [ "$(shasum -a 256 <"$1")" = "$(shasum -a 256 <"$2")" ]; then
            say "$name already current (identical to master)"; return 0
        fi
        b=$(backup_name "$2" local)
        cp -p "$2" "$b" || return 1
        say "   NOTE: $name differs from the master copy in this repo. Overwriting it."
        say "   The version that was there is kept at: $b"
        say "   If it was a real local fix, apply it to $1 and re-run."
        cp "$1" "$2" || return 1
        say "$name replaced a differing copy (previous version saved to $b)"
        return 0
    fi
    cp "$1" "$2" || return 1
    say "$name installed"
}

# ---------------------------------------------------------------- settings.json

# The jq program: add what is missing, leave every existing value alone, and replace a
# graph-refresh.ps1 SessionStart command (this Mac's hand port of 2026-10-14, or a
# Windows-shaped entry) with the sh one rather than adding a second refresher.
SETTINGS_JQ='
  .env = (.env // {})
  | .env.GITNEXUS_WAL_CHECKPOINT_THRESHOLD = (.env.GITNEXUS_WAL_CHECKPOINT_THRESHOLD // "67108864")
  | .env.MCP_TIMEOUT = (.env.MCP_TIMEOUT // "120000")
  | .env.MCP_CONNECT_TIMEOUT_MS = (.env.MCP_CONNECT_TIMEOUT_MS // "120000")
  | (if $crg != "" then .env.CRG_PYTHON = (.env.CRG_PYTHON // $crg) else . end)
  | .hooks = (.hooks // {})
  | .hooks.SessionStart = (.hooks.SessionStart // [])
  | if any(.hooks.SessionStart[]; tostring | test("graph-refresh\\.sh")) then .
    elif any(.hooks.SessionStart[]; tostring | test("graph-refresh\\.ps1")) then
      # The FIRST graph-refresh.ps1 hook becomes the sh one; any LATER .ps1 refresher hook is
      # a stale Windows-form entry and is removed - hook by hook, never a whole entry, so a
      # user hook sharing that entry, its matcher, and any existing sh refresher all stay
      # (review agent-04 F3, refined after agent-05 R2). An entry is dropped only when
      # removing those stale hooks left it empty.
      (reduce range(0; .hooks.SessionStart | length) as $i ({done: false, ss: .hooks.SessionStart};
         if (.ss[$i].hooks | type) != "array" then . else
           reduce range(0; .ss[$i].hooks | length) as $j (.;
             if ((.ss[$i].hooks[$j].command // "") | test("graph-refresh\\.ps1")) then
               (if .done then .ss[$i].hooks[$j] = {"__dw_drop": true}
                else .ss[$i].hooks[$j].command = $hook | .done = true end)
             else . end)
         end)) as $r
      | .hooks.SessionStart = [ $r.ss[]
          | if (type == "object") and ((.hooks | type) == "array")
               and any(.hooks[]; type == "object" and .__dw_drop == true) then
              (.hooks |= map(select((type == "object" and .__dw_drop == true) | not)))
              | (if (.hooks | length) == 0 then empty else . end)
            else . end ]
    else
      .hooks.SessionStart += [{hooks: [{type: "command", command: $hook, timeout: 10,
                                        statusMessage: "Queueing code-graph refresh..."}]}]
    end
'

# merge_settings FILE HOOK_COMMAND CRG_PYTHON -> prints notes; 0 ok, 1 refused or rolled back
merge_settings() {
    f=$1; hook=$2; crg=$3
    existed=0
    if [ -e "$f" ]; then
        existed=1
        /usr/bin/jq -e . "$f" >/dev/null 2>&1 || { say "settings.json is not valid JSON - refusing to touch it. Fix it first."; return 1; }
    else
        mkdir -p "$(dirname "$f")" || return 1
        printf '{}\n' >"$f"
        say "settings.json did not exist - creating it"
    fi
    tmpf="$f.dw-new.$$"
    /usr/bin/jq --arg hook "$hook" --arg crg "$crg" "$SETTINGS_JQ" "$f" >"$tmpf" 2>/dev/null || {
        rm -f "$tmpf"; [ $existed = 0 ] && rm -f "$f"; say "jq could not merge settings.json - nothing written"; return 1; }

    if [ $existed = 1 ] && [ "$(/usr/bin/jq -cS . "$f")" = "$(/usr/bin/jq -cS . "$tmpf")" ]; then
        rm -f "$tmpf"; say "settings.json: nothing to change"; return 0
    fi

    # notes - what changed and what was deliberately left alone
    for k in GITNEXUS_WAL_CHECKPOINT_THRESHOLD MCP_TIMEOUT MCP_CONNECT_TIMEOUT_MS CRG_PYTHON; do
        before=$(/usr/bin/jq -r --arg k "$k" '.env[$k] // empty' "$f")
        after=$(/usr/bin/jq -r --arg k "$k" '.env[$k] // empty' "$tmpf")
        if [ -z "$before" ] && [ -n "$after" ]; then say "added env.$k = $after"; fi
    done
    if /usr/bin/jq -e '[.hooks.SessionStart[]? | tostring | test("graph-refresh\\.ps1")] | any' "$f" >/dev/null 2>&1 \
        && ! /usr/bin/jq -e '[.hooks.SessionStart[]? | tostring | test("graph-refresh\\.sh")] | any' "$f" >/dev/null 2>&1; then
        say "replaced the graph-refresh.ps1 SessionStart command with the sh one"
    elif ! /usr/bin/jq -e '[.hooks.SessionStart[]? | tostring | test("graph-refresh\\.sh")] | any' "$f" >/dev/null 2>&1; then
        say "appended the graph-refresh entry to hooks.SessionStart"
    fi

    backup=''
    if [ $existed = 1 ]; then backup=$(backup_name "$f" bak); cp -p "$f" "$backup" || { rm -f "$tmpf"; return 1; }; fi
    # IN PLACE, not mv: mv would turn a symlinked settings.json (a dotfiles manager) into a
    # plain file and reset a 600 mode to 644 - and env can hold keys. install.ps1 writes in
    # place too.
    # A write that fails HALF WAY leaves a truncated file - restore the backup taken one
    # line up, which mv never needed (review agent-05, R1, the price of the F2 fix).
    if ! cat "$tmpf" >"$f"; then
        rm -f "$tmpf"
        if [ -n "$backup" ]; then cat "$backup" >"$f" && say "writing settings.json failed - restored from $backup"
        else rm -f "$f"; say 'writing settings.json failed - removed the file just created'; fi
        return 1
    fi
    rm -f "$tmpf"

    # the proof pass: it parses, SessionStart is an array, our keys are there, and NOTHING
    # outside env and hooks.SessionStart changed (other tools' hooks, plugins, ...)
    problems=''
    if ! /usr/bin/jq -e . "$f" >/dev/null 2>&1; then problems="$problems; result does not parse"; else
        /usr/bin/jq -e '.hooks.SessionStart | type == "array"' "$f" >/dev/null || problems="$problems; SessionStart is not an array"
        /usr/bin/jq -e '[.hooks.SessionStart[] | tostring | test("graph-refresh\\.sh")] | any' "$f" >/dev/null || problems="$problems; no graph-refresh.sh entry"
        /usr/bin/jq -e '.env.GITNEXUS_WAL_CHECKPOINT_THRESHOLD and .env.MCP_TIMEOUT and .env.MCP_CONNECT_TIMEOUT_MS' "$f" >/dev/null || problems="$problems; an env key is missing"
        if [ $existed = 1 ]; then
            rest='del(.env) | del(.hooks.SessionStart) | if .hooks == {} then del(.hooks) else . end'
            [ "$(/usr/bin/jq -cS "$rest" "$backup")" = "$(/usr/bin/jq -cS "$rest" "$f")" ] || problems="$problems; something outside env and hooks.SessionStart changed"
            [ "$(/usr/bin/jq -cS '(.env // {}) | to_entries | map(select(.key as $k | ["GITNEXUS_WAL_CHECKPOINT_THRESHOLD","MCP_TIMEOUT","MCP_CONNECT_TIMEOUT_MS","CRG_PYTHON"] | index($k) | not))' "$backup")" = \
              "$(/usr/bin/jq -cS '(.env // {}) | to_entries | map(select(.key as $k | ["GITNEXUS_WAL_CHECKPOINT_THRESHOLD","MCP_TIMEOUT","MCP_CONNECT_TIMEOUT_MS","CRG_PYTHON"] | index($k) | not))' "$f")" ] \
              || problems="$problems; another env key changed"
            # every SessionStart hook that is NOT a refresher must survive exactly - the
            # check that would have caught the over-eager dedupe (review agent-05, R2)
            others='[.hooks.SessionStart[]?.hooks[]?.command // empty | select(test("graph-refresh") | not)] | sort'
            [ "$(/usr/bin/jq -c "$others" "$backup")" = "$(/usr/bin/jq -c "$others" "$f")" ] \
              || problems="$problems; a SessionStart hook that is not ours changed"
        fi
    fi
    if [ -n "$problems" ]; then
        if [ -n "$backup" ]; then cat "$backup" >"$f"; undo='restored from backup'
        else rm -f "$f"; undo='removed the file just created'; fi
        say "settings.json patch failed, $undo. Problems:${problems#;}"
        return 1
    fi
    say "written: $f"
    [ -n "$backup" ] && say "backup:  $backup"
    say "verified: parses, SessionStart an array, nothing outside our keys changed"
    return 0
}

# ---------------------------------------------------------------- the agent doc

# snippet_body FILE -> everything after the first line that is exactly ---, with leading and
# trailing blank lines removed (install.ps1 does .Trim())
snippet_body() {
    awk 'found { print; next } /^---[[:space:]]*$/ { found = 1 }' "$1" \
        | awk 'NF { started = 1 } started { lines[++n] = $0 } END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }'
}

# agent_block SNIPPET -> the whole marked block, header byte-identical to install.ps1's
# (a project that is installed from both platforms must not see the block rewritten back
# and forth)
agent_block() {
    printf '%s\n' "$START_MARK"
    printf '%s\n' '<!-- Generated by graph-servers/install.ps1 from claude-md-snippet.md.'
    printf '%s\n' '     Edit the snippet in the dev-workstation repo, then re-run the installer. -->'
    snippet_body "$1"
    printf '%s\n' "$END_MARK"
}

# line_of FILE TEXT -> the first line number holding TEXT exactly as a line, or nothing
line_of() { grep -nxF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
count_of() { grep -cxF -- "$2" "$1" 2>/dev/null || true; }

# merge_agent_doc DOC SNIPPET -> prints the action; 0 ok, 1 refused or rolled back
merge_agent_doc() {
    doc=$1; snip=$2
    [ -f "$snip" ] || { say "snippet not found: $snip"; return 1; }
    grep -qx -- '---[[:space:]]*' "$snip" || grep -qx -- '---' "$snip" || { say "snippet has no '---' separator"; return 1; }
    t=$(mktemp -d "${TMPDIR:-/tmp}/agentdoc.XXXXXX") || return 1
    agent_block "$snip" >"$t/block"
    existed=0; [ -f "$doc" ] && existed=1
    if [ $existed = 1 ]; then cp "$doc" "$t/orig"; else : >"$t/orig"; fi

    s=$(line_of "$t/orig" "$START_MARK"); e=$(line_of "$t/orig" "$END_MARK")
    if [ -n "$s" ] && [ -z "$e" ]; then rm -rf "$t"; say "$(basename "$doc") has our start marker but no end marker - fix it by hand"; return 1; fi
    if [ -n "$s" ]; then
        gs=$(line_of "$t/orig" "$GN_START"); ge=$(line_of "$t/orig" "$GN_END")
        if [ -n "$gs" ] && [ -n "$ge" ] && [ "$ge" -gt "$gs" ]; then
            if { [ "$s" -gt "$gs" ] && [ "$s" -lt "$ge" ]; } || { [ "$e" -gt "$gs" ] && [ "$e" -lt "$ge" ]; } || { [ "$gs" -gt "$s" ] && [ "$ge" -lt "$e" ]; }; then
                rm -rf "$t"; say "our block overlaps the gitnexus markers in $(basename "$doc") - move it outside first, or the next 'gitnexus analyze' deletes it"; return 1
            fi
        fi
        awk -v n="$s" 'NR < n' "$t/orig" >"$t/prefix"
        tail -n +$((e + 1)) "$t/orig" >"$t/suffix"
        cat "$t/prefix" "$t/block" "$t/suffix" >"$t/new"
        action='updated in place'
    else
        # trim trailing blank lines of the original, one blank line, the block
        awk '{ lines[++n] = $0 } END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }' "$t/orig" >"$t/prefix"
        : >"$t/suffix"
        if [ -s "$t/prefix" ]; then { cat "$t/prefix"; printf '\n'; cat "$t/block"; } >"$t/new"; else cp "$t/block" "$t/new"; fi
        if [ $existed = 1 ]; then action=appended; else action="created $(basename "$doc")"; fi
    fi

    if [ $existed = 1 ] && cmp -s "$t/new" "$t/orig"; then rm -rf "$t"; say 'already current'; return 0; fi

    backup=''
    if [ $existed = 1 ]; then backup=$(backup_name "$doc" bak); cp -p "$doc" "$backup" || { rm -rf "$t"; return 1; }; fi
    cp "$t/new" "$doc" || { rm -rf "$t"; return 1; }

    problems=''
    [ "$(count_of "$doc" "$START_MARK")" = 1 ] || problems="$problems; start marker not present exactly once"
    [ "$(count_of "$doc" "$END_MARK")" = 1 ] || problems="$problems; end marker not present exactly once"
    grep -qF 'get_impact_radius_tool' "$doc" || problems="$problems; rule body missing after write"
    if [ $existed = 1 ] && [ -z "$problems" ]; then
        s2=$(line_of "$doc" "$START_MARK"); e2=$(line_of "$doc" "$END_MARK")
        { awk -v n="$s2" 'NR < n' "$doc"; tail -n +$((e2 + 1)) "$doc"; } | awk 'NF' >"$t/out-after"
        { cat "$t/prefix" "$t/suffix"; } | awk 'NF' >"$t/out-before"
        cmp -s "$t/out-after" "$t/out-before" || problems="$problems; content outside our markers changed"
    fi
    if [ -n "$problems" ]; then
        if [ -n "$backup" ]; then cp -p "$backup" "$doc"; undo='restored from backup'
        else rm -f "$doc"; undo='removed the file just created'; fi
        rm -rf "$t"
        say "$(basename "$doc") patch failed, $undo. Problems:${problems#;}"
        return 1
    fi
    rm -rf "$t"
    say "$action"
    [ -n "$backup" ] && say "backup:  $backup"
    return 0
}

# confirm_doc_ignored REPO DOCNAME -> a personal doc (and its .bak- backups) must be
# git-ignored, else it gets committed - ask git, never parse .gitignore
confirm_doc_ignored() {
    command -v git >/dev/null 2>&1 || { say "git not found - cannot check that $2 is ignored"; return 0; }
    git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { say "not a git repo - cannot check that $2 is ignored"; return 0; }
    if git -C "$1" check-ignore -q -- "$2" && git -C "$1" check-ignore -q -- "$2.bak-00000000000000"; then
        say "$2 and its backups already git-ignored"; return 0
    fi
    gi=$1/.gitignore
    if [ -s "$gi" ] && [ "$(tail -c 1 "$gi" | od -An -c | tr -d ' ')" != '\n' ]; then printf '\n' >>"$gi"; fi
    printf '\n# personal harness config, written by graph-servers/install.sh\n%s*\n' "$2" >>"$gi"
    if git -C "$1" check-ignore -q -- "$2"; then say "added $2* to .gitignore (the trailing * also covers its .bak-* backups)"
    else say "WARNING: added $2* to .gitignore but git still does not ignore $2 - check for a negating rule"; fi
}

# ---------------------------------------------------------------- steps

results=''
failed=0
step() {
    # step NAME FUNCTION - runs it, records ok / FAILED, never stops the run
    say ''
    say "== $1"
    out=$("$2" 2>&1); rc=$?
    printf '%s\n' "$out" | sed 's/^/   /'
    if [ $rc = 0 ]; then results="$results
$(printf '%-48s %s' "$1" "$(printf '%s\n' "$out" | tail -n 1)")"
    else failed=1; results="$results
$(printf '%-48s FAILED: %s' "$1" "$(printf '%s\n' "$out" | tail -n 1)")"; fi
}

tool_version() {
    command -v "$1" >/dev/null 2>&1 || return 1
    "$1" --version 2>/dev/null | head -n 1 | sed -n 's/[^0-9]*\([0-9][0-9.]*\).*/\1/p'
}

python_for_gate() {
    # the user's python, never the Command Line Tools' /usr/bin/python3 (see root install.sh)
    for c in $(which -a python3 python 2>/dev/null); do
        case $c in /usr/bin/*) ;; *) echo "$c"; return 0 ;; esac
    done
    return 1
}

prereq_gate() {
    blocked=0
    row() { printf '   %-8s %-10s min %-8s %s\n' "$1" "$2" "$3" "$4"; [ "$4" = OK ] || blocked=1; }
    v=$(tool_version node); if [ -z "$v" ]; then row node - "$NODE_MIN" MISSING; elif version_ge "$v" "$NODE_MIN"; then row node "$v" "$NODE_MIN" OK; else row node "$v" "$NODE_MIN" 'TOO OLD'; fi
    v=$(tool_version npm); if [ -z "$v" ]; then row npm - any MISSING; else row npm "$v" any OK; fi
    p=$(python_for_gate); v=''; [ -n "$p" ] && v=$("$p" --version 2>&1 | sed -n 's/^Python \([0-9.]*\).*/\1/p')
    if [ -z "$v" ]; then row python - "$PYTHON_MIN" MISSING; elif version_ge "$v" "$PYTHON_MIN"; then row python "$v" "$PYTHON_MIN" OK; else row python "$v" "$PYTHON_MIN" 'TOO OLD'; fi
    v=$(tool_version uv); if [ -z "$v" ]; then row uv - any MISSING; else row uv "$v" any OK; fi
    v=$(tool_version git); if [ -z "$v" ]; then row git - any MISSING; else row git "$v" any OK; fi
    v=$(tool_version claude); if [ -z "$v" ]; then row claude - any MISSING; else row claude "$v" any OK; fi
    if [ $blocked = 1 ]; then
        say 'a prerequisite is missing or too old - the root install.sh installs them'
        return 1
    fi
    say 'ok'
}

crg_python() {
    # nothing (and failure) when uv cannot say where its tools live - never a bare
    # "/code-review-graph/bin/python", which settings.json would then keep for ever (F5)
    d=$(uv tool dir 2>/dev/null) && [ -n "$d" ] || return 1
    echo "$d/code-review-graph/bin/python"
}

# db_counts DB -> "<nodes> <embeddings>", 0 0 when unreadable
db_counts() {
    [ -f "$1" ] || { echo '0 0'; return; }
    py=$(crg_python) || { echo '0 0'; return; }
    "$py" -c 'import sqlite3,sys
try:
    c=sqlite3.connect(sys.argv[1]); print(c.execute("select count(*) from nodes").fetchone()[0], c.execute("select count(*) from embeddings").fetchone()[0])
except Exception:
    print("0 0")' "$1" 2>/dev/null | tail -n 1
}

indexed_commit() {
    [ -f "$1/.gitnexus/meta.json" ] || return 0
    sed -n 's/.*"lastCommit"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{7,40\}\)".*/\1/p' "$1/.gitnexus/meta.json" | head -n 1
}

s_gitnexus_install() {
    if v=$(gitnexus --version 2>/dev/null); then
        say 'already installed - not reinstalling'
        say 'to upgrade on purpose: npm install -g gitnexus@latest'
        say "gitnexus $v already installed"; return 0
    fi
    npm install -g gitnexus "--allow-scripts=$GITNEXUS_ALLOW_SCRIPTS" 2>&1 | tail -n 3
    v=$(gitnexus --version 2>/dev/null) || { say 'gitnexus is not runnable after npm install'; return 1; }
    say "gitnexus $v installed"
}

s_gitnexus_setup() {
    out=$(gitnexus setup -c claude 2>&1); rc=$?
    printf '%s\n' "$out" | tail -n 6
    [ $rc = 0 ] || { say "gitnexus setup exited $rc"; return 1; }
    say ok
}

s_crg_install() {
    if uv tool list 2>/dev/null | grep -q '^code-review-graph '; then
        say 'already installed - not reinstalling'
        say 'to upgrade on purpose: uv tool upgrade code-review-graph'
        say "$(uv tool list 2>/dev/null | grep '^code-review-graph ') already installed"; return 0
    fi
    uv tool install --python 3.13 'code-review-graph[embeddings,communities]' 2>&1 | tail -n 4
    uv tool list 2>/dev/null | grep -q '^code-review-graph ' || { say 'not installed'; return 1; }
    say "$(uv tool list | grep '^code-review-graph ') installed"
}

s_crg_import() {
    py=$(crg_python) || { say "uv cannot say where its tools live"; return 1; }
    probe=$("$py" -c "import code_review_graph, sentence_transformers; print('import ok')" 2>&1)
    say "$probe" | tail -n 1
    case $probe in *'import ok'*) say ok ;; *) say "cannot import from $py"; return 1 ;; esac
}

s_crg_mcp() {
    if claude mcp get code-review-graph 2>&1 | grep -q 'Scope:'; then
        say 'already registered, leaving it alone'; say 'already present'; return 0
    fi
    py=$(crg_python) || { say "uv cannot say where its tools live"; return 1; }
    claude mcp add -s user code-review-graph -- "$py" -m code_review_graph serve 2>&1 || return 1
    say registered
}

s_hook_script() {
    mkdir -p "$HOME/.claude/hooks" || return 1
    copy_master "$here/graph-refresh.sh" "$HOME/.claude/hooks/graph-refresh.sh" || return 1
    chmod +x "$HOME/.claude/hooks/graph-refresh.sh"
}

s_post_commit() {
    # The repository's OWN hooks directory, never core.hooksPath: that can be a folder other
    # repositories share (global, husky), and overwriting its post-commit would change them
    # all (review agent-04, F12). install.ps1 writes to .git\hooks too.
    # The COMMON dir, not --absolute-git-dir: in a linked worktree that is
    # .git/worktrees/<name>, where git never looks for hooks (review agent-05, R3).
    gd=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { say "not a git repository: $repo"; return 1; }
    hd=$gd/hooks
    hp=$(git -C "$repo" config --get core.hooksPath)
    if [ -n "$hp" ]; then
        say "WARNING: core.hooksPath is set ($hp), so git runs hooks from THERE, not from $hd."
        say "The hook is installed in $hd only; that shared folder is left alone. To refresh"
        say "GitNexus after commits, call ~/.claude/hooks/graph-refresh.sh from that folder's post-commit."
    fi
    mkdir -p "$hd" || return 1
    target=$hd/post-commit
    if [ -f "$target" ] && ! grep -q 'graph-refresh\.' "$target"; then
        say 'the existing post-commit is NOT ours - it does something else'
    fi
    copy_master "$here/post-commit.sh" "$target" || return 1
    chmod +x "$target"
    # the summary shows the LAST line - with core.hooksPath set it must say the hook is
    # not the one git runs, not merely "installed" (review agent-05, R4)
    [ -z "$hp" ] || say "installed in $hd but NOT ACTIVE - git runs core.hooksPath ($hp)"
}

s_gitnexus_index() {
    command -v gitnexus >/dev/null 2>&1 || { say 'gitnexus is not installed - cannot index'; return 1; }
    indexed=$(indexed_commit "$repo")
    head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
    if [ "$pdg" = 0 ] && [ -n "$indexed" ] && [ "$indexed" = "$head" ]; then
        say "index is already at $(printf '%s' "$head" | cut -c1-8) - nothing to do"; say 'already at HEAD'; return 0
    fi
    [ "$pdg" = 1 ] && say '--pdg: re-indexing, because nothing on disk proves the PDG layers exist'
    set -- analyze --skip-agents-md
    [ "$pdg" = 1 ] && set -- "$@" --pdg
    out=$(cd "$repo" && GITNEXUS_WAL_CHECKPOINT_THRESHOLD=67108864 gitnexus "$@" 2>&1); rc=$?
    printf '%s\n' "$out" | tail -n 6
    # gitnexus exits 0 even when the analysis aborted - read the text, the exit code, AND
    # what is on disk afterwards (review agent-04, F10)
    case $out in *'Analysis failed'*) say 'analyze reported failure'; return 1 ;; esac
    [ $rc = 0 ] || { say "analyze exited $rc"; return 1; }
    [ "$(indexed_commit "$repo")" = "$head" ] || { say "analyze finished but the index is not at HEAD ($(printf '%s' "$head" | cut -c1-8))"; return 1; }
    say "ok - indexed at $(printf '%s' "$head" | cut -c1-8)"
}

s_crg_build() {
    py=$(crg_python) || { say 'uv cannot say where its tools live'; return 1; }
    db=$repo/.code-review-graph/graph.db
    counts=$(db_counts "$db")
    nodes=${counts% *}; embeds=${counts#* }
    if [ "${nodes:-0}" -gt 0 ] 2>/dev/null && [ "${embeds:-0}" -gt 0 ] 2>/dev/null; then
        say "already built: $nodes nodes, $embeds embeddings"
        say '(that it was BUILT, not that it is current - the daemon never embeds new code)'
        say "already built ($nodes nodes, $embeds embeddings)"; return 0
    fi
    blog=$(mktemp "${TMPDIR:-/tmp}/crg-build.XXXXXX") || return 1
    "$py" -m code_review_graph build --repo "$repo" >"$blog" 2>&1; brc=$?
    tail -n 4 "$blog"
    "$py" -m code_review_graph embed --repo "$repo" >"$blog" 2>&1; erc=$?
    tail -n 4 "$blog"; rm -f "$blog"
    # the exit codes AND the database decide, not the commands having been run (F11)
    counts=$(db_counts "$db"); nodes=${counts% *}; embeds=${counts#* }
    [ $brc = 0 ] && [ "${nodes:-0}" -gt 0 ] 2>/dev/null || { say "build failed (exit $brc, $nodes nodes)"; return 1; }
    [ $erc = 0 ] && [ "${embeds:-0}" -gt 0 ] 2>/dev/null || { say "built $nodes nodes, but embed failed (exit $erc, $embeds embeddings) - semantic search will not work; re-run: $py -m code_review_graph embed --repo $repo"; return 1; }
    say "built ($nodes nodes, $embeds embeddings)"
}

s_daemon() {
    py=$(crg_python) || { say "uv cannot say where its tools live"; return 1; }
    "$py" -m code_review_graph daemon add "$repo" 2>&1 | tail -n 3
    CRG_PYTHON=$py sh "$HOME/.claude/hooks/graph-refresh.sh" --which crg --repo "$repo" --detach
    sleep 6
    pf=$HOME/.code-review-graph/daemon.pid
    [ -f "$pf" ] || { say 'daemon did not write a pid file'; return 1; }
    dp=$(tr -d ' \n\r' <"$pf")
    if kill -0 "$dp" 2>/dev/null; then say "daemon pid $dp alive"; else say "daemon pid $dp NOT alive"; return 1; fi
}

s_settings() {
    merge_settings "$HOME/.claude/settings.json" \
        "/bin/sh \"$HOME/.claude/hooks/graph-refresh.sh\" --which both --detach" "$(crg_python)"
}

s_agent_doc() {
    confirm_doc_ignored "$repo" CLAUDE.local.md
    if [ -f "$repo/CLAUDE.md" ] && grep -qxF "$START_MARK" "$repo/CLAUDE.md"; then
        say 'WARNING: CLAUDE.md still holds an older copy of this block - it is the shared file;'
        say 'delete that block by hand (markers included).'
    fi
    merge_agent_doc "$repo/CLAUDE.local.md" "$here/claude-md-snippet.md"
}

# ---------------------------------------------------------------- self-test

self_test() {
    pass=0; fail=0
    t() { if [ "$2" = 0 ]; then pass=$((pass + 1)); say "  PASS  $1"; else fail=$((fail + 1)); say "  FAIL  $1"; fi; }
    sb=$(mktemp -d "${TMPDIR:-/tmp}/gs-selftest.XXXXXX") || return 1
    say 'graph-servers/install.sh self-test'
    H='/bin/sh "/h/.claude/hooks/graph-refresh.sh" --which both --detach'

    # settings: fresh file
    merge_settings "$sb/new/settings.json" "$H" /crg/python >/dev/null
    t 'settings: a missing file is created' "$([ -f "$sb/new/settings.json" ]; echo $?)"
    t 'settings: env keys added' "$(/usr/bin/jq -e '.env.MCP_TIMEOUT == "120000" and .env.CRG_PYTHON == "/crg/python"' "$sb/new/settings.json" >/dev/null; echo $?)"
    t 'settings: one SessionStart entry with the sh hook' "$(/usr/bin/jq -e '[.hooks.SessionStart[] | tostring | select(test("graph-refresh\\.sh"))] | length == 1' "$sb/new/settings.json" >/dev/null; echo $?)"
    merge_settings "$sb/new/settings.json" "$H" /crg/python >"$sb/out2"
    t 'settings: a re-run changes nothing' "$(grep -q 'nothing to change' "$sb/out2"; echo $?)"
    t 'settings: a re-run takes no backup' "$(ls "$sb/new" | grep -c bak | grep -qx 0; echo $?)"

    # settings: existing values and other tools' hooks survive; the pwsh entry is migrated
    cat >"$sb/s.json" <<'EOF'
{
  "model": "opus",
  "env": { "MCP_TIMEOUT": "999", "OTHER": "x", "CRG_PYTHON": "/mine/python" },
  "hooks": {
    "PreToolUse": [ { "matcher": "Grep", "hooks": [ { "type": "command", "command": "gitnexus hook" } ] } ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "other-tool start" } ] },
      { "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File \"/Users/x/.claude/hooks/graph-refresh.ps1\" -Which both -Detach", "timeout": 10 } ] }
    ]
  },
  "enabledPlugins": { "a@b": true },
  "statusLine": { "type": "command", "command": "s 中文" }
}
EOF
    merge_settings "$sb/s.json" "$H" /crg/python >"$sb/out3"
    t 'settings: an existing env value is left alone' "$(/usr/bin/jq -e '.env.MCP_TIMEOUT == "999" and .env.CRG_PYTHON == "/mine/python"' "$sb/s.json" >/dev/null; echo $?)"
    t 'settings: the pwsh refresher became the sh one' "$(/usr/bin/jq -e '[.hooks.SessionStart[] | tostring | select(test("graph-refresh\\.ps1"))] | length == 0' "$sb/s.json" >/dev/null; echo $?)"
    t 'settings: still exactly one refresher, no second one added' "$(/usr/bin/jq -e '[.hooks.SessionStart[] | tostring | select(test("graph-refresh"))] | length == 1' "$sb/s.json" >/dev/null; echo $?)"
    t 'settings: the migrated entry keeps its timeout' "$(/usr/bin/jq -e '.hooks.SessionStart[1].hooks[0].timeout == 10' "$sb/s.json" >/dev/null; echo $?)"
    t 'settings: other SessionStart entries survive' "$(/usr/bin/jq -e '.hooks.SessionStart[0].hooks[0].command == "other-tool start"' "$sb/s.json" >/dev/null; echo $?)"
    t 'settings: other tools'"'"' hooks, plugins, CJK survive' "$(/usr/bin/jq -e '.hooks.PreToolUse[0].matcher == "Grep" and .enabledPlugins["a@b"] and .statusLine.command == "s 中文" and .model == "opus" and .env.OTHER == "x"' "$sb/s.json" >/dev/null; echo $?)"
    t 'settings: a backup was taken' "$(ls "$sb" | grep -q '^s.json.bak-'; echo $?)"
    t 'settings: the migration is reported' "$(grep -q 'replaced the graph-refresh.ps1' "$sb/out3"; echo $?)"

    # settings: a file with NO env key - the usual fresh Mac (review agent-04, F1)
    printf '{ "model": "x", "hooks": { "PreToolUse": [] } }\n' >"$sb/noenv.json"
    merge_settings "$sb/noenv.json" "$H" '' >"$sb/out5"; rc=$?
    t 'settings: a file without env is merged, not rolled back' "$([ $rc = 0 ] && /usr/bin/jq -e '.env.MCP_TIMEOUT and .model == "x"' "$sb/noenv.json" >/dev/null; echo $?)"

    # settings: a symlinked file stays a symlink, and a 600 mode stays 600 (F2)
    printf '{}\n' >"$sb/real.json"; chmod 600 "$sb/real.json"; ln -s "$sb/real.json" "$sb/link.json"
    merge_settings "$sb/link.json" "$H" '' >/dev/null
    t 'settings: a symlinked settings.json is still a symlink' "$([ -L "$sb/link.json" ] && /usr/bin/jq -e '.env.MCP_TIMEOUT' "$sb/real.json" >/dev/null; echo $?)"
    t 'settings: a 600 file stays 600' "$([ "$(stat -f '%Lp' "$sb/real.json")" = 600 ]; echo $?)"

    # settings: a write that fails half way is rolled back, never left truncated (R1)
    printf '{ "keep": "me", "env": { "A": "1" } }\n' >"$sb/w.json"; cp "$sb/w.json" "$sb/w.orig"
    rc=$(n=0; cat() { n=$((n + 1)); if [ $n = 1 ]; then head -c 20 "$1"; return 1; fi; command cat "$@"; }
         merge_settings "$sb/w.json" "$H" '' >/dev/null 2>&1; echo $?)
    t 'settings: a write failing half way restores the original byte for byte' "$([ "$rc" = 1 ] && cmp -s "$sb/w.json" "$sb/w.orig"; echo $?)"

    # settings: two old refresher entries become ONE sh refresher (F3)
    cat >"$sb/two.json" <<'EOF'
{ "hooks": { "SessionStart": [
  { "hooks": [ { "type": "command", "command": "pwsh -File /a/graph-refresh.ps1 -Which both" } ] },
  { "hooks": [ { "type": "command", "command": "other" } ] },
  { "hooks": [ { "type": "command", "command": "powershell -File C:/b/graph-refresh.ps1 -Which crg" } ] }
] } }
EOF
    merge_settings "$sb/two.json" "$H" '' >/dev/null
    t 'settings: two old refreshers become exactly one sh refresher' "$(/usr/bin/jq -e '[.hooks.SessionStart[] | tostring | select(test("graph-refresh"))] | length == 1' "$sb/two.json" >/dev/null; echo $?)"
    t 'settings: ...and the unrelated entry between them survives' "$(/usr/bin/jq -e 'any(.hooks.SessionStart[]; .hooks[0].command == "other")' "$sb/two.json" >/dev/null; echo $?)"

    # settings: a user hook sharing the old refresher's entry survives, matcher kept (R2)
    cat >"$sb/share.json" <<'EOF'
{ "hooks": { "SessionStart": [
  { "matcher": "startup", "hooks": [
      { "type": "command", "command": "pwsh -File /a/graph-refresh.ps1 -Which both" },
      { "type": "command", "command": "my-own-hook" } ] },
  { "hooks": [ { "type": "command", "command": "pwsh -File /b/graph-refresh.ps1 -Which crg" },
               { "type": "command", "command": "second-own-hook" } ] }
] } }
EOF
    merge_settings "$sb/share.json" "$H" '' >/dev/null; rc=$?
    t 'settings: user hooks sharing a refresher entry survive the migration' \
        "$([ $rc = 0 ] && /usr/bin/jq -e '[.hooks.SessionStart[].hooks[].command] | index("my-own-hook") and index("second-own-hook")' "$sb/share.json" >/dev/null; echo $?)"
    t 'settings: ...the matcher survives, and one refresher is left' \
        "$(/usr/bin/jq -e '.hooks.SessionStart[0].matcher == "startup" and ([.hooks.SessionStart[].hooks[].command | select(test("graph-refresh"))] | length == 1)' "$sb/share.json" >/dev/null; echo $?)"
    cat >"$sb/keep.json" <<'EOF'
{ "hooks": { "SessionStart": [
  { "matcher": "startup", "hooks": [ { "type": "command", "command": "/bin/sh /x/graph-refresh.sh --which both --detach" } ] },
  { "matcher": "resume", "hooks": [ { "type": "command", "command": "/bin/sh /x/graph-refresh.sh --which crg --detach" } ] }
] } }
EOF
    cp "$sb/keep.json" "$sb/keep.orig"
    merge_settings "$sb/keep.json" "$H" '' >/dev/null
    t 'settings: sh refreshers the user already has are left exactly as they are' \
        "$([ "$(/usr/bin/jq -c '.hooks' "$sb/keep.json")" = "$(/usr/bin/jq -c '.hooks' "$sb/keep.orig")" ]; echo $?)"

    # settings: invalid JSON is refused and untouched
    printf '{ broken\n' >"$sb/bad.json"; cp "$sb/bad.json" "$sb/bad.orig"
    merge_settings "$sb/bad.json" "$H" '' >"$sb/out4"; rc=$?
    t 'settings: invalid JSON is refused' "$([ $rc = 1 ]; echo $?)"
    t 'settings: ...by the up-front check, not by jq failing later' "$(grep -q 'not valid JSON' "$sb/out4"; echo $?)"
    t 'settings: invalid JSON is left byte-identical' "$(cmp -s "$sb/bad.json" "$sb/bad.orig"; echo $?)"

    # agent doc
    printf 'intro\n\n---\n\nrule text get_impact_radius_tool\nline two\n\n' >"$sb/snip.md"
    printf '# Project\n\nmine\n' >"$sb/doc.md"
    merge_agent_doc "$sb/doc.md" "$sb/snip.md" >/dev/null
    t 'doc: block appended once' "$([ "$(count_of "$sb/doc.md" "$START_MARK")" = 1 ]; echo $?)"
    t 'doc: own content kept' "$(head -n 3 "$sb/doc.md" | grep -qx mine; echo $?)"
    t 'doc: header is the Windows header, byte for byte' "$(grep -qxF '<!-- Generated by graph-servers/install.ps1 from claude-md-snippet.md.' "$sb/doc.md"; echo $?)"
    t 'doc: snippet header before --- is not copied' "$(grep -qx intro "$sb/doc.md"; [ $? = 1 ]; echo $?)"
    cp "$sb/doc.md" "$sb/doc.v1"
    t 'doc: a re-run is already current' "$(merge_agent_doc "$sb/doc.md" "$sb/snip.md" | grep -q 'already current'; echo $?)"
    printf 'intro\n---\nrule text get_impact_radius_tool\nNEW LINE\n' >"$sb/snip.md"
    printf 'after\n' >>"$sb/doc.md"
    merge_agent_doc "$sb/doc.md" "$sb/snip.md" >/dev/null
    t 'doc: an edited snippet updates in place' "$(grep -qx 'NEW LINE' "$sb/doc.md" && [ "$(count_of "$sb/doc.md" "$START_MARK")" = 1 ]; echo $?)"
    t 'doc: text after the block survives an update' "$(tail -n 1 "$sb/doc.md" | grep -qx after; echo $?)"
    # a block that starts on line 1 (as in a CLAUDE.local.md the installer created) - BSD
    # head refuses `-n 0`, which once printed an error here and only worked by luck
    agent_block "$sb/snip.md" >"$sb/top.md"; printf 'tail line\n' >>"$sb/top.md"
    printf 'intro\n---\nrule text get_impact_radius_tool\nTOP EDIT\n' >"$sb/snip2.md"
    err=$(merge_agent_doc "$sb/top.md" "$sb/snip2.md" 2>&1 >/dev/null)
    t 'doc: a block on line 1 updates with no error output' "$([ -z "$err" ] && grep -qx 'TOP EDIT' "$sb/top.md" && [ "$(head -n 1 "$sb/top.md")" = "$START_MARK" ]; echo $?)"
    printf '%s\nx\n' "$START_MARK" >"$sb/half.md"
    merge_agent_doc "$sb/half.md" "$sb/snip.md" >/dev/null; rc=$?
    t 'doc: start marker without end is refused' "$([ $rc = 1 ]; echo $?)"
    t 'doc: ...before anything is written (no backup taken)' "$(ls "$sb" | grep -q '^half.md.bak-'; [ $? = 1 ]; echo $?)"
    printf '%s\n%s\nold\n%s\n%s\n' "$GN_START" "$START_MARK" "$END_MARK" "$GN_END" >"$sb/gn.md"
    merge_agent_doc "$sb/gn.md" "$sb/snip.md" >/dev/null; rc=$?
    t 'doc: a block inside the gitnexus region is refused' "$([ $rc = 1 ]; echo $?)"
    printf '%s\nold\n%s\nkeep me\n%s\n%s\n' "$START_MARK" "$GN_START" "$GN_END" "$END_MARK" >"$sb/around.md"
    cp "$sb/around.md" "$sb/around.orig"
    merge_agent_doc "$sb/around.md" "$sb/snip.md" >/dev/null; rc=$?
    t 'doc: a block that SURROUNDS the gitnexus region is refused, gitnexus kept (F7)' "$([ $rc = 1 ] && cmp -s "$sb/around.md" "$sb/around.orig"; echo $?)"
    printf 'no separator\n' >"$sb/nosep.md"
    merge_agent_doc "$sb/doc2.md" "$sb/nosep.md" >/dev/null; rc=$?
    t 'doc: a snippet with no --- is refused' "$([ $rc = 1 ] && [ ! -e "$sb/doc2.md" ]; echo $?)"

    # copy_master
    printf 'A\n' >"$sb/master"; printf 'A\n' >"$sb/target"
    t 'master: identical is a no-op' "$(copy_master "$sb/master" "$sb/target" | grep -q 'already current'; echo $?)"
    printf 'B\n' >"$sb/target"
    copy_master "$sb/master" "$sb/target" >/dev/null
    t 'master: a different file is replaced' "$(grep -qx A "$sb/target"; echo $?)"
    t 'master: ...and kept as .local-<stamp>' "$(cat "$sb"/target.local-* | grep -qx B; echo $?)"

    # post-commit goes to the repository's own hooks, never to a shared core.hooksPath (F12)
    git init -q "$sb/r" && mkdir -p "$sb/shared-hooks" && printf '#!/bin/sh\necho shared\n' >"$sb/shared-hooks/post-commit"
    git -C "$sb/r" config core.hooksPath "$sb/shared-hooks"
    printf '#!/bin/sh\n# graph-refresh.sh master\n' >"$sb/post-commit.sh"
    out=$(here=$sb repo=$sb/r s_post_commit 2>&1)
    t 'post-commit: a shared core.hooksPath folder is left alone' "$(grep -qx 'echo shared' "$sb/shared-hooks/post-commit" && [ "$(ls "$sb/shared-hooks")" = post-commit ]; echo $?)"
    t 'post-commit: ...the hook goes into the repo'"'"'s own .git/hooks' "$(cmp -s "$sb/post-commit.sh" "$sb/r/.git/hooks/post-commit"; echo $?)"
    t 'post-commit: ...and it warns that git runs the shared folder' "$(printf '%s\n' "$out" | grep -q 'core.hooksPath is set'; echo $?)"
    t 'post-commit: ...and its LAST line (the summary row) says NOT ACTIVE' "$(printf '%s\n' "$out" | tail -n 1 | grep -q 'NOT ACTIVE'; echo $?)"
    git -C "$sb/r" config --unset core.hooksPath
    git -C "$sb/r" -c user.email=t@t -c user.name=t commit -q --allow-empty -F "$sb/post-commit.sh"
    git -C "$sb/r" worktree add -q "$sb/wt" 2>/dev/null
    rm -f "$sb/r/.git/hooks/post-commit"
    out=$(here=$sb repo=$sb/wt s_post_commit 2>&1)
    t 'post-commit: from a linked worktree it goes to the COMMON hooks dir, where git runs it' \
        "$([ -f "$sb/r/.git/hooks/post-commit" ] && [ ! -e "$sb/r/.git/worktrees/wt/hooks/post-commit" ]; echo $?)"

    # the GitNexus index step must not say ok unless the index really is at HEAD (F10)
    printf 'x\n' >"$sb/r/f"; git -C "$sb/r" add f; git -C "$sb/r" -c user.email=t@t -c user.name=t -c advice.ignoredHook=false commit -q -F "$sb/r/f"
    mkdir -p "$sb/bin"
    out=$(PATH=/usr/bin:/bin repo=$sb/r pdg=0 s_gitnexus_index 2>&1); rc=$?
    t 'index: gitnexus not installed is a failure, not ok' "$([ $rc = 1 ] && printf '%s\n' "$out" | grep -q 'not installed'; echo $?)"
    printf '#!/bin/sh\necho done\nexit 0\n' >"$sb/bin/gitnexus"; chmod +x "$sb/bin/gitnexus"
    out=$(PATH=$sb/bin:/usr/bin:/bin repo=$sb/r pdg=0 s_gitnexus_index 2>&1); rc=$?
    t 'index: exit 0 with no index written is a failure, not ok' "$([ $rc = 1 ] && printf '%s\n' "$out" | grep -q 'not at HEAD'; echo $?)"

    t 'version: node 22.0.0 meets 22.0.0' "$(version_ge 22.0.0 "$NODE_MIN"; echo $?)"
    t 'version: python 3.9.6 is below 3.10' "$(! version_ge 3.9.6 "$PYTHON_MIN"; echo $?)"

    rm -rf "$sb"
    say ''
    say "  $pass PASS  $fail FAIL"
    [ "$fail" = 0 ]
}

# ---------------------------------------------------------------- main

main() {
    here=$(cd "$(dirname "$0")" && pwd)
    repo=$(cd "$here/.." && pwd)
    pdg=0; mode=install
    while [ $# -gt 0 ]; do
        case $1 in
            --repo) repo=${2:-}; shift ;;
            --pdg) pdg=1 ;;
            --check-only) mode=check ;;
            --self-test) mode=selftest ;;
            *) say "graph-servers/install.sh: unknown argument: $1"; exit 2 ;;
        esac
        shift
    done
    if [ "$mode" = selftest ]; then self_test; exit $?; fi

    if [ "$(uname -s)" != Darwin ]; then
        say 'graph-servers/install.sh is the macOS installer; on Windows run graph-servers/install.ps1.'
        exit 2
    fi
    [ -x /usr/bin/jq ] || { say '/usr/bin/jq is missing - see the root install.sh'; exit 2; }
    [ -d "$repo" ] || { say "--repo path does not exist: $repo"; exit 2; }
    repo=$(cd "$repo" && pwd)

    say ''
    say '== Prerequisites'
    if ! prereq_gate; then
        say ''
        say 'Stopped before installing anything - fix the items above and run this again.'
        exit 1
    fi
    if [ "$mode" = check ]; then say ''; say 'check-only: stopping before any install.'; exit 0; fi

    step 'GitNexus: npm global install' s_gitnexus_install
    step 'GitNexus: register MCP + skills + hooks' s_gitnexus_setup
    step 'code-review-graph: uv tool install with extras' s_crg_install
    step 'code-review-graph: import check' s_crg_import
    step 'code-review-graph: register MCP (user scope)' s_crg_mcp
    step 'Install graph-refresh.sh into ~/.claude/hooks' s_hook_script
    step "Repo: install post-commit hook" s_post_commit
    step 'Repo: GitNexus index' s_gitnexus_index
    step 'Repo: code-review-graph build + embeddings' s_crg_build
    step 'Repo: register + start the watch daemon' s_daemon
    step 'Patch ~/.claude/settings.json' s_settings
    step 'Write the usage rule into CLAUDE.local.md' s_agent_doc

    say ''
    say '===== summary ====='
    printf '%s\n' "$results" | sed '/^$/d'
    say ''
    say 'Restart Claude Code - env and hook changes only apply to a NEW session.'
    exit $failed
}

main "$@"
