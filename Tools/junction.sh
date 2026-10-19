#!/bin/sh
# junction.sh - move ~/.claude (or another data folder) to a different disk, and leave a
# SYMLINK behind so every tool still finds it at the old path. The macOS counterpart of
# Tools/junction.ps1.
#
# ⛔ NOT PART OF install.sh, DELIBERATELY. Relocating Claude Code's own data is somebody
# else's house and tens of gigabytes of it. Run this once, by hand, when you decide to -
# never as a side effect of installing or updating (owner, 2026-10-19).
#
# ⚠ macOS HAS NO JUNCTION. That is a Windows NTFS feature. The equivalent here is a
# symbolic link, which on macOS needs no administrator and works across disks. Hard links
# cannot be used: a normal user cannot hard-link a directory, and hard links cannot cross
# disks anyway.
#
# ⚠ FOLDERS ONLY. Never link a single FILE. Programs commonly save by writing a temporary
# file and renaming it over the original; the rename REPLACES the link with an ordinary
# file and the link is silently gone. ~/.claude.json is a file and is left alone.
#
# ⚠ IF THE TARGET IS AN EXTERNAL DISK: it must be APFS or HFS+, never exFAT or FAT32 -
# those have no Unix permissions and cannot hold symlinks, and the SQLite databases under
# ~/.claude-mem and ~/.code-review-graph lock unreliably on them. And in Finder's Get Info
# for the disk, "Ignore ownership on this volume" must be OFF or permissions do not apply.
# If the disk is ever missing when Claude Code starts, the link points at nothing and a new
# EMPTY folder may be created in its place - which looks exactly like losing everything.
#
# THE ORDER MATTERS. The source is RENAMED, not deleted; then the link is made and checked;
# only then is the renamed copy removed. Until that last step there is a way back.
#
# Usage:
#   sh Tools/junction.sh --target /Volumes/Ext/AgentData/.claude
#   ... --source "$HOME/.claude-mem"   move something else
#   ... --dry-run                      show the plan and touch nothing - works with Claude Code
#                                      open, and says whether a real run would refuse
#   ... --keep-backup                  keep the renamed original
#   ... --self-test                    run the checks offline; touches no real folder
#
# Exit: 0 done (or already a link; --dry-run: a real run would go ahead)
#       1 refused, nothing changed (--dry-run: a real run would refuse, and says why)
#       2 FAILED MID-WAY - or done, but the original was KEPT because it changed during the move

set -eu

SOURCE="${HOME}/.claude"
TARGET=""
DRY_RUN=0
KEEP_BACKUP=0
SELF_TEST=0

say()  { printf '%s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --target)      TARGET="${2:-}"; shift 2 ;;
        --source)      SOURCE="${2:-}"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --keep-backup) KEEP_BACKUP=1; shift ;;
        --self-test)   SELF_TEST=1; shift ;;
        *) say "junction.sh: unknown argument '$1'"; exit 1 ;;
    esac
done

# ------------------------------------------------------------------ pure helpers

# is_claude_running ENV_MARKER PROCESS_COUNT -> 0 (true) / 1 (false)
# Two independent signals: the CLAUDECODE variable is set INSIDE a session, which catches
# "you are running this from inside Claude Code"; a running process catches a session open
# in another window, which your own environment knows nothing about.
is_claude_running() {
    [ -n "$1" ] && return 0
    [ "$2" -gt 0 ] && return 0
    return 1
}

