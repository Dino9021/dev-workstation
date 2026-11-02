#!/bin/sh
# reply-language/install.sh - the owner's standing rule "always reply in Traditional Chinese
# (正體中文)", installed into Claude Code at user scope on macOS. Called by the root install.sh;
# runnable on its own.
#
# Owner, 2026-11-02: 「請你用絕對能記住、遵守的方式記錄下與我對話一律用正體中文」. Three layers,
# as first set up by hand on this Mac (Reglow project), reproduced exactly:
#   1. settings.json "language"   - Claude Code's own setting; adds a "# Language" block to
#                                    every session's system prompt
#   2. a UserPromptSubmit hook     - zh-tw-reply.py remind: puts the rule in front of the
#                                    model on every turn
#   3. a Stop hook                 - zh-tw-reply.py stop: if a turn showed the owner mostly
#                                    English prose, block once and ask for a rewrite
#
# A re-run on a machine that has all three changes nothing. An existing "language" value is
# LEFT ALONE (somebody chose it); existing hooks of other tools are never touched.
#
# Usage: sh reply-language/install.sh [--check-only] [--self-test]
# Exit:  0 ok / nothing to do   1 failed (settings.json restored)   2 bad usage

LANGUAGE_VALUE='traditional chinese (正體中文, Taiwan)'
HOOK_NAME=zh-tw-reply.py

say() { printf '%s\n' "$*"; }

# copy_master SOURCE TARGET - identical is a no-op; different keeps TARGET.local-<stamp>
copy_master() {
    if [ -e "$2" ]; then
        if [ "$(shasum -a 256 <"$1")" = "$(shasum -a 256 <"$2")" ]; then
            say "   $(basename "$2") already current"; return 0
        fi
        b="$2.local-$(date +%Y%m%d%H%M%S)"
        cp -p "$2" "$b" || return 1
        say "   $(basename "$2") differed from the master - previous version kept at $b"
    fi
    cp "$1" "$2" || return 1
    say "   $(basename "$2") installed"
}

