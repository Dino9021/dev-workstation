#!/bin/sh
# install.sh - one-shot workstation installer for this repository, macOS.
#
# The macOS sibling of install.ps1 (Windows). Same goal, same end state, written in POSIX
# sh with only what macOS ships (/bin/sh, curl, /usr/bin/jq) - the owner's decision of
# 2026-10-15, recorded in Memory/tasks/20261015-194453-os-detect/ADR-macos-sh-installer.md.
# install.ps1 is not involved here and is never called from here: on a Mac it refuses with
# exit 2.
#
# Usage (a fresh Mac - download THIS FILE ALONE, then run it; not `curl | sh`, which takes
# away the terminal the questions and the Homebrew installer need):
#     curl -fsSLo install.sh https://raw.githubusercontent.com/Dino9021/dev-workstation/main/install.sh
#     sh install.sh
#
#     sh install.sh --check-only     report what is present and what is missing; writes nothing
#     sh install.sh --self-test      offline tests of the pure functions; writes nothing
#
# STAGE 1 (2026-10-15): detection, the tool table, --check-only and --self-test. A plain
# run says what it WOULD do and stops; the installing phases land in later commits.
#
# The whole body is inside functions and the last line calls main, so a download cut off
# half way is a syntax error - never half a run.

# --------------------------------------------------------------------- the tool table
#
# BEGIN-DEPS - parity-checked against install.ps1's $DEPS by Tools/parity-check.sh.
# One row per tool: name|route|sudo|optional|why
#   name      the SAME name install.ps1 uses for the same tool, so the parity check can
#             compare the two lists; a macOS-only row gets its own name and an entry in the
#             parity check's exception list
#   route     how it is installed on macOS
#   sudo      yes = needs an administrator password once
#   optional  yes = a run that cannot elevate skips it and says so
unset CDPATH   # with CDPATH exported, `cd x && pwd` prints two lines (review agent-04, F9)

DEPS_TABLE='
git|xcode-clt|no|no|Git, from the Xcode Command Line Tools
homebrew|vendor-script|yes|no|Homebrew at /opt/homebrew - GitNexus links its openssl@3 by absolute path
openssl3|brew|no|no|openssl@3 for GitNexus (its database binary links /opt/homebrew/opt/openssl@3)
vscode|vendor-zip|no|no|Visual Studio Code, into /Applications
node|vendor-tarball|no|no|Node.js LTS, user scope (GitNexus and claude-mem install through npm)
python|uv|no|no|Python, user scope through uv (code-review-graph is a Python tool)
uv|vendor-script|no|no|uv, Astral'"'"'s Python manager
claude|vendor-script|no|no|Claude Code
'
# END-DEPS

# BEGIN-PLUGINS - parity-checked against install.ps1's $PLUGINS. name|source|market|plugin
PLUGINS_TABLE='
dispatch-guard|Dino9021/dispatch-guard|dispatch-guard|dispatch-guard
mattpocock-skills|mattpocock/skills|mattpocock|mattpocock-skills
'
# END-PLUGINS

# --------------------------------------------------------------------- pure functions
# No machine access in this section: --self-test drives every branch with made-up inputs.

# platform_verdict UNAME_S -> macos | refuse:<what it is>
platform_verdict() {
    case $1 in
        Darwin) echo macos ;;
        Linux) echo 'refuse:Linux' ;;
        MINGW*|MSYS*|CYGWIN*) echo 'refuse:Windows' ;;
        '') echo 'refuse:unknown' ;;
        *) echo "refuse:$1" ;;
    esac
}

# normalise_arch RAW -> x64 | arm64 | x86 | unnormalised(RAW)   (same vocabulary as
# detect-os-w1.ps1's Get-NormalisedArch, so both platforms report one word per chip)
normalise_arch() {
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
        amd64|x64|x86_64) echo x64 ;;
        arm64|aarch64) echo arm64 ;;
        x86|i386|i686) echo x86 ;;
        *) echo "unnormalised($1)" ;;
    esac
}