# target_problem SOURCE TARGET TARGET_EXISTS TARGET_ENTRIES PARENT_EXISTS
# prints the reason the target cannot be used, or nothing when it can.
target_problem() {
    _s=$(printf '%s' "$1" | sed 's:/*$::')
    _t=$(printf '%s' "$2" | sed 's:/*$::')
    _texists=$3; _tcount=$4; _pexists=$5
    if [ -z "$_t" ]; then printf 'no target path was given'; return; fi
    if [ "$_s" = "$_t" ]; then printf 'the target is the source'; return; fi
    # ⛔ A target INSIDE the source copies a folder into itself, for ever. The trailing
    # slash matters: without it, ~/.claude-mem would look like it is inside ~/.claude.
    case "$_t/" in
        "$_s"/*) printf 'the target is inside the source (%s) - that would copy a folder into itself' "$_s"; return ;;
    esac
    if [ "$_pexists" -eq 0 ]; then printf "the target's parent folder does not exist"; return; fi
    if [ "$_texists" -eq 1 ] && [ "$_tcount" -gt 0 ]; then
        printf 'the target already exists and is not empty (%s entries) - choose an empty or new folder' "$_tcount"
        return
    fi
}

# mount_noowners MOUNT_LINE -> 0 (true) when the volume IGNORES OWNERSHIP ("Ignore ownership
# on this volume" ticked in Finder's Get Info). macOS prints it as `noowners` among the
# mount options. Measured 2026-10-20 on the owner's external disk: `/dev/disk7s1 on
# /Volumes/SSD (apfs, local, nodev, nosuid, journaled, noowners)` - APFS, so the filesystem
# check alone passed it, although the header above says ownership must be honoured (J1).
mount_noowners() {
    case "$1" in
        *noowners*) return 0 ;;
        *) return 1 ;;
    esac
}

# holders SOURCE OWN_PID < `lsof -n -Fpcn` -> "<command> (pid <n>)" for every process with a
# file open at or under SOURCE, sorted, one per line; nothing when none does.
# ⛔ `pgrep -x claude` IS NOT ENOUGH ON ITS OWN. Measured 2026-10-20: four VS Code "Code
# Helper" processes held ~/.claude/settings.json while `pgrep -x claude` counted only the
# CLI (J3). Asking the kernel who holds what catches every tool, named. The trailing slash
# in the prefix keeps ~/.claude-mem from looking like it is inside ~/.claude.
holders() {
    awk -v s="$1" -v me="$2" '
        /^p/ { pid = substr($0, 2) }
        /^c/ { cmd = substr($0, 2) }
        /^n/ { n = substr($0, 2)
               if (pid != me && (n == s || index(n, s "/") == 1)) seen[cmd " (pid " pid ")"] = 1 }
        END { for (k in seen) print k }
    ' | LC_ALL=C sort
}

# manifest DIR -> "<size> <relative path>" per file, sorted. Comparing PATHS catches a file
# that never arrived; comparing SIZES catches one that arrived truncated. A count alone
# catches neither reliably: two different files make the same count.
#
# SYMLINKS ARE LISTED TOO, as "L <link text> <relative path>". ~/.claude holds two dozen
# (relative, under plugins/), and a copy missing one used to compare EQUAL - measured with a
# positive control 2026-10-20 (J4). The link TEXT is compared, never followed: following a
# relative link from a different root would read a different file.
#
# ⛔ SIZE COMES FROM `wc -c`, NOT FROM `stat`, AND THAT IS NOT A STYLE CHOICE. `stat` takes
# incompatible flags on the two platforms this project targets: BSD/macOS `stat -f '%z'`
# means "size of this file", while GNU `stat -f` means "filesystem status" and needs -c for
# a format. So the obvious `stat -f ... || stat -c ...` fallback is WRONG IN ONE DIRECTION:
# measured on Git Bash 2026-10-19, `stat -f '%z' file` fails (good, the fallback runs), but
# the reverse ordering on a Mac would have taken the wrong branch silently. `wc -c` is in
# POSIX, means the same thing in both places, and needs no fallback at all.
manifest() {
    _d=$1
    ( cd "$_d" && find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do
        if [ -L "$f" ]; then
            printf 'L %s %s\n' "$(readlink "$f")" "$f"
        else
            printf '%s %s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"
        fi
    done )
}

human() {
    awk -v b="$1" 'BEGIN{
        if (b>=1073741824) printf "%.2f GB", b/1073741824;
        else if (b>=1048576) printf "%.1f MB", b/1048576;
        else printf "%d bytes", b
    }'
}

# ------------------------------------------------------------------ self-test

if [ "$SELF_TEST" -eq 1 ]; then
    fails=0
    ck() { if [ "$2" = "1" ]; then printf '   PASS  %s\n' "$1"; else printf '   FAIL  %s\n' "$1"; fails=$((fails+1)); fi; }
    eq() { if [ "$1" = "$2" ]; then printf 1; else printf 0; fi; }
    has() { case "$1" in *"$2"*) printf 1 ;; *) printf 0 ;; esac; }

    say 'junction.sh self-test'

    if is_claude_running "1" 0; then ck 'running: the CLAUDECODE marker alone is enough' 1; else ck 'running: the CLAUDECODE marker alone is enough' 0; fi
    if is_claude_running "" 3;  then ck 'running: a claude process alone is enough' 1; else ck 'running: a claude process alone is enough' 0; fi
    if is_claude_running "" 0;  then ck 'running: neither means it is safe to proceed' 0; else ck 'running: neither means it is safe to proceed' 1; fi

    S='/Users/u/.claude'
    ck 'target: a fresh folder is accepted'        "$(eq "$(target_problem "$S" /Volumes/Ext/.claude 0 0 1)" '')"
    ck 'target: an EMPTY existing folder is accepted' "$(eq "$(target_problem "$S" /Volumes/Ext/.claude 1 0 1)" '')"
    ck 'target: a non-empty folder is refused'     "$(has "$(target_problem "$S" /Volumes/Ext/.claude 1 5 1)" 'not empty')"
    ck 'target: a missing parent is refused'       "$(has "$(target_problem "$S" /Volumes/Ext/.claude 0 0 0)" 'parent')"
    ck 'target: the source itself is refused'      "$(eq "$(target_problem "$S" "$S" 1 9 1)" 'the target is the source')"
    ck 'target: a trailing slash is still the source' "$(eq "$(target_problem "$S" "$S/" 1 9 1)" 'the target is the source')"
    ck 'target: a folder inside the source is refused' "$(has "$(target_problem "$S" "$S/moved" 0 0 1)" 'inside the source')"
    # The lookalike that must NOT be refused: a sibling whose name merely starts the same.
    ck 'target: a SIBLING with a similar name is accepted' "$(eq "$(target_problem "$S" /Users/u/.claude-mem 0 0 1)" '')"
    ck 'target: no path at all is refused'         "$(has "$(target_problem "$S" '' 0 0 1)" 'no target')"

    _sb=$(mktemp -d)
    mkdir -p "$_sb/a/sub"; printf 'hello' > "$_sb/a/one.txt"; printf 'xy' > "$_sb/a/sub/two.txt"
    mkdir -p "$_sb/b/sub"; printf 'hello' > "$_sb/b/one.txt"; printf 'xy' > "$_sb/b/sub/two.txt"
    ck 'manifest: identical trees compare equal' "$(eq "$(manifest "$_sb/a")" "$(manifest "$_sb/b")")"
    printf 'x' > "$_sb/b/sub/two.txt"
    ck 'manifest: a TRUNCATED file is detected'  "$(if [ "$(manifest "$_sb/a")" = "$(manifest "$_sb/b")" ]; then printf 0; else printf 1; fi)"
    printf 'xy' > "$_sb/b/sub/two.txt"; printf 'z' > "$_sb/b/extra.txt"
    ck 'manifest: an extra file is detected'     "$(if [ "$(manifest "$_sb/a")" = "$(manifest "$_sb/b")" ]; then printf 0; else printf 1; fi)"
    # The control: without it, a manifest that always returned nothing would pass every
    # case above by making both sides equally empty.
    ck 'manifest: control - it really lists the files' "$(has "$(manifest "$_sb/a")" 'one.txt')"
    # J4: a symlink missing from the copy, or pointing elsewhere, must be detected
    rm -f "$_sb/b/extra.txt"; ln -s one.txt "$_sb/a/AGENTS.md"
    ck 'manifest: a MISSING symlink is detected (J4)' "$(if [ "$(manifest "$_sb/a")" = "$(manifest "$_sb/b")" ]; then printf 0; else printf 1; fi)"
    ln -s sub/two.txt "$_sb/b/AGENTS.md"
    ck 'manifest: a symlink with ANOTHER target is detected' "$(if [ "$(manifest "$_sb/a")" = "$(manifest "$_sb/b")" ]; then printf 0; else printf 1; fi)"
    rm -f "$_sb/b/AGENTS.md"; ln -s one.txt "$_sb/b/AGENTS.md"
    ck 'manifest: identical symlinks compare equal' "$(eq "$(manifest "$_sb/a")" "$(manifest "$_sb/b")")"
    rm -rf "$_sb"

    # J1: the owner's external disk, verbatim, and a normal APFS mount as the lookalike
    if mount_noowners '/dev/disk7s1 on /Volumes/SSD (apfs, local, nodev, nosuid, journaled, noowners)'; then ck 'noowners: the owner'"'"'s SSD mount line is caught (J1)' 1; else ck 'noowners: the owner'"'"'s SSD mount line is caught (J1)' 0; fi
    if mount_noowners '/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse)'; then ck 'noowners: a normal APFS mount is NOT flagged' 0; else ck 'noowners: a normal APFS mount is NOT flagged' 1; fi

    # J3: lsof -Fpcn shaped input - the holder, a lookalike sibling, our own pid, the folder itself
    _l=$(printf '%s\n' p11 'cCode Helper' f5 'n/Users/u/.claude/settings.json' \
                       p22 cbun f6 'n/Users/u/.claude-mem/db.sqlite' \
                       p33 csh f7 'n/Users/u/.claude/x' \
                       p44 cfinder fcwd 'n/Users/u/.claude' | holders /Users/u/.claude 33)
    ck 'holders: a process holding a file inside is named (J3)' "$(has "$_l" 'Code Helper (pid 11)')"
    ck 'holders: a process whose cwd IS the folder is named' "$(has "$_l" 'finder (pid 44)')"
    ck 'holders: a SIBLING folder (.claude-mem) is not counted' "$(if printf '%s' "$_l" | grep -q 'bun'; then printf 0; else printf 1; fi)"
    ck 'holders: this script'"'"'s own pid is not counted' "$(if printf '%s' "$_l" | grep -q 'pid 33'; then printf 0; else printf 1; fi)"
    ck 'holders: nothing open means no output' "$(eq "$(printf '%s\n' p1 cx f1 n/tmp/y | holders /Users/u/.claude 0)" '')"

    say ''
    if [ "$fails" -gt 0 ]; then say "   self-test: $fails failed"; exit 1; fi
    say '   self-test: all passed'
    exit 0
fi

# ------------------------------------------------------------------ the run

say ''
say '== Move a Claude Code data folder to another disk'
say ''

# --- 1. the source
if [ ! -e "$SOURCE" ]; then note "source does not exist: $SOURCE"; exit 1; fi
if [ -L "$SOURCE" ]; then
    note "$SOURCE is already a symlink -> $(readlink "$SOURCE")"
    note 'Nothing to do. To move it somewhere else, remove the link first with'
    note "   rm \"$SOURCE\"        <- removes the LINK only, never rm -rf on a link"
    exit 0
fi
if [ ! -d "$SOURCE" ]; then
    note "source is a FILE, not a folder: $SOURCE"
    note 'Never link a single file - see the header.'
    exit 1
fi

# --- 2. is Claude Code running, or does anything else hold a file in the source?
#
# ⭐ A --dry-run REPORTS this and goes on to the plan; only a real run refuses here. The
# preview used to stop at this point, so with any Claude Code window open - which on the
# owner's Mac is always - the plan could never be seen at all (J2, measured 2026-10-20).
# WOULD_REFUSE collects every reason a real run would stop; a dry run exits 1 when it is set.
WOULD_REFUSE=''
PROCS=$(pgrep -x claude 2>/dev/null | wc -l | tr -d ' ')
[ -n "$PROCS" ] || PROCS=0
# lsof reports PHYSICAL paths: /var/... arrives as /private/var/..., and any symlinked
# component of SOURCE is resolved. Compared against SOURCE as typed, a holder was missed
# (measured 2026-10-20 in the sandbox test, where TMPDIR is under /var). So: pwd -P first.
SOURCE_REAL=$(cd "$SOURCE" && pwd -P)
HOLDERS=$(lsof -n -Fpcn 2>/dev/null | holders "$SOURCE_REAL" "$$")
if is_claude_running "${CLAUDECODE:-}" "$PROCS" || [ -n "$HOLDERS" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        note '⚠ a real run would REFUSE right now:'
    else
        note 'Claude Code, or something else, is using this folder. Nothing has been changed.'
    fi
    say ''
    if [ -n "${CLAUDECODE:-}" ]; then
        note 'You are running this script FROM INSIDE Claude Code (CLAUDECODE is set).'
        note 'This session is reading and writing the very folder you are asking to move.'
    fi
    [ "$PROCS" -gt 0 ] && note "$PROCS claude process(es) are running."
    if [ -n "$HOLDERS" ]; then
        note "these have a file open in $SOURCE:"
        printf '%s\n' "$HOLDERS" | while IFS= read -r h; do note "   $h"; done
    fi
    say ''
    note 'Quit every Claude Code window and VS Code (its extension holds settings.json), then'
    note 'run this again from a plain Terminal.'
    if [ "$DRY_RUN" -ne 1 ]; then exit 1; fi
    WOULD_REFUSE="$WOULD_REFUSE claude-running"
    say ''
fi

# --- 3. the target
if [ -z "$TARGET" ]; then
    say 'Where should it go? Give a full path on the disk you want, for example:'
    note '/Volumes/Ext/AgentData/.claude'
    say ''
    printf 'Target path: '
    read -r TARGET
fi
PARENT=$(dirname "$TARGET")
TEXISTS=0; [ -e "$TARGET" ] && TEXISTS=1
TCOUNT=0
[ "$TEXISTS" -eq 1 ] && TCOUNT=$(ls -A "$TARGET" 2>/dev/null | wc -l | tr -d ' ')
PEXISTS=0; [ -d "$PARENT" ] && PEXISTS=1
WHY=$(target_problem "$SOURCE" "$TARGET" "$TEXISTS" "$TCOUNT" "$PEXISTS")
if [ -n "$WHY" ]; then
    note "cannot use that target: $WHY"
    # say how to fix the commonest one (J6): the folder the target goes in must exist first
    [ "$PEXISTS" -eq 0 ] && note "create it first:   mkdir -p \"$PARENT\""
    exit 1
fi

# --- 4. the plan
# Same reason as in manifest(): wc -c rather than stat, so no platform branch is needed.
BYTES=$(find "$SOURCE" -type f -exec wc -c {} + 2>/dev/null | awk '$2!="total"{s+=$1} END{printf "%d", s+0}')
FILES=$(find "$SOURCE" -type f | wc -l | tr -d ' ')
say 'Plan'
note "move   : $SOURCE"
note "to     : $TARGET"
note "size   : $(human "$BYTES") in $FILES files"
note "link   : $SOURCE -> $TARGET  (symbolic link, no administrator needed)"
say ''

# ⚠ A filesystem without Unix permissions cannot hold this safely.
MOUNT=$(df -P "$PARENT" 2>/dev/null | awk 'NR==2{print $NF}')
if [ -n "$MOUNT" ]; then
    # ⛔ `mount` PRINTS DIFFERENT SHAPES AND ONE OF THEM LIES IF READ NAIVELY.
    #   macOS:     /dev/disk3s5 on / (apfs, local, journaled)      <- fs type is in the ()
    #   Git Bash:  C:/... on /tmp type ntfs (binary,noacl,...)     <- the () holds OPTIONS
    # Measured 2026-10-19: taking the first parenthesised word on Git Bash reported the
    # filesystem as "binary". So look for an explicit `type <fs>` token FIRST, fall back to
    # the parenthesised word, and when neither yields something plausible say so rather
    # than printing a confident wrong answer.
    _line=$(mount 2>/dev/null | awk -v m="$MOUNT" '$3==m || $NF==m {print; exit}')
    FS=$(printf '%s' "$_line" | sed -n 's/.*[[:space:]]type[[:space:]]\([a-zA-Z0-9_]*\).*/\1/p')
    [ -n "$FS" ] || FS=$(printf '%s' "$_line" | sed -n 's/.*(\([a-zA-Z0-9_]*\).*/\1/p')
    case "$FS" in
        exfat|msdos|vfat|ntfs|fuseblk)
            note "⚠ the target is on $FS, which has no Unix permissions and cannot hold"
            note '  symlinks reliably; SQLite databases can corrupt there. Use APFS or HFS+.'
            exit 1 ;;
        apfs|hfs|smbfs|afpfs)
            note "target filesystem: $FS on $MOUNT" ;;
        *)
            note "target filesystem: could NOT be determined for $MOUNT (mount said: ${FS:-nothing})"
            note '  ⚠ Check yourself that it is APFS or HFS+, not exFAT or FAT32.' ;;
    esac
    # ⛔ The header says ownership must be honoured; this is where that is enforced (J1).
    # With it ignored, every file reads as owned by whoever looks, and the permissions on
    # ~/.claude - settings, session history, plugin code - stop protecting anything.
    if mount_noowners "$_line"; then
        note "⚠ $MOUNT IGNORES OWNERSHIP (mounted noowners): file permissions are not enforced there."
        note '  Turn it off first: Finder > select the disk > File > Get Info > Sharing & Permissions >'
        note '  untick "Ignore ownership on this volume". Then run this again.'
        if [ "$DRY_RUN" -ne 1 ]; then exit 1; fi
        WOULD_REFUSE="$WOULD_REFUSE noowners"
    fi