# The jq program: add what is missing, leave everything else exactly as it is. A hook is
# "ours" when its command mentions zh-tw-reply.py, so a re-run never adds a second one.
SETTINGS_JQ='
  (if has("language") then . else .language = $lang end)
  | .hooks = (.hooks // {})
  | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // [])
  | .hooks.Stop = (.hooks.Stop // [])
  # an entry that is already ours gets the CURRENT command written in place (never a second
  # entry) - else the command the first install wrote would be frozen and an update could
  # never change it (W1, 2026-11-02; graph-refresh.ps1 / settings-merge.py do the same)
  | .hooks.UserPromptSubmit |= map(if (.hooks | type) == "array" then .hooks |= map(
        if ((.command // "") | test("zh-tw-reply\\.py")) then .command = $remind else . end) else . end)
  | .hooks.Stop |= map(if (.hooks | type) == "array" then .hooks |= map(
        if ((.command // "") | test("zh-tw-reply\\.py")) then .command = $stop else . end) else . end)
  | (if any(.hooks.UserPromptSubmit[]; tostring | test("zh-tw-reply\\.py")) then .
     else .hooks.UserPromptSubmit += [{hooks: [{type: "command", command: $remind, timeout: 10}]}] end)
  | (if any(.hooks.Stop[]; tostring | test("zh-tw-reply\\.py")) then .
     else .hooks.Stop += [{hooks: [{type: "command", command: $stop, timeout: 20}]}] end)
'
REMIND_CMD='python3 -I "$HOME/.claude/hooks/zh-tw-reply.py" remind'
STOP_CMD='python3 -I "$HOME/.claude/hooks/zh-tw-reply.py" stop'

# merge_settings FILE - add the three entries if missing; backup, in-place write, and a proof
# pass that nothing outside .language / hooks.UserPromptSubmit / hooks.Stop changed
merge_settings() {
    f=$1
    existed=0
    if [ -e "$f" ]; then
        existed=1
        /usr/bin/jq -e . "$f" >/dev/null 2>&1 || { say "   settings.json is not valid JSON - refusing to touch it"; return 1; }
    else
        mkdir -p "$(dirname "$f")" || return 1
        printf '{}\n' >"$f"
    fi
    tmpf="$f.dw-new.$$"
    /usr/bin/jq --arg lang "$LANGUAGE_VALUE" --arg remind "$REMIND_CMD" --arg stop "$STOP_CMD" \
        "$SETTINGS_JQ" "$f" >"$tmpf" 2>/dev/null || { rm -f "$tmpf"; [ $existed = 0 ] && rm -f "$f"; say "   jq could not merge settings.json"; return 1; }
    if [ $existed = 1 ] && [ "$(/usr/bin/jq -cS . "$f")" = "$(/usr/bin/jq -cS . "$tmpf")" ]; then
        rm -f "$tmpf"; say "   settings.json: nothing to change"; return 0
    fi
    backup=''
    if [ $existed = 1 ]; then backup="$f.bak-$(date +%Y%m%d%H%M%S)"; cp -p "$f" "$backup" || { rm -f "$tmpf"; return 1; }; fi
    if ! cat "$tmpf" >"$f"; then
        rm -f "$tmpf"
        if [ -n "$backup" ]; then cat "$backup" >"$f"; else rm -f "$f"; fi
        say "   writing settings.json failed - restored"; return 1
    fi
    rm -f "$tmpf"
    problems=''
    /usr/bin/jq -e '.language and ([.hooks.UserPromptSubmit[] | tostring | test("zh-tw-reply")] | any) and ([.hooks.Stop[] | tostring | test("zh-tw-reply")] | any)' "$f" >/dev/null 2>&1 \
        || problems="$problems; an entry is missing after the write"
    if [ $existed = 1 ]; then
        rest='del(.language) | del(.hooks.UserPromptSubmit) | del(.hooks.Stop) | if .hooks == {} then del(.hooks) else . end'
        [ "$(/usr/bin/jq -cS "$rest" "$backup")" = "$(/usr/bin/jq -cS "$rest" "$f")" ] || problems="$problems; something else changed"
        others='[(.hooks.UserPromptSubmit // [], .hooks.Stop // [])[] | .hooks[]?.command // empty | select(test("zh-tw-reply") | not)] | sort'
        [ "$(/usr/bin/jq -c "$others" "$backup")" = "$(/usr/bin/jq -c "$others" "$f")" ] || problems="$problems; another tool's hook changed"
        [ "$(/usr/bin/jq -c '.language' "$backup")" = null ] || [ "$(/usr/bin/jq -c '.language' "$backup")" = "$(/usr/bin/jq -c '.language' "$f")" ] || problems="$problems; an existing language value changed"
    fi
    if [ -n "$problems" ]; then
        if [ -n "$backup" ]; then cat "$backup" >"$f"; else rm -f "$f"; fi
        say "   settings.json patch failed, restored. Problems:${problems#;}"; return 1
    fi
    say "   settings.json: language and the two hooks added (backup: ${backup:-none - new file})"
}

self_test() {
    pass=0; fail=0
    t() { if [ "$2" = 0 ]; then pass=$((pass + 1)); say "  PASS  $1"; else fail=$((fail + 1)); say "  FAIL  $1"; fi; }
    sb=$(mktemp -d "${TMPDIR:-/tmp}/reply-lang-test.XXXXXX") || return 1
    say 'reply-language/install.sh self-test'
    merge_settings "$sb/new/settings.json" >/dev/null
    t 'a missing settings.json is created with all three' "$(/usr/bin/jq -e '.language and (.hooks.UserPromptSubmit|length==1) and (.hooks.Stop|length==1)' "$sb/new/settings.json" >/dev/null; echo $?)"
    merge_settings "$sb/new/settings.json" >"$sb/o2"
    t 'a re-run changes nothing' "$(grep -q 'nothing to change' "$sb/o2"; echo $?)"
    t 'a re-run adds no second hook' "$(/usr/bin/jq -e '(.hooks.UserPromptSubmit|length==1) and (.hooks.Stop|length==1)' "$sb/new/settings.json" >/dev/null; echo $?)"
    cat >"$sb/s.json" <<'EOF'
{ "model": "opus", "language": "english",
  "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "other-tool" } ] } ],
             "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "guard" } ] } ] },
  "statusLine": { "type": "command", "command": "s 中文" } }
EOF
    merge_settings "$sb/s.json" >/dev/null
    t 'an existing language value is left alone' "$(/usr/bin/jq -e '.language == "english"' "$sb/s.json" >/dev/null; echo $?)"
    t 'other tools'"'"' hooks and keys survive' "$(/usr/bin/jq -e '.hooks.UserPromptSubmit[0].hooks[0].command == "other-tool" and .hooks.PreToolUse[0].matcher == "Bash" and .model == "opus" and .statusLine.command == "s 中文"' "$sb/s.json" >/dev/null; echo $?)"
    t 'our two hooks are appended beside them' "$(/usr/bin/jq -e '([.hooks.UserPromptSubmit[]|tostring|select(test("zh-tw-reply"))]|length==1) and ([.hooks.Stop[]|tostring|select(test("zh-tw-reply"))]|length==1)' "$sb/s.json" >/dev/null; echo $?)"
    # an entry that is ours but carries an OLD command is updated in place, not frozen, not doubled
    cat >"$sb/old.json" <<'EOF'
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "python3 /old/zh-tw-reply.py remind", "timeout": 7 } ] } ],
             "Stop": [ { "hooks": [ { "type": "command", "command": "python3 /old/zh-tw-reply.py stop", "timeout": 9 } ] } ] } }
EOF
    merge_settings "$sb/old.json" >/dev/null
    t 'an old command of ours is rewritten to the current one' "$(/usr/bin/jq -e --arg r "$REMIND_CMD" --arg s "$STOP_CMD" '.hooks.UserPromptSubmit[0].hooks[0].command == $r and .hooks.Stop[0].hooks[0].command == $s' "$sb/old.json" >/dev/null; echo $?)"
    t '...in place: still one entry each, its timeout kept' "$(/usr/bin/jq -e '(.hooks.UserPromptSubmit|length==1) and (.hooks.Stop|length==1) and .hooks.UserPromptSubmit[0].hooks[0].timeout == 7' "$sb/old.json" >/dev/null; echo $?)"
    printf '{ broken\n' >"$sb/bad.json"; cp "$sb/bad.json" "$sb/bad.orig"
    merge_settings "$sb/bad.json" >/dev/null; rc=$?
    t 'invalid JSON is refused and left byte-identical' "$([ $rc = 1 ] && cmp -s "$sb/bad.json" "$sb/bad.orig"; echo $?)"
    # the hook itself: remind prints the rule; stop blocks an English turn, passes a Chinese one
    h=$here/$HOOK_NAME
    t 'hook remind: prints the rule as additionalContext' "$(python3 -I "$h" remind | /usr/bin/jq -e '.hookSpecificOutput.additionalContext | test("正體中文")' >/dev/null; echo $?)"
    en='This is a long English paragraph written for the owner, which the rule says must be in Chinese instead.'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' \
        "$(/usr/bin/jq -cn --arg t "$en" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}')" >"$sb/en.jsonl"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"這一段是給擁有者看的正體中文說明，提到 install.sh 也沒關係。"}]}}' >"$sb/zh.jsonl"
    t 'hook stop: an English turn is blocked' "$(/usr/bin/jq -cn --arg p "$sb/en.jsonl" '{transcript_path:$p}' | python3 -I "$h" stop | /usr/bin/jq -e '.decision == "block"' >/dev/null; echo $?)"
    t 'hook stop: a Chinese turn passes' "$([ -z "$(/usr/bin/jq -cn --arg p "$sb/zh.jsonl" '{transcript_path:$p}' | python3 -I "$h" stop)" ]; echo $?)"
    # a Chinese reply citing unbackticked Windows paths is still Chinese (W1's false positive)
    wz='設定已經寫進 D:\WorkSpace\dev-workstation\reply-language\settings-merge.py，另一份在 C:\Users\Someone\AppData\Local\Programs\dev-workstation\node\something.json，兩個都改好了。'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' \
        "$(/usr/bin/jq -cn --arg t "$wz" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}')" >"$sb/win.jsonl"
    t 'hook stop: a Chinese reply with Windows paths passes' "$([ -z "$(/usr/bin/jq -cn --arg p "$sb/win.jsonl" '{transcript_path:$p}' | python3 -I "$h" stop)" ]; echo $?)"
    t 'hook stop: never blocks twice (stop_hook_active)' "$([ -z "$(/usr/bin/jq -cn --arg p "$sb/en.jsonl" '{transcript_path:$p,stop_hook_active:true}' | python3 -I "$h" stop)" ]; echo $?)"
    rm -rf "$sb"
    say ''; say "  $pass PASS  $fail FAIL"
    [ "$fail" = 0 ]
}

main() {
    here=$(cd "$(dirname "$0")" && pwd)
    mode=install
    for a in "$@"; do
        case $a in
            --check-only) mode=check ;;
            --self-test) mode=selftest ;;
            *) say "reply-language/install.sh: unknown argument: $a"; exit 2 ;;
        esac
    done
    if [ "$mode" = selftest ]; then self_test; exit $?; fi
    [ -x /usr/bin/jq ] || { say '/usr/bin/jq is missing'; exit 1; }
    command -v python3 >/dev/null 2>&1 || { say 'python3 is missing - the root install.sh installs it'; exit 1; }
    s=$HOME/.claude/settings.json; h=$HOME/.claude/hooks/$HOOK_NAME
    if [ "$mode" = check ]; then
        if [ -f "$h" ] && cmp -s "$here/$HOOK_NAME" "$h"; then say "   $HOOK_NAME: current"; else say "   $HOOK_NAME: would be installed or updated"; fi
        if [ -f "$s" ] && /usr/bin/jq -e '.language and ([.hooks.UserPromptSubmit[]?|tostring|test("zh-tw-reply")]|any) and ([.hooks.Stop[]?|tostring|test("zh-tw-reply")]|any)' "$s" >/dev/null 2>&1; then
            say '   settings.json: language and both hooks present'
        else say '   settings.json: would add what is missing'; fi
        exit 0
    fi
    mkdir -p "$HOME/.claude/hooks" || exit 1
    copy_master "$here/$HOOK_NAME" "$h" || exit 1
    merge_settings "$s" || exit 1
    say '   takes effect in the NEXT Claude Code session'
}

main "$@"