# in_group GROUP "GROUPS..." -> exit 0 when GROUP is one of the space-separated words
in_group() {
    case " $2 " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# privilege_verdict UID "GROUPS" -> root | can-elevate | standard
#   root         refused: Homebrew itself refuses to run as root, and files made by root in
#                the user's home break later runs
#   can-elevate  a member of admin: the sudo rows can be done, one password, asked up front
#   standard     the sudo rows are skipped (optional) or block (required), named at the start
privilege_verdict() {
    if [ "$1" = 0 ]; then echo root; return; fi
    if in_group admin "$2"; then echo can-elevate; return; fi
    echo standard
}

# version_ge HAVE WANT -> exit 0 when dotted version HAVE >= WANT (numeric fields only)
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

# table_names TABLE -> the first field of every row, one per line
table_names() {
    printf '%s\n' "$1" | while IFS='|' read -r name _rest; do
        [ -n "$name" ] && echo "$name"
    done
}

# table_field TABLE NAME FIELDNO -> one field of one row
table_field() {
    printf '%s\n' "$1" | awk -F'|' -v n="$2" -v f="$3" '$1 == n { print $f; exit }'
}

# --------------------------------------------------------------------- the machine
# Everything that reads the live machine is here, and only here.

brew_bin() {
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$b" ]; then echo "$b"; return 0; fi
    done
    return 1
}

# probe NAME -> prints a version or location and exits 0 when present; exits 1 when absent
probe() {
    case $1 in
        git)
            # /usr/bin/git is a shim that pops up an installer dialog when the Command Line
            # Tools are missing - ask xcode-select first, never run the shim blind.
            xcode-select -p >/dev/null 2>&1 || return 1
            git --version 2>/dev/null | sed 's/^git version //' ;;
        homebrew)
            b=$(brew_bin) || return 1
            echo "$b" ;;
        openssl3)
            b=$(brew_bin) || return 1
            [ -d "$("$b" --prefix)/opt/openssl@3" ] || return 1
            echo "$("$b" --prefix)/opt/openssl@3" ;;
        vscode)
            for a in "${DW_APPLICATIONS:-/Applications}/Visual Studio Code.app" "$HOME/Applications/Visual Studio Code.app"; do
                if [ -d "$a" ]; then echo "$a"; return 0; fi
            done
            return 1 ;;
        node)
            command -v node >/dev/null 2>&1 || return 1
            v=$(node --version 2>/dev/null) || return 1
            echo "${v#v}" ;;
        python)
            # /usr/bin/python3 does NOT count: it is the Command Line Tools' own (3.9.6 on
            # macOS 27, measured 2026-10-15 - below the 3.10 the graph servers need), always
            # there, and nobody chose it. Any OTHER python on PATH is the user's choice and
            # counts as present; the graph-servers phase enforces its minimum, as on Windows.
            p=''
            for c in $(command -v -a python3 python 2>/dev/null; which -a python3 python 2>/dev/null); do
                case $c in /usr/bin/*) ;; *) p=$c; break ;; esac
            done
            [ -n "$p" ] || return 1
            "$p" --version 2>&1 | sed 's/^Python //' ;;
        uv)
            command -v uv >/dev/null 2>&1 || return 1
            uv --version 2>/dev/null | awk '{print $2}' ;;
        claude)
            command -v claude >/dev/null 2>&1 || return 1
            claude --version 2>/dev/null | awk '{print $1}' ;;
        *)
            echo "probe: no probe for $1" >&2
            return 2 ;;
    esac
}

# --------------------------------------------------------------------- phases

say() { printf '%s\n' "$*"; }
phase() { printf '\n===== %s =====\n' "$*"; }

detect_environment() {
    os_raw=$(uname -s)
    verdict=$(platform_verdict "$os_raw")
    case $verdict in
        refuse:*)
            say "install.sh is the macOS installer; this host is ${verdict#refuse:}."
            say "On Windows run install.ps1 instead - see README.md."
            exit 2 ;;
    esac
    arch=$(normalise_arch "$(uname -m)")
    macos_version=$(sw_vers -productVersion 2>/dev/null)
    priv=$(privilege_verdict "$(id -u)" "$(id -Gn)")
    say "host        : macOS $macos_version, $arch"
    say "privilege   : $priv"
    if [ "$priv" = root ]; then
        say "Do not run install.sh as root or with sudo: Homebrew refuses root, and files created"
        say "as root in your home folder break every later run. Run it as yourself; it asks for"
        say "the administrator password itself, once, for the rows that need it."
        exit 2
    fi
    if [ ! -x /usr/bin/jq ]; then
        say "/usr/bin/jq is missing. This installer edits ~/.claude/settings.json with the jq"
        say "that macOS ships; it was found on macOS 27.0.1 and the first release that shipped it"
        say "is not known. Update macOS, or report this macOS version."
        exit 2
    fi
}

check_toolchain() {
    phase 'Toolchain'
    missing=''
    for name in $(table_names "$DEPS_TABLE"); do
        if found=$(probe "$name"); then
            printf '  ok       %-10s %s\n' "$name" "$found"
        else
            sudo_=$(table_field "$DEPS_TABLE" "$name" 4)
            printf '  MISSING  %-10s %s\n' "$name" "$(table_field "$DEPS_TABLE" "$name" 5)"
            missing="$missing $name"
        fi
    done
    missing=${missing# }
}

# --------------------------------------------------------------------- installing
#
# Every tool goes into the user's own home unless the table says sudo: nothing here writes
# outside $HOME except VS Code into /Applications (writable by the admin group, no sudo)
# and the rows marked sudo. Each installer is downloaded to a file first and verified where
# the vendor publishes a checksum; nothing is piped from the network into a shell.

DW_SHARE=$HOME/.local/share/dev-workstation
DW_BIN=$HOME/.local/bin
PROFILE_BEGIN='# >>> dev-workstation (install.sh) >>>'
PROFILE_END='# <<< dev-workstation (install.sh) <<<'

work_dir=''
make_work_dir() {
    [ -n "$work_dir" ] && return 0
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dev-workstation-install.XXXXXX") || return 1
    trap 'rm -rf "$work_dir"' EXIT
}

# fetch URL FILE - download, failing on any HTTP error
fetch() {
    curl -fsSL --retry 2 --connect-timeout 20 -o "$2" "$1"
}

# profile_block -> the lines install.sh keeps in ~/.zprofile, between its own markers
profile_block() {
    printf '%s\n' "$PROFILE_BEGIN"
    printf '%s\n' '# Written by dev-workstation install.sh; a re-run recognises these markers.'
    printf '%s\n' 'export PATH="$HOME/.local/bin:$HOME/.local/share/dev-workstation/node/bin:$PATH"'
    printf '%s\n' '[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"'
    printf '%s\n' 'export GITNEXUS_LBUG_EXTENSION_INSTALL=auto'
    printf '%s\n' "$PROFILE_END"
}

# ensure_profile FILE - add the block once; a file that already has the begin marker, or the
# hand-ported PATH line of 2026-10-14, is left exactly as it is
ensure_profile() {
    f=$1
    if [ -f "$f" ] && grep -qF "$PROFILE_BEGIN" "$f"; then return 0; fi
    if [ -f "$f" ] && grep -qF '.local/share/dev-workstation/node/bin' "$f"; then
        say "  $f already puts the toolchain on PATH (set up by hand) - left as it is"
        return 0
    fi
    if ! { { [ -s "$f" ] && printf '\n'; profile_block; } >>"$f"; } 2>/dev/null; then
        say "  COULD NOT write $f - add these lines yourself:"; profile_block | sed 's/^/    /'
        return 1
    fi
    say "  added the PATH block to $f"
}

# this run must see what it installs, without waiting for a new login shell
use_toolchain_path() {
    PATH=$DW_BIN:$DW_SHARE/node/bin:$PATH
    b=$(brew_bin) && PATH=$(dirname "$b"):$PATH
    export PATH
}

install_git() {
    # The Command Line Tools carry git. Apple offers them only through a dialog; the run
    # waits for it, up to 30 minutes, and says so.
    xcode-select --install >/dev/null 2>&1
    say '  A macOS dialog asks to install the Command Line Tools: click Install.'
    say '  Waiting for it to finish (up to 30 minutes)...'
    i=0
    while [ $i -lt 360 ]; do
        xcode-select -p >/dev/null 2>&1 && return 0
        sleep 5; i=$((i + 1))
    done
    say '  The Command Line Tools did not appear within 30 minutes.'
    return 1
}

install_vscode() {
    dest=${DW_APPLICATIONS:-/Applications}
    [ -w "$dest" ] || dest=$HOME/Applications
    mkdir -p "$dest" "$DW_BIN" || return 1
    make_work_dir || return 1
    say "  downloading VS Code (universal) ..."
    fetch 'https://update.code.visualstudio.com/latest/darwin-universal/stable' "$work_dir/vscode.zip" || return 1
    ditto -x -k "$work_dir/vscode.zip" "$work_dir/vscode" || return 1
    [ -d "$work_dir/vscode/Visual Studio Code.app" ] || { say '  the archive holds no Visual Studio Code.app'; return 1; }
    rm -rf "$dest/Visual Studio Code.app"
    mv "$work_dir/vscode/Visual Studio Code.app" "$dest/" || return 1
    ln -sf "$dest/Visual Studio Code.app/Contents/Resources/app/bin/code" "$DW_BIN/code"
    say "  installed into $dest"
}

# node_platform ARCH -> the nodejs.org file-name platform, or nothing for an unsupported arch
node_platform() {
    case $1 in
        arm64) echo darwin-arm64 ;;
        x64) echo darwin-x64 ;;
        *) echo '' ;;
    esac
}

install_node() {
    plat=$(node_platform "$arch")
    [ -n "$plat" ] || { say "  no Node.js build for $arch"; return 1; }
    make_work_dir || return 1
    fetch 'https://nodejs.org/dist/index.json' "$work_dir/node-index.json" || return 1
    ver=$(/usr/bin/jq -r '[.[] | select(.lts != false)][0].version' "$work_dir/node-index.json")
    case $ver in v[0-9]*) ;; *) say "  could not read the current LTS from nodejs.org"; return 1 ;; esac
    tarname=node-$ver-$plat
    say "  downloading $tarname ..."
    fetch "https://nodejs.org/dist/$ver/$tarname.tar.gz" "$work_dir/$tarname.tar.gz" || return 1
    fetch "https://nodejs.org/dist/$ver/SHASUMS256.txt" "$work_dir/SHASUMS256.txt" || return 1
    want=$(awk -v f="$tarname.tar.gz" '$2 == f { print $1 }' "$work_dir/SHASUMS256.txt")
    have=$(shasum -a 256 "$work_dir/$tarname.tar.gz" | awk '{ print $1 }')
    if [ -z "$want" ] || [ "$want" != "$have" ]; then
        say "  checksum mismatch for $tarname.tar.gz (want '$want', got '$have') - not installed"
        return 1
    fi
    mkdir -p "$DW_SHARE" || return 1
    tar -xzf "$work_dir/$tarname.tar.gz" -C "$DW_SHARE" || return 1
    ln -sfn "$DW_SHARE/$tarname" "$DW_SHARE/node"
    say "  installed $ver into $DW_SHARE/$name (checksum verified)"
}

install_uv() {
    make_work_dir || return 1
    fetch 'https://astral.sh/uv/install.sh' "$work_dir/uv-install.sh" || return 1
    # UV_NO_MODIFY_PATH: the PATH is this script's block in ~/.zprofile, written once.
    UV_NO_MODIFY_PATH=1 sh "$work_dir/uv-install.sh" || return 1
}

install_python() {
    command -v uv >/dev/null 2>&1 || { say '  uv is needed first'; return 1; }
    # --default also places python and python3 in ~/.local/bin, as on this Mac by hand.
    uv python install 3.13 --default || return 1
}

install_claude() {
    make_work_dir || return 1
    fetch 'https://claude.ai/install.sh' "$work_dir/claude-install.sh" || return 1
    bash "$work_dir/claude-install.sh" || return 1
}

# homebrew_verdict STDIN_IS_TTY PRIV -> "ok", or why Homebrew cannot be installed now. Pure.
# Homebrew is the one row that needs the administrator password (owner, 2026-10-15: install
# it - GitNexus links /opt/homebrew/opt/openssl@3 by absolute path). Its installer only
# works with sudo already unlocked, and the password can only be typed at a terminal.
homebrew_verdict() {
    if [ "$2" != can-elevate ]; then echo 'this account is not an administrator (not in group admin)'; return; fi
    if [ "$1" != yes ]; then echo 'no terminal to type the administrator password into (run install.sh from Terminal)'; return; fi
    echo ok
}

install_homebrew() {
    tty=no; [ -t 0 ] && tty=yes
    v=$(homebrew_verdict "$tty" "$priv")
    if [ "$v" != ok ]; then say "  cannot install Homebrew: $v"; return 1; fi
    make_work_dir || return 1
    fetch 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' "$work_dir/brew-install.sh" || return 1
    say '  Homebrew installs into /opt/homebrew and needs your administrator password once:'
    sudo -v || { say '  sudo was not unlocked - Homebrew not installed'; return 1; }
    # NONINTERACTIVE: the password was just given to sudo, so its own prompts are not needed
    NONINTERACTIVE=1 /bin/bash "$work_dir/brew-install.sh" || return 1
}

install_openssl3() {
    b=$(brew_bin) || { say '  Homebrew is needed first'; return 1; }
    "$b" install openssl@3 || return 1
}

# install_row NAME -> runs that row's installer; 3 = deliberately not done (owner decision)
install_row() {
    case $1 in
        git) install_git ;;
        homebrew) install_homebrew ;;
        openssl3) install_openssl3 ;;
        vscode) install_vscode ;;
        node) install_node ;;
        uv) install_uv ;;
        python) install_python ;;
        claude) install_claude ;;
        *) say "  no installer for $1"; return 1 ;;
    esac
}

# The order rows are installed in: uv before python, which it installs.
INSTALL_ORDER='git homebrew openssl3 vscode node uv python claude'

uv_before_python() {
    # (a function, not a case inside $( ): bash 3.2 misparses the ')' of a case pattern there)
    case " $INSTALL_ORDER " in
        *' uv '*'python '*) return 0 ;;
        *) return 1 ;;
    esac
}

install_missing() {
    phase 'Installing what is missing'
    use_toolchain_path
    still=''; skipped=''
    for name in $INSTALL_ORDER; do
        case " $missing " in *" $name "*) ;; *) continue ;; esac
        say "- $name"
        if [ "$(table_field "$DEPS_TABLE" "$name" 3)" = yes ] && [ "$priv" != can-elevate ]; then
            say '  needs an administrator and this account cannot elevate - skipped'
            skipped="$skipped $name"; continue
        fi
        # in a subshell: an installer that reuses a variable name (install_node once used
        # $name) can never clobber this loop's - review agent-05, N1
        ( install_row "$name" ); rc=$?
        if [ $rc = 3 ]; then skipped="$skipped $name"; continue; fi
        use_toolchain_path
        if [ $rc = 0 ] && found=$(probe "$name"); then
            say "  ok: $found"
        else
            say "  FAILED"
            still="$still $name"
        fi
    done
    ensure_profile "$HOME/.zprofile"
    still=${still# }; skipped=${skipped# }
}

# --------------------------------------------------------------------- self-test

self_test() {
    pass=0; fail=0
    t() { if [ "$2" = 0 ]; then pass=$((pass + 1)); say "  PASS  $1"; else fail=$((fail + 1)); say "  FAIL  $1"; fi; }
    is() { [ "$1" = "$2" ]; echo $?; }
    say 'install.sh self-test'

    t 'platform: Darwin is macos' "$(is "$(platform_verdict Darwin)" macos)"
    t 'platform: Linux refused' "$(is "$(platform_verdict Linux)" refuse:Linux)"
    t 'platform: Git Bash on Windows refused as Windows' "$(is "$(platform_verdict MINGW64_NT-10.0)" refuse:Windows)"
    t 'platform: empty refused' "$(is "$(platform_verdict '')" refuse:unknown)"

    t 'arch: arm64' "$(is "$(normalise_arch arm64)" arm64)"
    t 'arch: x86_64 is x64' "$(is "$(normalise_arch x86_64)" x64)"
    t 'arch: AMD64 is x64' "$(is "$(normalise_arch AMD64)" x64)"
    t 'arch: aarch64 is arm64' "$(is "$(normalise_arch aarch64)" arm64)"
    t 'arch: unknown is flagged, not passed through' "$(is "$(normalise_arch sparc)" 'unnormalised(sparc)')"

    t 'privilege: uid 0 is root even in admin' "$(is "$(privilege_verdict 0 'staff admin')" root)"
    t 'privilege: admin member can elevate' "$(is "$(privilege_verdict 501 'staff everyone admin _lpadmin')" can-elevate)"
    t 'privilege: _lpadmin alone is not admin' "$(is "$(privilege_verdict 501 'staff _lpadmin')" standard)"
    t 'privilege: no admin group is standard' "$(is "$(privilege_verdict 502 'staff everyone')" standard)"

    t 'version: 24.21.0 >= 22' "$(version_ge 24.21.0 22; echo $?)"
    t 'version: 22.0.0 >= 22.0.0' "$(version_ge 22.0.0 22.0.0; echo $?)"
    t 'version: 20.9.0 < 22' "$(! version_ge 20.9.0 22; echo $?)"
    t 'version: 3.9.6 < 3.10 (numeric, not string)' "$(! version_ge 3.9.6 3.10; echo $?)"
    t 'version: 3.13.16 >= 3.10' "$(version_ge 3.13.16 3.10; echo $?)"

    names=$(table_names "$DEPS_TABLE" | tr '\n' ' ')
    t "table: DEPS rows are exactly {$names}" \
        "$(is "$names" 'git homebrew openssl3 vscode node python uv claude ')"
    t 'table: every DEPS row has five fields' \
        "$(printf '%s\n' "$DEPS_TABLE" | awk -F'|' 'NF && NF != 5 { bad = 1 } END { exit bad }'; echo $?)"
    t 'table: every DEPS row has a probe' \
        "$(for n in $(table_names "$DEPS_TABLE"); do probe "$n" >/dev/null 2>&1; [ $? = 2 ] && exit 1; done; echo 0)"
    t 'table: sudo rows are exactly {homebrew}' \
        "$(is "$(printf '%s\n' "$DEPS_TABLE" | awk -F'|' '$3 == "yes" { print $1 }' | tr '\n' ' ')" 'homebrew ')"
    t 'table: PLUGINS rows' \
        "$(is "$(table_names "$PLUGINS_TABLE" | tr '\n' ' ')" 'dispatch-guard mattpocock-skills ')"
    t 'table_field: route of node' "$(is "$(table_field "$DEPS_TABLE" node 2)" vendor-tarball)"
    t 'install order covers exactly the table' \
        "$(is "$(printf '%s\n' $INSTALL_ORDER | sort | tr '\n' ' ')" "$(table_names "$DEPS_TABLE" | sort | tr '\n' ' ')")"
    t 'install order: uv before python' "$(uv_before_python; echo $?)"

    r=$(install_row() { name=clobbered; return 0; }; probe() { [ "$1" = node ] && echo ok; }
        use_toolchain_path() { :; }; ensure_profile() { :; }
        missing=node; priv=can-elevate; install_missing >/dev/null 2>&1; echo "[$still]")
    t 'install loop: an installer that clobbers $name cannot turn a good install into FAILED' "$(is "$r" '[]')"

    t 'homebrew: an administrator at a terminal may install it' "$(is "$(homebrew_verdict yes can-elevate)" ok)"
    t 'homebrew: no terminal means no password - refused with the reason' "$(homebrew_verdict no can-elevate | grep -q 'no terminal'; echo $?)"
    t 'homebrew: a standard account is refused with the reason' "$(homebrew_verdict yes standard | grep -q 'not an administrator'; echo $?)"
    t 'homebrew: root is refused (Homebrew refuses root itself)' "$([ "$(homebrew_verdict yes root)" != ok ]; echo $?)"

    t 'node platform: arm64' "$(is "$(node_platform arm64)" darwin-arm64)"
    t 'node platform: x64' "$(is "$(node_platform x64)" darwin-x64)"
    t 'node platform: x86 has none' "$(is "$(node_platform x86)" '')"

    t 'update: a clean clone at its own top level may be pulled' "$(is "$(update_verdict /w/dw /w/dw '')" '')"
    t 'update: a ZIP copy (no work tree) is not pulled' "$(update_verdict /w/dw '' '' | grep -q 'not a git work tree'; echo $?)"
    t 'update: a copy inside another repository is not pulled' "$(update_verdict /w/proj/dw /w/proj '' | grep -q 'INSIDE another'; echo $?)"
    t 'update: uncommitted tracked changes block the pull' "$(update_verdict /w/dw /w/dw ' M install.sh' | grep -q 'uncommitted'; echo $?)"
    t 'update: a trailing slash is not a different directory' "$(is "$(update_verdict /w/dw/ /w/dw '')" '')"

    st=$(mktemp -d "${TMPDIR:-/tmp}/install-selftest.XXXXXX")
    printf 'export FOO=1\n' >"$st/zp"
    ensure_profile "$st/zp" >/dev/null; ensure_profile "$st/zp" >/dev/null
    t 'profile: block added exactly once on a re-run' "$(is "$(grep -cF "$PROFILE_BEGIN" "$st/zp")" 1)"
    t 'profile: the existing line is kept' "$(grep -qx 'export FOO=1' "$st/zp"; echo $?)"
    t 'profile: block closes' "$(is "$(grep -cF "$PROFILE_END" "$st/zp")" 1)"
    printf 'export PATH="$HOME/.local/bin:$HOME/.local/share/dev-workstation/node/bin:$PATH"\n' >"$st/hand"
    ensure_profile "$st/hand" >/dev/null
    t 'profile: a hand-made PATH line is left alone' "$(is "$(grep -cF "$PROFILE_BEGIN" "$st/hand")" 0)"
    printf '# read-only\n' >"$st/ro"; chmod 444 "$st/ro"
    ensure_profile "$st/ro" >"$st/ro.out" 2>&1; rc=$?
    t 'profile: an unwritable file is reported as NOT written, not as added' \
        "$([ $rc = 1 ] && grep -q 'COULD NOT write' "$st/ro.out" && ! grep -q 'added the PATH block' "$st/ro.out"; echo $?)"
    chmod 644 "$st/ro"
    ensure_profile "$st/new" >/dev/null
    t 'profile: a missing file is created with the block' "$(is "$(head -n 1 "$st/new")" "$PROFILE_BEGIN")"
    rm -rf "$st"

    say ''
    say "  $pass PASS  $fail FAIL"
    [ "$fail" = 0 ]
}

# --------------------------------------------------------------------- the clone

# DW_REPO_URL overrides the source for testing the bootstrap against a local repository.
REPO_URL=${DW_REPO_URL:-https://github.com/Dino9021/dev-workstation.git}
CLONE_DIR=$HOME/WorkSpace/dev-workstation

# is_clone DIR -> a copy of this repository (ZIP or git): it holds Tools/deploy.py
is_clone() { [ -f "$1/Tools/deploy.py" ] && [ -f "$1/install.sh" ]; }

# update_verdict DIR TOPLEVEL PORCELAIN -> nothing when DIR may be fast-forwarded, else why not.
# Pure, for the self-test. The same three rules as install.ps1's Test-UpdatableClone:
# a ZIP copy has no work tree; a copy INSIDE another repository would pull THAT one; and a
# tree with uncommitted tracked changes is never pulled under somebody who is editing it.
update_verdict() {
    if [ -z "$2" ]; then echo 'it is not a git work tree (a ZIP copy has no .git)'; return; fi
    if [ "${2%/}" != "${1%/}" ]; then echo "it sits INSIDE another repository ($2) - pulling would update that one"; return; fi
    if [ -n "$3" ]; then echo 'tracked files in the working tree have uncommitted changes'; return; fi
}

bootstrap() {
    # This file was downloaded on its own: get git, clone, and hand over to the clone's copy.
    phase 'Bootstrap: git, then the repository'
    if is_clone "$CLONE_DIR"; then
        say "  using the existing copy at $CLONE_DIR"
    else
        if [ -e "$CLONE_DIR" ]; then
            say "  $CLONE_DIR exists but is not a copy of this repository - not touching it."
            say "  Move it aside, or clone by hand: git clone $REPO_URL \"$CLONE_DIR\""
            exit 1
        fi
        if [ "$mode" = check ]; then
            say "  a real run would clone $REPO_URL into $CLONE_DIR, then continue from there"
            # still report the toolchain - the usage line promises it (review agent-05, N4)
            check_toolchain
            say ''
            if [ -n "$missing" ]; then say "a real run would install: $missing"; else say 'toolchain: nothing missing'; fi
            say 'CHECK ONLY: nothing was installed or written.'
            exit 0
        fi
        probe git >/dev/null 2>&1 || install_git || { say '  git is not available - stopping'; exit 1; }
        mkdir -p "$(dirname "$CLONE_DIR")" || exit 1
        git clone "$REPO_URL" "$CLONE_DIR" || { say '  git clone failed - stopping'; exit 1; }
    fi
    say "  handing over to $CLONE_DIR/install.sh"
    exec /bin/sh "$CLONE_DIR/install.sh" "$@"
}

self_update() {
    phase 'Update'
    if [ "$no_update" = 1 ]; then update_note='skipped - --no-update'; say "  $update_note"; return 0; fi
    command -v git >/dev/null 2>&1 || { update_note='skipped - git is not installed yet'; say "  $update_note"; return 0; }
    top=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$top" ] && top=$(cd "$top" && pwd -P)
    porcelain=$(git -C "$here" status --porcelain --untracked-files=no 2>/dev/null)
    why=$(update_verdict "$(cd "$here" && pwd -P)" "$top" "$porcelain")
    if [ -n "$why" ]; then
        update_note="skipped - $why"; say "  $update_note"
        say "  to update by hand: git -C \"$here\" pull --ff-only"
        return 0
    fi
    if [ "$mode" = check ]; then update_note='not checked - --check-only never fetches'; say "  $update_note"; return 0; fi
    before=$(git -C "$here" rev-parse HEAD)
    self_before=$(shasum -a 256 <"$here/install.sh")
    if ! git -C "$here" pull --ff-only --quiet; then
        update_note='FAILED - git pull --ff-only refused (see above); continuing with this copy'
        say "  $update_note"; return 0
    fi
    after=$(git -C "$here" rev-parse HEAD)
    if [ "$before" = "$after" ]; then update_note='already up to date'; say "  $update_note"; return 0; fi
    update_note="updated $(printf '%s' "$before" | cut -c1-7) -> $(printf '%s' "$after" | cut -c1-7)"
    say "  $update_note"
    if [ "$(shasum -a 256 <"$here/install.sh")" != "$self_before" ]; then
        say ''
        say '  install.sh itself was updated. Nothing has been installed yet - run it again:'
        say "    sh \"$here/install.sh\""
        exit 0
    fi
}

ask_cowork() {
    # claude-mem Cowork streams tool use to cmem.ai, so it is never installed without a
    # decision. Asked once, here, before anything is installed. No terminal = no.
    [ -n "$cowork" ] && return 0
    if [ ! -t 0 ]; then cowork=no; return 0; fi
    say ''
    say 'claude-mem Cowork is the CLOUD half of claude-mem: its hooks stream tool use to cmem.ai.'
    say 'The local memory is installed either way. Install the cloud half too? [y/N] (30 s)'
    answer=''
    if [ -n "$BASH_VERSION" ]; then read -r -t 30 answer || answer=''; else read -r answer || answer=''; fi
    case $answer in y|Y|yes|YES|Yes) cowork=yes ;; *) cowork=no ;; esac
    say "  Cowork: $cowork"
}

user_python() {
    for c in $(which -a python3 python 2>/dev/null); do
        case $c in /usr/bin/*) ;; *) echo "$c"; return 0 ;; esac
    done
    return 1
}

VSCODE_EXTENSIONS='anthropic.claude-code'

vscode_extensions() {
    phase 'VS Code extensions'
    code_cmd=$(command -v code)
    [ -n "$code_cmd" ] || [ ! -x "$DW_BIN/code" ] || code_cmd=$DW_BIN/code
    if [ -z "$code_cmd" ]; then
        say "  VS Code's code command is not available - skipping. Later: code --install-extension $VSCODE_EXTENSIONS"
        return 0
    fi
    installed=$("$code_cmd" --list-extensions 2>/dev/null)
    for ext in $VSCODE_EXTENSIONS; do
        if printf '%s\n' "$installed" | grep -qxF "$ext"; then say "  $ext already installed for $(id -un) - left alone"; continue; fi
        if [ "$mode" = check ]; then say "  would run: code --install-extension $ext"; continue; fi
        "$code_cmd" --install-extension "$ext" 2>&1 | tail -n 2 | sed 's/^/    /'
        if "$code_cmd" --list-extensions 2>/dev/null | grep -qxF "$ext"; then say "  $ext installed for $(id -un)"
        else say "  $ext did NOT install"; ext_failed="$ext_failed $ext"; fi
    done
}

# claude_mem_state -> running | stopped | absent (asks npx only when ~/.claude-mem exists:
# otherwise npx would download the whole package to say it is not installed)
claude_mem_state() {
    [ -d "$HOME/.claude-mem" ] || { echo absent; return; }
    out=$(npx -y claude-mem status 2>&1)
    case $out in
        *'Worker is not running'*) echo stopped ;;
        *'Worker is running'*) echo running ;;
        *) echo absent ;;
    esac
}

claude_mem() {
    phase 'claude-mem'
    state=$(claude_mem_state)
    case $state in
        running)
            say '  already installed and the worker is running - left alone'
            say '  (re-running its installer would stop the worker mid-flight)' ;;
        stopped)
            say '  installed, but the worker is not running - starting it'
            npx -y claude-mem start 2>&1 | tail -n 2 | sed 's/^/    /' ;;
        *)
            say '  installing claude-mem (local worker; nothing is uploaded, data stays in ~/.claude-mem).'
            say '  If its installer asks about a cloud tier, choose the LOCAL option.'
            npx -y claude-mem install --provider claude --runtime worker 2>&1 | tail -n 6 | sed 's/^/    /'
            # non-interactive installs skip the autostart; without a worker nothing is captured
            npx -y claude-mem start 2>&1 | tail -n 2 | sed 's/^/    /' ;;
    esac
    claude plugin marketplace add thedotmack/claude-mem 2>&1 | tail -n 3 | sed 's/^/    /'
    if [ "$cowork" = yes ]; then
        say '  Cowork: yes - installing the cloud plugin'
        claude plugin install claude-mem-cowork@thedotmack 2>&1 | tail -n 3 | sed 's/^/    /'
    else
        say '  Cowork: no - claude-mem-cowork@thedotmack was NOT installed'
        say '  to add it later: sh install.sh --cowork yes'
    fi
    if [ "$(claude_mem_state)" = running ]; then say '  verified: worker is running'
    else say '  worker is NOT running - nothing is captured until it is. Diagnose: npx claude-mem doctor'; mem_failed=1; fi
}

# plugin_installed PLUGIN MARKET -> enabledPlugins has PLUGIN@... set to true AND the
# plugin cache holds a version directory (the key alone downloads nothing)
plugin_installed() {
    s=$HOME/.claude/settings.json
    [ -f "$s" ] || return 1
    /usr/bin/jq -e --arg p "$1@" '(.enabledPlugins // {}) | to_entries | any(.key | startswith($p)) and any(.[]; (.key | startswith($p)) and .value == true)' "$s" >/dev/null 2>&1 || return 1
    [ -n "$(ls -d "$HOME/.claude/plugins/cache/$2/$1"/*/ 2>/dev/null)" ]
}

