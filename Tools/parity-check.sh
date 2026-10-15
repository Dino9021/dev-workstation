#!/bin/sh
# parity-check.sh - fail when the Windows and the macOS installers' tool lists drift apart.
#
# The owner chose two installers, one per platform (2026-10-15; ADR
# Memory/tasks/20261015-194453-os-detect/ADR-macos-sh-installer.md, J4). The price is two
# lists that can drift; this check is what makes a drift loud. It compares NAMES only -
# not versions, not routes - of:
#     install.ps1  $DEPS = @( ... )      against   install.sh  BEGIN-DEPS ... END-DEPS
#     install.ps1  $PLUGINS = @( ... )   against   install.sh  BEGIN-PLUGINS ... END-PLUGINS
#
# THE EXCEPTION LISTS BELOW ARE PART OF THE DESIGN, not an escape hatch: a row that exists
# on one platform only is named here with its reason, so moving a row onto or off a list is
# a visible line in a diff (W1's requirement, board 2026-10-15).
#
# A SHORT LIST IS A FAILURE, NOT A PASS. The extractor is a pattern over a file somebody
# else edits; after a formatting change it could silently match fewer rows and the
# comparison would still look clean. So each extraction is checked against a literal
# expected count, and a missing start or end marker stops the check. Changing a count here
# is the deliberate act of whoever added or removed a row.
#
# Usage: sh Tools/parity-check.sh [install.ps1] [install.sh]
# Exit:  0 equal (modulo the exceptions)   1 drift   2 the extraction itself is broken

# ---------------------------------------------------------------- the literal expectations
EXPECT_WIN_DEPS=12
EXPECT_WIN_PLUGINS=2
EXPECT_MAC_DEPS=8
EXPECT_MAC_PLUGINS=2

# name  reason
WINDOWS_ONLY='
pwsh          PowerShell 7 is the Windows installer'"'"'s own runtime; macOS has no PowerShell (owner: sh)
vcredist-x64  Microsoft Visual C++ runtime - a Windows DLL package
vcredist-x86  Microsoft Visual C++ runtime - a Windows DLL package
tortoisegit   TortoiseGit is a Windows Explorer extension
telnet        a Windows optional feature (TelnetClient); macOS has nc and ssh
putty         a Windows SSH client; macOS ships ssh
'
MAC_ONLY='
homebrew      GitNexus links Homebrew openssl@3 by absolute path (/opt/homebrew/opt/openssl@3)
openssl3      openssl@3 itself, for the same reason
'

# ---------------------------------------------------------------- extraction

die2() { echo "parity-check: $*" >&2; exit 2; }

# ps1_block FILE VAR -> the Name = '...' values inside `$VAR = @(` ... the closing `)`
ps1_block() {
    grep -q "^\\\$$2 = @(" "$1" || die2 "no '\$$2 = @(' line in $1 - the block moved or was renamed"
    # ⛔ "the next line starting with )" is not enough on its own: if the real closing paren
    # gets indented, the NEXT column-0 ) (another block's) satisfies it, the block silently
    # grows past other variables, and the check still says OK (found by W1, review
    # a7a191a). So meeting another top-level `$NAME = @(` while inside is fatal too.
    # `ranon` is not optional: awk runs END after a rule's exit, and END would otherwise
    # overwrite exit 4 with exit 3.
    awk -v start="^[$]$2 = @[(]" '
        $0 ~ start { inside = 1; next }
        inside && /^\)/ { closed = 1; exit }
        inside && /^[$][A-Za-z_][A-Za-z_0-9]* = @[(]/ { ranon = 1; exit 4 }
        inside { print }
        END { if (ranon) exit 4; if (!closed) exit 3 }
    ' "$1" >"$tmp/block"
    rc=$?
    [ $rc = 4 ] && die2 "'\$$2 = @(' in $1 runs into the next top-level block before a line starting with ')' closes it - its closing paren was probably indented"
    [ $rc = 0 ] || die2 "'\$$2 = @(' in $1 is never closed by a line starting with ')'"
    sed -n "s/^[[:space:]]*@{[[:space:]]*Name[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p" "$tmp/block"
}

