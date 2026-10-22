#!/bin/sh
# Tests for graph-refresh.sh and post-commit.sh (macOS). Offline, touches nothing real:
# HOME, TMPDIR and PATH are pointed into a throwaway directory, and `node` / python are
# stubs that record how they were called.
#
# Usage: sh graph-servers/test-graph-refresh.sh [SHELL]
#   SHELL defaults to /bin/sh; run it again with /bin/dash to catch bash-isms.
# Env:   REFRESH_UNDER_TEST overrides which refresher is tested (mutation checks).

here=$(cd "$(dirname "$0")" && pwd)
shell=${1:-/bin/sh}
refresh=${REFRESH_UNDER_TEST:-$here/graph-refresh.sh}
postcommit=$here/post-commit.sh

pass=0
fail=0
check() {
    if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "  PASS  $1"
    else fail=$((fail + 1)); echo "  FAIL  $1"; fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/graph-refresh-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

real_git=$(command -v git)
bin=$work/bin
mkdir -p "$bin" "$work/home" "$work/tmp"
calls=$work/calls.log

# Stubs: append one line per call. NODE_SLEEP makes node slow (detach test).
cat >"$bin/node" <<'EOF'
#!/bin/sh
echo "node $*" >>"$STUB_CALLS"
[ -n "$NODE_SLEEP" ] && sleep "$NODE_SLEEP"
[ "${NODE_EXIT:-0}" != 0 ] && echo "ERROR: Database is locked by another process" >&2
exit "${NODE_EXIT:-0}"
EOF
cat >"$bin/fakepython" <<'EOF'
#!/bin/sh
echo "python $*" >>"$STUB_CALLS"
exit 0
EOF
chmod +x "$bin/node" "$bin/fakepython"

# A real git repository with one commit.
repo=$work/repo
mkdir -p "$repo"
"$real_git" -C "$repo" init -q
"$real_git" -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
head=$("$real_git" -C "$repo" rev-parse HEAD)

run() {
    # run ARGS... - the refresher, synchronously, in the sandbox
    : >"$calls"
    env -i PATH="$bin:/usr/bin:/bin" HOME="$work/home" TMPDIR="$work/tmp" \
        STUB_CALLS="$calls" CRG_PYTHON="${CRG:-$bin/fakepython}" NODE_EXIT="${NODE_EXIT:-0}" \
        NODE_SLEEP="${NODE_SLEEP:-}" \
        "$shell" "$refresh" "$@"
}
count() { grep -c "$1" "$calls" 2>/dev/null || true; }
logged() { grep -q "$1" "$work/tmp/claude-graph-refresh.log" 2>/dev/null; }

echo "graph-refresh.sh tests under $shell"

# 1. argument handling
run --which nonsense --repo "$repo" 2>/dev/null; check 'bad --which exits 2' "$([ $? = 2 ]; echo $?)"
run --bogus 2>/dev/null; check 'unknown argument exits 2' "$([ $? = 2 ]; echo $?)"
# --which / --repo as the LAST argument once looped for ever (shift 2 fails, nothing exits)
( run --which >/dev/null 2>&1 & p=$!; sleep 3; if kill -0 $p 2>/dev/null; then kill $p; exit 1; fi; wait $p; [ $? = 2 ] )
check 'a trailing --which with no value exits 2, does not hang' $?
( run --repo >/dev/null 2>&1 & p=$!; sleep 3; if kill -0 $p 2>/dev/null; then kill $p; exit 1; fi; wait $p; [ $? = 2 ] )
check 'a trailing --repo with no value exits 2, does not hang' $?

# 2. not a git work tree: nothing runs
mkdir -p "$work/plain/.code-review-graph"
run --which both --repo "$work/plain"; rc=$?
check 'non-repo: exit 0' "$([ $rc = 0 ]; echo $?)"
check 'non-repo: no stub called' "$([ ! -s "$calls" ]; echo $?)"

# 3. repo with no index of either kind: nothing runs
run --which both --repo "$repo"
check 'no index: no stub called' "$([ ! -s "$calls" ]; echo $?)"

# 4. code-review-graph
mkdir -p "$repo/.code-review-graph"
run --which crg --repo "$repo"
sleep 1    # the daemon start is backgrounded
check 'crg: update -q --repo called once' "$([ "$(count 'code_review_graph update -q --repo')" = 1 ]; echo $?)"
check 'crg: daemon started when no pid file' "$([ "$(count 'daemon start')" = 1 ]; echo $?)"
mkdir -p "$work/home/.code-review-graph"; echo $$ >"$work/home/.code-review-graph/daemon.pid"
run --which crg --repo "$repo"
sleep 1
check 'crg: live daemon pid is not restarted' "$([ "$(count 'daemon start')" = 0 ]; echo $?)"
echo 999999 >"$work/home/.code-review-graph/daemon.pid"
run --which crg --repo "$repo"
sleep 1
check 'crg: dead daemon pid is restarted' "$([ "$(count 'daemon start')" = 1 ]; echo $?)"
check 'crg: --which gitnexus does not touch crg' \
    "$(run --which gitnexus --repo "$repo"; sleep 1; [ "$(count code_review_graph)" = 0 ]; echo $?)"
CRG=/nonexistent/python run --which crg --repo "$repo" >/dev/null 2>&1
rm -rf "$repo/.code-review-graph"

# 5. gitnexus
mkdir -p "$repo/.gitnexus"
: >"$repo/.gitnexus/run.cjs"
printf '{"repoPath":"x","lastCommit":"%s","stats":{"Clear":1,"clear":2}}\n' "$head" >"$repo/.gitnexus/meta.json"
run --which gitnexus --repo "$repo"
check 'gitnexus: index at HEAD -> no analyze' "$([ "$(count 'node')" = 0 ]; echo $?)"

printf '{"lastCommit" : "0123456789abcdef0123456789abcdef01234567"}\n' >"$repo/.gitnexus/meta.json"
run --which gitnexus --repo "$repo"
check 'gitnexus: index behind -> analyze --skip-agents-md' "$([ "$(count 'run.cjs analyze --skip-agents-md')" -ge 1 ]; echo $?)"
check 'gitnexus: index that never catches up -> exactly 3 passes' "$([ "$(count 'node')" = 3 ]; echo $?)"

NODE_EXIT=7 run --which gitnexus --repo "$repo"
check 'gitnexus: failing analyze is logged with its exit code' "$(logged 'analyze exit 7'; echo $?)"
# a bare exit code cannot tell a locked database from a parse error (W1, 2026-10-21)
check 'gitnexus: ...and WHY - the end of its output is in the log' "$(logged 'Database is locked by another process'; echo $?)"
: >"$work/tmp/claude-graph-refresh.log"
# NODE_EXIT=0 explicitly: in POSIX sh `NODE_EXIT=7 run ...` above LEAVES NODE_EXIT=7 set
# after the function returns, so a bare `run` here would still be a failing analyze
NODE_EXIT=0 run --which gitnexus --repo "$repo"
check 'gitnexus: a SUCCESSFUL analyze logs nothing (its progress is not wanted)' "$([ ! -s "$work/tmp/claude-graph-refresh.log" ]; echo $?)"
check 'gitnexus: no captured-output file is left behind' "$([ -z "$(ls "$work/tmp" | grep 'claude-graph-analyze')" ]; echo $?)"

printf '{"nothing":"here"}\n' >"$repo/.gitnexus/meta.json"
run --which gitnexus --repo "$repo"
check 'gitnexus: unreadable lastCommit -> no analyze' "$([ "$(count 'node')" = 0 ]; echo $?)"
check 'gitnexus: unreadable lastCommit -> logged' "$(logged 'cannot read lastCommit'; echo $?)"

# 6. the lock
printf '{"lastCommit":"0123456789abcdef0123456789abcdef01234567"}\n' >"$repo/.gitnexus/meta.json"
mkdir "$work/tmp/claude-graph-gitnexus.lock"
run --which gitnexus --repo "$repo"
check 'lock: a fresh lock drops the refresh' "$([ "$(count 'node')" = 0 ]; echo $?)"
rm -rf "$work/tmp/claude-graph-gitnexus.lock"; mkdir "$work/tmp/claude-graph-gitnexus.lock"
touch -t 202001010000 "$work/tmp/claude-graph-gitnexus.lock"
run --which gitnexus --repo "$repo"
check 'lock: a stale lock (>30 min) is taken over' "$([ "$(count 'node')" -ge 1 ]; echo $?)"
check 'lock: released after the run' "$([ ! -e "$work/tmp/claude-graph-gitnexus.lock" ]; echo $?)"
rm -rf "$work/tmp/claude-graph-gitnexus.lock"; : >"$work/tmp/claude-graph-gitnexus.lock"
touch -t 202001010000 "$work/tmp/claude-graph-gitnexus.lock"
run --which gitnexus --repo "$repo"
check 'lock: a stale stray FILE at the lock path does not block refreshes for ever' "$([ "$(count 'node')" -ge 1 ]; echo $?)"
rm -rf "$work/tmp/claude-graph-gitnexus.lock"

# OLD IS NOT DEAD (W1: one analyze ran 11.5 h). Refresh A holds the lock with a slow
# analyze; its lock is backdated past 30 minutes; refresh B must NOT start a second analyze.
lk=$work/tmp/claude-graph-gitnexus.lock
: >"$calls"
env -i PATH="$bin:/usr/bin:/bin" HOME="$work/home" TMPDIR="$work/tmp" STUB_CALLS="$calls" \
    CRG_PYTHON="$bin/fakepython" NODE_SLEEP=5 "$shell" "$refresh" --which gitnexus --repo "$repo" & apid=$!
sleep 1
lline=$(head -n 1 "$lk/pid" 2>/dev/null); lpid=${lline%% *}
check 'lock: the holder writes its pid into the lock' "$([ "$lpid" -gt 0 ] 2>/dev/null; echo $?)"
check 'lock: ...and its START TIME beside it, as ps reports it' \
    "$([ "${lline#"$lpid" }" = "$(ps -p "$lpid" -o lstart= | tr -s ' ' | sed 's/^ //; s/ $//')" ]; echo $?)"
touch -t 202001010000 "$lk"
: >"$work/tmp/claude-graph-refresh.log"
env -i PATH="$bin:/usr/bin:/bin" HOME="$work/home" TMPDIR="$work/tmp" STUB_CALLS="$calls" \
    CRG_PYTHON="$bin/fakepython" "$shell" "$refresh" --which gitnexus --repo "$repo"
check 'lock: an OLD lock whose holder is ALIVE is not taken - no second analyze' "$([ "$(count 'node')" = 1 ]; echo $?)"
check 'lock: ...and the live holder is logged by pid' "$(logged 'is ALIVE'; echo $?)"
check 'lock: ...and the holder'"'"'s lock is still there' "$([ -d "$lk" ]; echo $?)"
kill $apid 2>/dev/null; wait $apid 2>/dev/null; rm -rf "$lk"
# a DEAD holder's old lock must still be taken over - the reason the rule exists
mkdir "$lk"; echo 999999 >"$lk/pid"; touch -t 202001010000 "$lk"
run --which gitnexus --repo "$repo"
check 'lock: an OLD lock whose recorded holder is DEAD is taken over' "$([ "$(count 'node')" -ge 1 ]; echo $?)"
# a recycled pid: alive, but started at another time than the one recorded - it must not
# hold the lock for ever. Same rule as graph-refresh.ps1 (owner, 2026-10-22).
sleep 30 & other=$!
ostart=$(ps -p $other -o lstart= | tr -s ' ' | sed 's/^ //; s/ $//')
mkdir -p "$lk"; printf '%s %s\n' $other 'Mon Jan 1 00:00:00 2001' >"$lk/pid"; touch -t 202001010000 "$lk"
run --which gitnexus --repo "$repo"
check 'lock: a live pid with the WRONG start time (recycled) does not keep the lock' "$([ "$(count 'node')" -ge 1 ]; echo $?)"
# the control that makes the case above mean something: the SAME live pid with its RIGHT
# start time must keep the lock - else the check could be dead and the case still pass
rm -rf "$lk"; mkdir -p "$lk"; printf '%s %s\n' $other "$ostart" >"$lk/pid"; touch -t 202001010000 "$lk"
run --which gitnexus --repo "$repo"
check 'lock: ...control: the same pid with its RIGHT start time keeps the lock' "$([ "$(count 'node')" = 0 ]; echo $?)"
# ⛔ `ps -o lstart` IS LOCALE-DEPENDENT (measured 2026-10-22: C "Thu Oct 22 10:40:33 2026",
# zh_TW "四 10月/22 10:40:33 2026"). The hook starts from SessionStart (Claude's locale) AND
# from post-commit (the terminal's), so a holder that wrote its start time in one locale and
# a reader in another must still agree it is alive.
rm -rf "$lk"; : >"$calls"
env -i PATH="$bin:/usr/bin:/bin" HOME="$work/home" TMPDIR="$work/tmp" STUB_CALLS="$calls" LC_ALL=zh_TW.UTF-8 \
    CRG_PYTHON="$bin/fakepython" NODE_SLEEP=5 "$shell" "$refresh" --which gitnexus --repo "$repo" & apid=$!
sleep 1
# the start time a zh_TW holder writes must still be a WHOLE C-locale one - else recycled
# pids would go undetected for every holder started from a zh_TW terminal (it would only
# ever read as "unknown, alive")
zline=$(head -n 1 "$lk/pid" 2>/dev/null); zstart=${zline#* }
check 'lock: a holder started in zh_TW still records a C-locale start time' \
    "$(printf '%s\n' "$(awk '/^whole_start\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$refresh")" 'whole_start "$1"' | "$shell" -s "$zstart"; echo $?)"
touch -t 202001010000 "$lk"
env -i PATH="$bin:/usr/bin:/bin" HOME="$work/home" TMPDIR="$work/tmp" STUB_CALLS="$calls" LC_ALL=C \
    CRG_PYTHON="$bin/fakepython" "$shell" "$refresh" --which gitnexus --repo "$repo"
check 'lock: a holder that wrote in zh_TW is still ALIVE to a reader in C' "$([ "$(count 'node')" = 1 ]; echo $?)"
kill $apid 2>/dev/null; wait $apid 2>/dev/null; rm -rf "$lk"
# a start time cut short (a write that failed half way) is not a whole timestamp: unknown,
# so ALIVE - never "a different start time", which would steal from a live holder (W1)
mkdir -p "$lk"; printf '%s %s\n' $other 'Thu Oct 2' >"$lk/pid"; touch -t 202001010000 "$lk"
run --which gitnexus --repo "$repo"
check 'lock: a start time cut short leaves a live holder alone' "$([ "$(count 'node')" = 0 ]; echo $?)"
rm -rf "$lk"
# every PREFIX of a real start time must be rejected as "not whole" - a truncated write
# cuts the end, and W1 found on Windows that a truncated ISO time still parses as a date
fn=$(awk '/^whole_start\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$refresh")
real=$(LC_ALL=C ps -p $$ -o lstart= | tr -s ' ' | sed 's/^ //; s/ $//')
bad=$(printf '%s\n' "$fn" 'r=$1; n=${#r}; i=1; while [ $i -lt $n ]; do p=$(printf %s "$r" | cut -c1-$i); whole_start "$p" && echo "$p"; i=$((i+1)); done' \
      | "$shell" -s "$real")
check 'whole_start: the real start time itself is whole (control)' "$(printf '%s\n' "$fn" 'whole_start "$1"' | "$shell" -s "$real"; echo $?)"
check "whole_start: none of its ${#real} - 1 shorter prefixes passes as whole" "$([ -z "$bad" ]; echo $?)"
check 'whole_start: a zh_TW start time is not whole' "$(printf '%s\n' "$fn" 'whole_start "$1"' | "$shell" -s '四 10月/22 10:40:33 2026'; [ $? = 1 ]; echo $?)"
# a lock written by the previous version holds the pid alone: treated as ALIVE
rm -rf "$lk"; mkdir -p "$lk"; echo $other >"$lk/pid"; touch -t 202001010000 "$lk"
run --which gitnexus --repo "$repo"
check 'lock: an older lock with no start time and a live pid is left alone' "$([ "$(count 'node')" = 0 ]; echo $?)"
kill $other 2>/dev/null; wait $other 2>/dev/null; rm -rf "$lk"

# 7. --detach returns at once while the refresh runs on
start=$(date +%s)
NODE_SLEEP=4 run --which gitnexus --repo "$repo" --detach
elapsed=$(( $(date +%s) - start ))
check "detach: returned in ${elapsed}s (< 2s) although analyze takes 4s" "$([ $elapsed -lt 2 ]; echo $?)"
sleep 1
check 'detach: the detached child did run analyze' "$([ "$(count 'node')" -ge 1 ]; echo $?)"
sleep 12   # let the 3 slow passes finish before the sandbox is removed

# 8. post-commit.sh
: >"$calls"
out=$(cd "$repo" && env -i PATH="$bin:/usr/bin:/bin" HOME="$work/home" "$shell" "$postcommit" 2>&1); rc=$?
check 'post-commit: no refresher installed -> exit 0' "$([ $rc = 0 ]; echo $?)"
check 'post-commit: no refresher installed -> says so' "$(echo "$out" | grep -q 'not installed'; echo $?)"
mkdir -p "$work/home/.claude/hooks"
printf '#!/bin/sh\necho "refresh $*" >>"%s"\n' "$calls" >"$work/home/.claude/hooks/graph-refresh.sh"
(cd "$repo" && env -i PATH="$bin:/usr/bin:/bin" HOME="$work/home" "$shell" "$postcommit"); rc=$?
check 'post-commit: exit 0' "$([ $rc = 0 ]; echo $?)"
check 'post-commit: calls the refresher for gitnexus, detached, with this repo' \
    "$(grep -q "refresh --which gitnexus --repo $(cd "$repo" && pwd -P) --detach" "$calls"; echo $?)"

echo
echo "  $pass PASS  $fail FAIL"
[ $fail = 0 ]