fi
say ''

if [ "$DRY_RUN" -eq 1 ]; then
    note '--dry-run: nothing was changed.'
    if [ -n "$WOULD_REFUSE" ]; then
        note "a real run would refuse now (${WOULD_REFUSE# }) - see the ⚠ lines above."
        exit 1
    fi
    note 'a real run would go ahead.'
    exit 0
fi

printf 'Type MOVE to go ahead (anything else cancels): '
read -r ANSWER
if [ "$ANSWER" != "MOVE" ]; then note 'cancelled - nothing was changed.'; exit 1; fi

# --- 5. copy. ditto preserves macOS metadata (resource forks, ACLs); cp -a is the fallback.
say ''
say '== Copying'
mkdir -p "$TARGET"
if command -v ditto >/dev/null 2>&1; then
    ditto "$SOURCE" "$TARGET" || { note 'ditto failed. Nothing was deleted.'; exit 2; }
    note 'copied with ditto'
else
    cp -a "$SOURCE/." "$TARGET/" || { note 'cp -a failed. Nothing was deleted.'; exit 2; }
    note 'copied with cp -a'
fi

# --- 6. verify before anything is destroyed
say ''
say '== Checking the copy matches'
MA=$(manifest "$SOURCE")
MB=$(manifest "$TARGET")
if [ "$MA" != "$MB" ]; then
    note 'the copy does NOT match the source. Nothing was deleted.'
    printf '%s\n' "$MA" > /tmp/junction-src.$$ 2>/dev/null || true
    printf '%s\n' "$MB" > /tmp/junction-dst.$$ 2>/dev/null || true
    diff /tmp/junction-src.$$ /tmp/junction-dst.$$ 2>/dev/null | head -10 | while IFS= read -r l; do note "$l"; done
    rm -f /tmp/junction-src.$$ /tmp/junction-dst.$$
    note "Remove the partial copy at $TARGET yourself, then try again."
    exit 2
