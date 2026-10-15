#!/bin/sh
# Tests for parity-check.sh: every way the two lists can drift, and every way the
# extraction can break, must give the right exit code. Fixtures are sed-edited copies of
# the REAL install.ps1 and install.sh, so a format change in either file is exercised too.
#
# Usage: sh Tools/test-parity-check.sh [SHELL]   (default /bin/sh; also run with /bin/dash)

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
shell=${1:-/bin/sh}
check_script=${PARITY_UNDER_TEST:-$here/parity-check.sh}

pass=0; fail=0
work=$(mktemp -d "${TMPDIR:-/tmp}/parity-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# case NAME EXPECTED_EXIT EXPECTED_TEXT PS1_SED SH_SED
#   an empty sed expression leaves that file as it is
case_() {
    name=$1; want=$2; text=$3
    if [ -n "$4" ]; then sed "$4" "$root/install.ps1" >"$work/a.ps1"; else cp "$root/install.ps1" "$work/a.ps1"; fi
    if [ -n "$5" ]; then sed "$5" "$root/install.sh" >"$work/a.sh"; else cp "$root/install.sh" "$work/a.sh"; fi
    # the fixture must actually differ when an edit was asked for - else the case proves nothing
    if [ -n "$4" ] && cmp -s "$work/a.ps1" "$root/install.ps1"; then fail=$((fail + 1)); echo "  FAIL  $name (fixture edit did not apply to install.ps1)"; return; fi
    if [ -n "$5" ] && cmp -s "$work/a.sh" "$root/install.sh"; then fail=$((fail + 1)); echo "  FAIL  $name (fixture edit did not apply to install.sh)"; return; fi
    out=$("$shell" "$check_script" "$work/a.ps1" "$work/a.sh" 2>&1); got=$?
    if [ "$got" = "$want" ] && printf '%s\n' "$out" | grep -q -- "$text"; then
        pass=$((pass + 1)); echo "  PASS  $name"
    else
        fail=$((fail + 1)); echo "  FAIL  $name (exit $got, wanted $want; output: $(printf '%s' "$out" | head -n 2 | tr '\n' ' '))"
    fi
}

echo "parity-check tests under $shell"

case_ 'the real files are in parity' 0 'parity OK' '' ''

# drift: same counts, a different name
case_ 'a renamed macOS row is DRIFT' 1 "DRIFT   'nodejs'" '' 's/^node|vendor-tarball/nodejs|vendor-tarball/'
case_ 'a renamed Windows row is DRIFT' 1 "DRIFT   'nodejs'" "s/@{ Name = 'node';/@{ Name = 'nodejs';/" ''
case_ 'a renamed plugin is DRIFT' 1 "DRIFT   plugin" '' 's/^mattpocock-skills|/mattpocock-skillz|/'
case_ 'a renamed Windows-only row leaves a STALE exception' 1 'STALE   Windows-only' "s/@{ Name = 'telnet';/@{ Name = 'telnet2';/" ''
case_ 'a macOS row taking a Windows-only name is a CONFLICT' 1 'CONFLICT' '' 's/^openssl3|/putty|/'

# a row added or removed changes a count: loud, never silent
case_ 'a removed macOS row fails the count' 2 'found 7 names, expected 8' '' '/^uv|vendor-script/d'
case_ 'an added Windows row fails the count' 2 'found 13 names, expected 12' "s/^\\(    @{ Name = 'uv';\\)/    @{ Name = 'extra'; }\\
\\1/" ''

# the extraction itself breaking must not look like a pass
case_ 'a commented-out Windows row is not counted' 0 'parity OK' "s/^\\(    @{ Name = 'uv';\\)/    # @{ Name = 'ghost'; }\\
\\1/" ''
case_ 'a reformatted Windows row (short list) fails the count' 2 'found 11 names' "s/@{ Name = 'git';/@{ 'Name' = 'git';/" ''
case_ 'a missing $DEPS marker stops the check' 2 'no .\$DEPS = @(. line' 's/^\$DEPS = @(/$DEPS=@(/' ''
case_ 'an indented closing paren of $DEPS is caught, not read past (W1 a7a191a)' 2 'runs into the next top-level block' '/^\$DEPS = @(/,/^)/s/^)/    )/' ''
case_ 'a macOS row named like openssl@3 is named as malformed, not miscounted' 2 'malformed row: openssl@3|' '' 's/^openssl3|/openssl@3|/'
case_ 'a missing BEGIN-DEPS marker stops the check' 2 "no '# BEGIN-DEPS' marker" '' 's/^# BEGIN-DEPS/# BEGIN DEPS/'
case_ 'a missing END-PLUGINS marker stops the check' 2 "no '# END-PLUGINS' marker" '' 's/^# END-PLUGINS/# END PLUGINS/'

echo
echo "  $pass PASS  $fail FAIL"
[ $fail = 0 ]