plugins() {
    phase 'Claude Code plugins'
    printf '%s\n' "$PLUGINS_TABLE" | while IFS='|' read -r name source market plugin; do
        [ -n "$name" ] || continue
        if plugin_installed "$plugin" "$market"; then say "  $name: already installed (key + cache) - left alone"; continue; fi
        if [ "$mode" = check ]; then say "  would install $name: claude plugin marketplace add $source; claude plugin install $plugin@$market"; continue; fi
        say "  $name"
        claude plugin marketplace add "$source" 2>&1 | sed 's/^/    /'
        claude plugin install "$plugin@$market" 2>&1 | sed 's/^/    /'
        if [ "$name" = dispatch-guard ]; then
            "$py" "$here/Tools/deploy.py" --user --apply --with-dispatch-guard 2>&1 | sed 's/^/    /'
        fi
        if plugin_installed "$plugin" "$market"; then say '    verified: plugin key and cache are both present now'
        else say '    NOT installed - if the claude CLI is not logged in, check that first'; echo "$name" >>"$work_plugins"; fi
    done
}

# --------------------------------------------------------------------- main

usage() {
    say 'usage: sh install.sh [--check-only] [--self-test] [--no-update] [--pdg]'
    say '                     [--cowork yes|no] [--repo PATH]'
}