fi
note "$FILES files, $(human "$BYTES") - every path and every size matches"

# --- 7. rename the original out of the way (NOT delete)
BACKUP="${SOURCE}.old-$(date +%Y%m%d%H%M%S)"
say ''
say '== Putting the link in place'
if ! mv "$SOURCE" "$BACKUP"; then
    note "could not rename $SOURCE - something still has it open. Nothing was deleted;"
    note "the copy at $TARGET can be removed."
    exit 2
fi
note "original renamed to $BACKUP"

# --- 8. the link, with a way back
if ! ln -s "$TARGET" "$SOURCE"; then
    note 'could not create the symlink.'
    if mv "$BACKUP" "$SOURCE"; then
        note 'ROLLED BACK: the original folder is back under its own name. Nothing was lost.'
    else
        note "⚠ COULD NOT RESTORE. Your data is in $BACKUP and $TARGET; rename the first back."
    fi
    exit 2
fi
note "symlink created: $SOURCE -> $TARGET"

# --- 9. prove it reads back
#
# ⛔ THE ROLLBACK MUST NOT BE ABLE TO FAIL HALFWAY, AND THE FIRST VERSION COULD.
# It ran `rm -f "$SOURCE"` then `mv "$BACKUP" "$SOURCE"` under `set -e`. Measured
# 2026-10-19 in a sandbox: when `ln -s` succeeded but produced a DIRECTORY rather than a
# link (which is what Git Bash does without winsymlinks, and what any filesystem that
# cannot hold symlinks would do), `rm -f` refused with "Is a directory", `set -e` killed
# the script THERE, and the restoring `mv` never ran - leaving no ~/.claude at all under
# its proper name. The data was still in two places, but the user would have found their
# config gone. So: never delete in a rollback, move aside; and `|| true` every step so the
# restore always runs.
rollback() {
    _why=$1
    note "$_why ROLLING BACK."
    if [ -L "$SOURCE" ]; then
        rm -f "$SOURCE" || true                      # a link: removes the link only
    elif [ -e "$SOURCE" ]; then
        mv "$SOURCE" "${SOURCE}.failed-$(date +%Y%m%d%H%M%S)" || true
    fi
    if mv "$BACKUP" "$SOURCE"; then
        note 'The original folder is back under its own name. Nothing was lost.'
    else
        note "⚠ COULD NOT RESTORE AUTOMATICALLY. Your data is safe in TWO places:"
        note "   $BACKUP   (the original)"
        note "   $TARGET   (the copy)"
        note "Rename the first back to $SOURCE by hand."
    fi
    exit 2
}

