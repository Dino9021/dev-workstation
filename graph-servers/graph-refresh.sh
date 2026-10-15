#!/bin/sh
# Fire-and-forget code-graph refresh for Claude Code hooks and git hooks - macOS.
#
# Master copy: graph-servers/graph-refresh.sh in the dev-workstation repo
# Installed to: ~/.claude/hooks/graph-refresh.sh  (by install.sh)
#
# The macOS sibling of graph-refresh.ps1, same behaviour, POSIX sh only (owner,
# 2026-10-15: the Mac side is sh, no PowerShell). ADR:
# Memory/tasks/20261015-194453-os-detect/ADR-macos-sh-installer.md. The reasons behind
# each step are written up at length in graph-refresh.ps1; they are not repeated here.
#
# It is USER-scope: it fires in every project, so every step is guarded by "does this
# repo actually have that index".
#
# WHY DETACHED (--detach). gitnexus analyze takes minutes; a hook must return at once.
# The child gets nohup and /dev/null for all three streams, so it holds none of the
# caller's pipes - a Claude Code hook waits for its stdout to close.
#
# ponytail: mkdir lock, no queue. A refresh requested while one runs is DROPPED; the
# gitnexus branch loops instead, so a commit landing mid-analyze is not left behind.
# The lock paths are the ones graph-refresh.ps1 uses on macOS ($TMPDIR), so during a
# migration the two versions never run the same refresh at once.
#
# Usage: graph-refresh.sh [--which crg|gitnexus|both] [--repo PATH] [--detach]

unset CDPATH

which_=crg
repo=${CLAUDE_PROJECT_DIR:-}
detach=0

while [ $# -gt 0 ]; do
    case $1 in
        --which) [ $# -ge 2 ] || { echo "graph-refresh.sh: --which needs a value" >&2; exit 2; }; which_=$2; shift 2 ;;
        --repo) [ $# -ge 2 ] || { echo "graph-refresh.sh: --repo needs a value" >&2; exit 2; }; repo=$2; shift 2 ;;
        --detach) detach=1; shift ;;
        *) echo "graph-refresh.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

case $which_ in
    crg|gitnexus|both) ;;
    *) echo "graph-refresh.sh: --which must be crg, gitnexus or both" >&2; exit 2 ;;
esac

[ -n "$repo" ] || repo=$(pwd)
[ -d "$repo" ] || exit 0
# Not inside a git work tree (or no git at all): skip - both graphs index a repository.
[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 0

tmp_dir=${TMPDIR:-/tmp}
tmp_dir=${tmp_dir%/}
log_file=$tmp_dir/claude-graph-refresh.log

log() {
    # Every give-up path leaves one line here, with the repo named.
    printf '%s [%s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$which_" "$repo" "$1" >>"$log_file"
}

# --- interpreter ------------------------------------------------------------
# CRG_PYTHON wins (install.sh points it at code-review-graph's own venv).
python=${CRG_PYTHON:-}
[ -n "$python" ] || python=$(command -v python3 || command -v python || true)

# The index is hundreds of MB; the default WAL checkpoint threshold (~16 MB) makes the
# update abort while still exiting 0. 64 MiB stops that.
GITNEXUS_WAL_CHECKPOINT_THRESHOLD=67108864
export GITNEXUS_WAL_CHECKPOINT_THRESHOLD

# --- detach -----------------------------------------------------------------
if [ "$detach" = 1 ]; then
    nohup /bin/sh "$0" --which "$which_" --repo "$repo" </dev/null >/dev/null 2>&1 &
    exit 0
fi

ensure_daemon() {
    # code-review-graph's own file watcher keeps the graph fresh with zero per-Edit cost.
    pid_file=$HOME/.code-review-graph/daemon.pid
    if [ -f "$pid_file" ]; then
        daemon_pid=$(tr -d ' \n\r' <"$pid_file")
        case $daemon_pid in
            ''|*[!0-9]*) ;;
            *) if kill -0 "$daemon_pid" 2>/dev/null; then return 0; fi ;;   # already watching
        esac
        # ponytail: pid-alive only, no identity check.
        rm -f "$pid_file"
    fi
    nohup "$python" -m code_review_graph daemon start </dev/null >/dev/null 2>&1 &
}

# run_once NAME COMMAND... - runs COMMAND unless another refresh of NAME holds the lock.
run_once() {
    lock=$tmp_dir/claude-graph-$1.lock
    shift
    # -e, not -d: a stray FILE at the lock path would otherwise make every mkdir below
    # fail, and the refresh would never run again (found by a mutation run 2026-10-15).
    if [ -e "$lock" ]; then
        # younger than 30 minutes: another refresh owns it; older: a crashed run.
        if [ -n "$(find "$lock" -maxdepth 0 -mmin -30 2>/dev/null)" ]; then return 0; fi
        rm -rf "$lock"
    fi
    mkdir "$lock" 2>/dev/null || return 0          # lost the race, nothing to do
    trap 'rm -rf "$lock"' EXIT INT TERM
    "$@"
    rm -rf "$lock"
    trap - EXIT INT TERM
}

crg_update() {
    "$python" -m code_review_graph update -q --repo "$repo" >/dev/null 2>&1
}

gitnexus_refresh() {
    # Only pay for analyze when HEAD moved past the indexed commit; up to 3 passes so a
    # commit landing DURING an analyze is not left behind. Bounded, so a burst of
    # commits cannot spin here.
    pass=0
    while [ $pass -lt 3 ]; do
        pass=$((pass + 1))
        head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
        if [ -z "$head" ]; then log 'git rev-parse HEAD gave nothing - refresh skipped'; return 0; fi
        # A pattern match, not a JSON parser: meta.json can hold keys that differ only
        # by case, and "lastCommit" occurs once, at the top level.
        indexed=$(sed -n 's/.*"lastCommit"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{7,40\}\)".*/\1/p' "$meta" | head -n 1)
        if [ -z "$indexed" ]; then log "cannot read lastCommit from $meta - refresh skipped"; return 0; fi
        [ "$head" = "$indexed" ] && return 0
        # --skip-agents-md: a refresh indexes; it never writes into an instruction file.
        (cd "$repo" && node "$runner" analyze --skip-agents-md >/dev/null 2>&1)
        rc=$?
        [ $rc -eq 0 ] || log "analyze exit $rc"
    done
}

# --- code-review-graph ------------------------------------------------------
if { [ "$which_" = crg ] || [ "$which_" = both ]; } && [ -d "$repo/.code-review-graph" ]; then
    if [ -z "$python" ]; then
        log 'no python found (set CRG_PYTHON)'
    else
        ensure_daemon
        # One catch-up pass for edits made while the daemon was down.
        run_once crg crg_update
    fi
fi

# --- gitnexus ---------------------------------------------------------------
if [ "$which_" = gitnexus ] || [ "$which_" = both ]; then
    runner=$repo/.gitnexus/run.cjs
    meta=$repo/.gitnexus/meta.json
    if [ -f "$runner" ] && [ -f "$meta" ]; then
        run_once gitnexus gitnexus_refresh
    fi
fi

exit 0