main() {
    mode=install; no_update=0; pdg=0; cowork=''; repo_arg=''; row=''
    # Parsed WITHOUT shift, so "$@" is still intact for the bootstrap's hand-over - a
    # re-split string would break a --repo path that holds a space.
    takes=''
    for a in "$@"; do
        case $takes in
            cowork) cowork=$a; takes=''; continue ;;
            repo) repo_arg=$a; takes=''; continue ;;
            row) row=$a; takes=''; continue ;;
        esac
        case $a in
            --check-only) mode=check ;;
            --self-test) mode=selftest ;;
            --no-update) no_update=1 ;;
            --pdg) pdg=1 ;;
            --cowork) takes=cowork ;;
            --repo) takes=repo ;;
            --install-row) mode=row; takes=row ;;
            -h|--help) usage; exit 0 ;;
            *) say "install.sh: unknown argument: $a"; usage; exit 2 ;;
        esac
    done
    [ -z "$takes" ] || { say "install.sh: --$takes needs a value"; exit 2; }
    case $cowork in ''|yes|no) ;; *) say '--cowork takes yes or no'; exit 2 ;; esac

    if [ "$mode" = selftest ]; then
        self_test
        exit $?
    fi

    here=$(cd "$(dirname "$0")" && pwd)

    phase 'Environment'
    detect_environment

    if [ "$mode" = row ]; then
        # one row's installer on its own - for testing a route against a sandbox HOME
        check_toolchain
        use_toolchain_path
        install_row "$row"; rc=$?
        use_toolchain_path
        if [ $rc = 0 ] && found=$(probe "$row"); then say "row $row: ok: $found"; exit 0; fi
        say "row $row: not installed (installer exit $rc)"
        exit 1
    fi

    is_clone "$here" || bootstrap "$@"

    repo=${repo_arg:-$here}
    self_update
    [ "$mode" = install ] && ask_cowork
    check_toolchain

    if [ "$mode" = install ] && [ -n "$missing" ]; then install_missing
    else still=''; skipped=''; [ "$mode" = install ] && ensure_profile "$HOME/.zprofile"; fi
    use_toolchain_path
    GITNEXUS_LBUG_EXTENSION_INSTALL=${GITNEXUS_LBUG_EXTENSION_INSTALL:-auto}; export GITNEXUS_LBUG_EXTENSION_INSTALL

    ext_failed=''
    vscode_extensions

    [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || { say "--repo $repo is not a git repository; the per-repo steps need one."; exit 1; }
    py=$(user_python) || py=''

    phase 'Preflight A: prerequisite versions (graph-servers/install.sh --check-only)'
    if ! sh "$here/graph-servers/install.sh" --check-only --repo "$repo"; then
        say ''
        if [ "$mode" = check ]; then
            say 'A prerequisite is missing or too old. --check-only installs nothing; a real run'
            say 'installs a MISSING tool first, then checks again.'
        else
            # Say what DID happen: the toolchain phase above has already run (review agent-05, N2)
            say 'A prerequisite is still missing or too old after the toolchain phase, so the steps'
            say 'from here on (CLAUDE.md files, graph servers, claude-mem, plugins) were NOT run.'
            say 'What the toolchain phase did install stays; re-running is safe and continues from it.'
            [ -n "$still" ] && say "These rows FAILED to install above:$still - their own messages say why."
            [ -n "$skipped" ] && say "These rows were skipped: $skipped"
            say 'A tool that is present but TOO OLD is never replaced: upgrade it yourself, then re-run.'
        fi
        exit 1
    fi

    phase 'Preflight B: the plan (Tools/deploy.py --check)'
    # NOT --with-graph-servers: on macOS that relay would call the Windows installer.
    "$py" "$here/Tools/deploy.py" --user --repo "$repo" || { say 'preflight failed - nothing was applied.'; exit 1; }

    if [ "$mode" = check ]; then
        phase 'Check only'
        say '  a real run would then: apply the CLAUDE.md files, run graph-servers/install.sh,'
        say '  install claude-mem (and ask about its cloud half, Cowork), and these plugins:'
        plugins
        say ''
        say 'CHECK ONLY: nothing was installed or written.'
        exit 0
    fi

    phase 'CLAUDE.md files (Tools/deploy.py --apply)'
    "$py" "$here/Tools/deploy.py" --user --repo "$repo" --apply || { say 'deploy.py failed - stopping before the graph servers.'; exit 1; }

    phase 'Graph servers (graph-servers/install.sh)'
    if [ "$pdg" = 1 ]; then sh "$here/graph-servers/install.sh" --repo "$repo" --pdg; else sh "$here/graph-servers/install.sh" --repo "$repo"; fi
    graph_rc=$?

    mem_failed=0
    claude_mem

    make_work_dir
    work_plugins=$work_dir/plugins-failed; : >"$work_plugins"
    plugins
    plugin_failed=$(tr '\n' ' ' <"$work_plugins")

    phase 'Summary'
    say "update     : $update_note"
    [ -n "$skipped" ] && say "skipped    : $skipped"
    [ -n "$still" ] && say "FAILED     : $still"
    [ -z "$skipped$still" ] && say 'toolchain  : complete'
    [ $graph_rc = 0 ] && say 'graph      : every step ok' || say 'graph      : a step FAILED - see its summary above'
    [ $mem_failed = 0 ] && say 'claude-mem : worker running' || say 'claude-mem : worker NOT running'
    [ -n "$plugin_failed" ] && say "plugins    : NOT installed: $plugin_failed" || say 'plugins    : installed'
    [ -n "$ext_failed" ] && say "extensions : NOT installed:$ext_failed"
    say ''
    say 'What only you can do:'
    say "  1. Fill the project template: $repo/CLAUDE.md has FILL slots; delete sections with nothing to say."
    say '  2. Open a new terminal (or: source ~/.zprofile) so the PATH takes effect.'
    say '  3. Start Claude Code in the project and run /context: both CLAUDE.md files should be listed.'
    [ "$pdg" = 1 ] || say '  4. Taint analysis (explain) and pdg_query need the PDG index: sh install.sh --pdg'
    [ -z "$still" ] && [ $graph_rc = 0 ] && [ -z "$plugin_failed" ]
}

main "$@"