# sh_block FILE TAG -> the first field of every row between `# BEGIN-TAG` and `# END-TAG`
sh_block() {
    grep -q "^# BEGIN-$2" "$1" || die2 "no '# BEGIN-$2' marker in $1"
    grep -q "^# END-$2" "$1" || die2 "no '# END-$2' marker in $1"
    # A line that has a | but does not START like a row name (an uppercase letter, a dot,
    # an @ - openssl@3 is exactly that shape) is NAMED and fails, rather than dropped and
    # misreported by the count as "a row was added or removed" (W1, review a7a191a).
    awk -v b="^# BEGIN-$2" -v e="^# END-$2" '
        $0 ~ b { inside = 1; next }
        $0 ~ e { exit }
        inside && /^[a-z0-9][a-z0-9-]*\|/ { split($0, f, "|"); print f[1]; next }
        inside && /^[[:space:]]*#/ { next }
        inside && /\|/ { print "malformed row: " $0 > "/dev/stderr"; bad = 1 }
        END { if (bad) exit 5 }
    ' "$1" || die2 "$1 $2 has a row whose name is not lower-case letters, digits and - (see above)"
}

names_of() { printf '%s\n' "$1" | awk 'NF { print $1 }'; }

expect_count() {
    # expect_count WHAT LIST N
    n=$(printf '%s\n' "$2" | grep -c .)
    [ "$n" = "$3" ] || die2 "$1: found $n names, expected $3 - a row was added or removed (update the expectation on purpose) or the extractor no longer matches the file's format. Found: $(printf '%s ' $2)"
}

# ---------------------------------------------------------------- main

here=$(cd "$(dirname "$0")/.." && pwd)
ps1=${1:-$here/install.ps1}
shf=${2:-$here/install.sh}
[ -f "$ps1" ] || die2 "not found: $ps1"
[ -f "$shf" ] || die2 "not found: $shf"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/parity.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

win_deps=$(ps1_block "$ps1" DEPS) || exit 2
win_plugins=$(ps1_block "$ps1" PLUGINS) || exit 2
mac_deps=$(sh_block "$shf" DEPS) || exit 2
mac_plugins=$(sh_block "$shf" PLUGINS) || exit 2

expect_count 'install.ps1 $DEPS' "$win_deps" "$EXPECT_WIN_DEPS"
expect_count 'install.ps1 $PLUGINS' "$win_plugins" "$EXPECT_WIN_PLUGINS"
expect_count 'install.sh DEPS' "$mac_deps" "$EXPECT_MAC_DEPS"
expect_count 'install.sh PLUGINS' "$mac_plugins" "$EXPECT_MAC_PLUGINS"

win_only=$(names_of "$WINDOWS_ONLY")
mac_only=$(names_of "$MAC_ONLY")
status=0

# Every exception must still name a real row on its own side - a stale exception hides
# nothing today and silently excuses the next row that happens to take its name.
for n in $win_only; do
    printf '%s\n' "$win_deps" | grep -qxF "$n" || { echo "STALE   Windows-only exception '$n' is not in install.ps1 \$DEPS"; status=1; }
    printf '%s\n' "$mac_deps" | grep -qxF "$n" && { echo "CONFLICT '$n' is excepted as Windows-only but install.sh has it"; status=1; }
done
for n in $mac_only; do
    printf '%s\n' "$mac_deps" | grep -qxF "$n" || { echo "STALE   macOS-only exception '$n' is not in install.sh DEPS"; status=1; }
    printf '%s\n' "$win_deps" | grep -qxF "$n" && { echo "CONFLICT '$n' is excepted as macOS-only but install.ps1 has it"; status=1; }
done

for n in $win_deps; do
    printf '%s\n' "$win_only" | grep -qxF "$n" && continue
    printf '%s\n' "$mac_deps" | grep -qxF "$n" || { echo "DRIFT   '$n' is in install.ps1 \$DEPS but not in install.sh, and is not listed as Windows-only"; status=1; }
done
for n in $mac_deps; do
    printf '%s\n' "$mac_only" | grep -qxF "$n" && continue
    printf '%s\n' "$win_deps" | grep -qxF "$n" || { echo "DRIFT   '$n' is in install.sh but not in install.ps1 \$DEPS, and is not listed as macOS-only"; status=1; }
done
for n in $win_plugins; do
    printf '%s\n' "$mac_plugins" | grep -qxF "$n" || { echo "DRIFT   plugin '$n' is in install.ps1 but not in install.sh"; status=1; }
done
for n in $mac_plugins; do
    printf '%s\n' "$win_plugins" | grep -qxF "$n" || { echo "DRIFT   plugin '$n' is in install.sh but not in install.ps1"; status=1; }
done

if [ $status = 0 ]; then
    echo "parity OK: $EXPECT_WIN_DEPS Windows rows, $EXPECT_MAC_DEPS macOS rows, $(printf '%s\n' "$win_only" | grep -c .) Windows-only, $(printf '%s\n' "$mac_only" | grep -c .) macOS-only, $EXPECT_WIN_PLUGINS plugins"
fi
exit $status