MC=$(manifest "$SOURCE")
if [ ! -L "$SOURCE" ]; then
    rollback 'what was created is NOT a symbolic link - this filesystem cannot hold one.'
fi
if [ "$MA" != "$MC" ]; then
    rollback 'the link does not read back the same files.'
fi
note "reads back through the link: $FILES files, all matching"

# --- 10. now, and only now, the original goes
#
# ⛔ ONE LAST COMPARISON FIRST (J5). Anything written to the source between the check in
# step 6 and the rename in step 7 landed in the RENAMED original, not in the copy - and
# deleting the original would throw it away without a word. So the original is compared
# with the copy once more; on any difference it is KEPT and the differences are named.
MD=$(manifest "$BACKUP")
MT=$(manifest "$TARGET")
if [ "$MD" != "$MT" ]; then
    say ''
    note '⚠ the original CHANGED after it was checked - something wrote to it during the move.'
    note "It is KEPT at $BACKUP; the link to $TARGET is in place and works."
    note 'What differs (< original, > copy):'
    printf '%s\n' "$MD" > "${TMPDIR:-/tmp}/junction-orig.$$"
    printf '%s\n' "$MT" > "${TMPDIR:-/tmp}/junction-copy.$$"
    diff "${TMPDIR:-/tmp}/junction-orig.$$" "${TMPDIR:-/tmp}/junction-copy.$$" | grep '^[<>]' | head -20 | while IFS= read -r l; do note "   $l"; done || true
    rm -f "${TMPDIR:-/tmp}/junction-orig.$$" "${TMPDIR:-/tmp}/junction-copy.$$"
    note 'Copy anything you need from the original into the target, then delete the original.'
    exit 2
fi

say ''
if [ "$KEEP_BACKUP" -eq 1 ]; then
    note "--keep-backup: the original is still at $BACKUP"
    note "It is using $(human "$BYTES"). Delete it when you are satisfied."
else
    say '== Removing the original copy'
    rm -rf "$BACKUP"
    if [ -e "$BACKUP" ]; then
        note "could not fully remove $BACKUP - delete it by hand."
        note 'This is cosmetic: the link is in place and working.'
    else
        note 'the original copy is gone'
    fi
fi

say ''
note 'Done.'
note "$SOURCE is now a symlink to $TARGET"
note 'Every tool keeps using the old path and does not need to know anything changed.'
say ''
note 'To undo it later: quit Claude Code, then'
note "   rm \"$SOURCE\"                     <- removes the LINK only, never rm -rf"
note "   ditto \"$TARGET\" \"$SOURCE\""
say ''
exit 0
