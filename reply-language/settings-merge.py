#!/usr/bin/env python3
# ⚠ The docstring below is RAW. It names Windows paths, and `\U` in C:\Users is a
# unicode escape in an ordinary string - measured here 2026-11-02 as
# "SyntaxError: truncated \UXXXXXXXX escape", which took the whole module out.
r"""The settings.json half of reply-language/install.ps1, on Windows.

    settings-merge.py merge <settings.json> <python.exe> <zh-tw-reply.py>
    settings-merge.py check <settings.json> <python.exe> <zh-tw-reply.py>
    settings-merge.py selftest

⛔ THE HOOK COMMANDS ARE BUILT HERE, from the two paths, and never passed in as strings.
PowerShell decodes a child process's stdout with [Console]::OutputEncoding - CP950 on a
zh-TW Windows - so a command string carrying a non-ASCII path (an owner whose Windows
user name is Chinese: C:\Users\王小明\.claude\hooks\...) would be mangled the moment it
crossed a pipe. Arguments do not go through a pipe: CreateProcess passes them as UTF-16
and Python decodes argv as UTF-16 on Windows, so the paths arrive intact. Keeping the
only copy of the command template on this side removes the pipe from the design.

Adds what is missing and nothing else: the "language" key (an existing value is LEFT
ALONE - somebody chose it), a UserPromptSubmit hook and a Stop hook. A hook is "ours"
when its command mentions zh-tw-reply.py, so a re-run never adds a second one - and when
ours is present but its command has CHANGED, the command is rewritten in place, which is
what makes the one-command update able to update anything at all.

Exit: 0 ok / nothing to do   1 failed (settings.json restored)   2 bad usage

WHY THIS IS PYTHON AND NOT POWERSHELL, when graph-servers/install.ps1:200
`Merge-ClaudeSettings` already patches this very file from PowerShell. Three measured
reasons, all of them encoding, which is the defect this whole feature exists to fix:

  1. The language value below contains 正體中文. No .ps1 in this repository carries a
     BOM (measured 2026-11-02 over every .ps1 in the tree: 0 of them), and Windows
     PowerShell 5.1 reads a BOM-less file as the ANSI codepage - CP950 here - so a
     Chinese literal in a .ps1 would be written into settings.json as mojibake. In a
     .py it is unambiguous: Python 3 source is UTF-8 by definition.
  2. `Set-Content -Encoding utf8` writes a BOM under 5.1 and no BOM under 7. A BOM in
     settings.json is a risk nothing here needs to take; Python writes UTF-8 without one,
     the same under every host.
  3. ConvertTo-Json's depth-2 default flattens hooks[] to the literal "System.Object[]"
     (graph-servers/install.ps1:206-209 records that measurement), and 5.1 unwraps a
     one-element array on the way through the pipeline - and the live settings.json on
     this machine has three one-element hook arrays. json.dump has neither behaviour.

The macOS half does the same work with /usr/bin/jq (reply-language/install.sh:42-96);
this file is its counterpart, not a port of the PowerShell patcher.
"""
import json
import os
import shutil
import sys
import time

# Must stay byte-identical to LANGUAGE_VALUE in reply-language/install.sh:21 - the two
# installers write the same key on their own platform, and a machine that has had both
# must not see the value flip.
LANGUAGE_VALUE = 'traditional chinese (正體中文, Taiwan)'
OURS = 'zh-tw-reply.py'
EVENTS = (('UserPromptSubmit', 10), ('Stop', 20))


def say(text):
    print('   ' + text)


def canonical(obj):
    """For COMPARING two structures - key order must not count here."""
    return json.dumps(obj, sort_keys=True, ensure_ascii=False)


def copy_of(obj):
    """For EDITING - key order must be preserved here, or the whole file gets reordered
    on every run and 'leave everything else exactly as it is' stops being true."""
    return json.loads(json.dumps(obj, ensure_ascii=False))


def is_ours(entry):
    return OURS in canonical(entry)


def shape_problem(settings):
    """A settings.json whose shape we cannot edit without losing data. Refusing beats
    guessing: these keys have one legal shape, and anything else is already broken."""
    if not isinstance(settings, dict):
        return 'the top level is not a JSON object'
    hooks = settings.get('hooks', {})
    if not isinstance(hooks, dict):
        return 'hooks is not a JSON object'
    for event, _ in EVENTS:
        if event in hooks and not isinstance(hooks[event], list):
            return 'hooks.%s is not a JSON array' % event
    return None


def rest_of(settings):
    """Everything this installer is NOT allowed to touch, for the before/after proof."""
    d = copy_of(settings)
    d.pop('language', None)
    hooks = d.get('hooks')
    if isinstance(hooks, dict):
        hooks.pop('UserPromptSubmit', None)
        hooks.pop('Stop', None)
        if not hooks:
            d.pop('hooks', None)
    return canonical(d)


def other_tools_hooks(settings):
    """Every command in our two arrays that is NOT ours - none of them may change."""
    out = []
    hooks = settings.get('hooks')
    if not isinstance(hooks, dict):
        return out
    for event, _ in EVENTS:
        for entry in hooks.get(event) or []:
            if not isinstance(entry, dict):
                continue
            for inner in entry.get('hooks') or []:
                cmd = isinstance(inner, dict) and inner.get('command')
                if cmd and OURS not in cmd:
                    out.append(cmd)
    return sorted(out)


def our_command(settings, event):
    """The command of our entry for EVENT, or None when we have no entry there."""
    for entry in ((settings.get('hooks') or {}).get(event) or []):
        if not isinstance(entry, dict) or not is_ours(entry):
            continue
        for inner in entry.get('hooks') or []:
            if isinstance(inner, dict) and OURS in str(inner.get('command', '')):
                return inner.get('command')
    return None


def apply_wanted(settings, commands):
    """Mutate SETTINGS towards the wanted state. Returns a list of notes."""
    notes = []
    if 'language' not in settings:
        settings['language'] = LANGUAGE_VALUE
        notes.append('language added')
    else:
        notes.append('language already set - left alone')

    # shape_problem() has already refused anything but the legal shapes, so these two
    # lines cannot silently replace somebody's data with an empty container.
    hooks = settings.setdefault('hooks', {})

    for event, timeout in EVENTS:
        arr = hooks.setdefault(event, [])
        mine = [e for e in arr if isinstance(e, dict) and is_ours(e)]
        if not mine:
            arr.append({'hooks': [{'type': 'command', 'command': commands[event],
                                   'timeout': timeout}]})
            notes.append('%s hook added' % event)
            continue
        # Present already. Rewrite the command if it has changed - a skip-if-present rule
        # would freeze whatever command the first install wrote and make this feature
        # permanently un-updatable, which is the opposite of what it is for.
        changed = 0
        for entry in mine:
            for inner in entry.get('hooks') or []:
                if (isinstance(inner, dict) and OURS in str(inner.get('command', ''))
                        and inner['command'] != commands[event]):
                    inner['command'] = commands[event]
                    changed += 1
        if changed:
            notes.append('%s hook command updated' % event)
        else:
            notes.append('%s hook already current' % event)
        if len(mine) > 1:
            notes.append('%s has %d of our entries - only the commands were touched'
                         % (event, len(mine)))
    return notes


def load(path):
    with open(path, 'rb') as f:
        raw = f.read()
    if raw.startswith(b'\xef\xbb\xbf'):
        raw = raw[3:]
    return json.loads(raw.decode('utf-8'))


def dump(path, settings):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
        f.write('\n')


def check(path, commands):
    if not os.path.isfile(path):
        say('settings.json: would be created with language and both hooks')
        return 0
    try:
        settings = load(path)
    except (ValueError, OSError) as exc:
        say('settings.json is not valid JSON - refusing to touch it (%s)' % exc)
        return 1
    bad = shape_problem(settings)
    if bad:
        say('settings.json: %s - refusing to touch it' % bad)
        return 1
    missing = []
    if 'language' not in settings:
        missing.append('language')
    for event, _ in EVENTS:
        cur = our_command(settings, event)
        if cur is None:
            missing.append(event + ' hook')
        elif cur != commands[event]:
            missing.append(event + ' hook command (out of date)')
    if missing:
        say('settings.json: would add or update ' + ', '.join(missing))
    else:
        say('settings.json: language and both hooks present and current')
    return 0


def merge(path, commands):
    existed = os.path.isfile(path)
    if existed:
        try:
            before = load(path)
        except (ValueError, OSError) as exc:
            say('settings.json is not valid JSON - refusing to touch it (%s)' % exc)
            return 1
        bad = shape_problem(before)
        if bad:
            say('settings.json: %s - refusing to touch it' % bad)
            return 1
    else:
        parent = os.path.dirname(path)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)
        before = {}

    after = copy_of(before)
    notes = apply_wanted(after, commands)
    if existed and canonical(before) == canonical(after):
        say('settings.json: nothing to change')
        return 0

    backup = None
    if existed:
        backup = '%s.bak-%s' % (path, time.strftime('%Y%m%d%H%M%S'))
        shutil.copy2(path, backup)
    try:
        dump(path, after)
    except OSError as exc:
        if backup:
            shutil.copy2(backup, path)
        elif os.path.isfile(path):
            os.remove(path)
        say('writing settings.json failed (%s) - restored' % exc)
        return 1

    # --- the proof pass: read back from disk, in a separate read from the one that wrote
    problems = []
    try:
        with open(path, 'rb') as f:
            raw = f.read()
        if raw.startswith(b'\xef\xbb\xbf'):
            problems.append('the file was written with a BOM')
        live = json.loads(raw.decode('utf-8'))
    except (ValueError, OSError) as exc:
        problems.append('the result does not read back as UTF-8 JSON: %s' % exc)
        live = None

    if live is not None:
        if 'language' not in live:
            problems.append('language is missing after the write')
        for event, _ in EVENTS:
            if our_command(live, event) != commands[event]:
                problems.append('the %s hook is missing or wrong after the write' % event)
        if existed:
            if rest_of(before) != rest_of(live):
                problems.append('something else changed')
            if other_tools_hooks(before) != other_tools_hooks(live):
                problems.append("another tool's hook changed")
            if 'language' in before and before['language'] != live.get('language'):
                problems.append('an existing language value changed')

    if problems:
        if backup:
            shutil.copy2(backup, path)
            undo = 'restored from the backup'
        else:
            if os.path.isfile(path):
                os.remove(path)
            undo = 'removed the file we had just created'
        say('settings.json patch failed, %s. Problems: %s' % (undo, '; '.join(problems)))
        return 1

    say('settings.json: ' + '; '.join(notes)
        + ' (backup: %s)' % (backup if backup else 'none - new file'))
    return 0


# ----------------------------------------------------------------- the hook command
# ⛔ THE ONE LIVE COPY OF THE COMMAND STRING. install.ps1 asks for it with `command`
# rather than formatting its own, so the installer and the self-test can never drift.
#
# -X utf8 is the whole point, and it is NOT decoration. Measured on this machine
# 2026-11-02, Python 3.14.7, a zh-TW Windows:
#     python -I zh-tw-reply.py remind   ->  BE D6 A6 B3 AA CC AA BA   (CP950/Big5)
#     python -X utf8 -I ... remind      ->  E6 93 81 E6 9C 89 E8 80   (UTF-8)
# Claude Code reads a hook's stdout as UTF-8, so without the flag the rule arrives as
# mojibake and `stop` ALSO decodes its stdin JSON as CP950 - a Chinese path in the
# payload then raises, the hook dies, and the enforcement is silently off.
# An environment variable cannot fix this: -I is isolated mode and ignores PYTHONUTF8
# and PYTHONIOENCODING (both measured, both still produced CP950 bytes).
def hook_command(python, hook_path, verb):
    return '"%s" -X utf8 -I "%s" %s' % (python, hook_path, verb)


# ------------------------------------------------------------------------ self-test
# ⚠ WHY THE WHOLE WINDOWS SELF-TEST LIVES IN THIS FILE and not in install.ps1.
# PowerShell cannot measure what is under test here. It decodes a child's stdout with
# [Console]::OutputEncoding - CP950 on this host - so `python ... | ConvertFrom-Json`
# round-trips the BROKEN output cleanly and passes; and it encodes piped stdin with
# $OutputEncoding, which is ASCII under 5.1, so a Chinese fixture would arrive as
# "???". A test that cannot see the defect is worse than no test. install.ps1
# self-tests its own PowerShell functions and adds these counts to its total.
def self_test():
    import subprocess
    import tempfile

    here = os.path.dirname(os.path.abspath(__file__))
    hook = os.path.join(here, 'zh-tw-reply.py')
    state = {'pass': 0, 'fail': 0}

    def t(name, ok):
        state['pass' if ok else 'fail'] += 1
        print('  %s  %s' % ('PASS' if ok else 'FAIL', name))

    def run(path, cmds):
        """merge() promises a message and an exit code, never a traceback. Catching
        here is what turns a broken guard into a named red case instead of a dead
        suite - measured: the M2 and M4 mutations both killed the run outright, which
        detects them but names nothing."""
        try:
            return merge(path, cmds)
        except Exception as exc:                        # noqa: BLE001 - see above
            print('   merge RAISED instead of reporting: %r' % (exc,))
            return 99

    def peek(path):
        try:
            return load(path)
        except (OSError, ValueError):
            return {}

    sb = tempfile.mkdtemp(prefix='reply-lang-test.')
    py = sys.executable
    cmds = {'UserPromptSubmit': hook_command(py, hook, 'remind'),
            'Stop': hook_command(py, hook, 'stop')}
    print('reply-language/settings-merge.py self-test')

    # --- the merge ----------------------------------------------------------------
    fresh = os.path.join(sb, 'new', 'settings.json')
    rc0 = run(fresh, cmds)
    d = peek(fresh)
    t('creating a settings.json reports success', rc0 == 0)
    t('a missing settings.json is created with all three',
      'language' in d and len(d.get('hooks', {}).get('UserPromptSubmit', [])) == 1
      and len(d.get('hooks', {}).get('Stop', [])) == 1)
    t('the new file has no BOM',
      os.path.isfile(fresh) and open(fresh, 'rb').read()[:3] != b'\xef\xbb\xbf')
    t('a one-element hook array is still a JSON array',
      isinstance(d.get('hooks', {}).get('Stop'), list))

    import io
    cap = io.StringIO()
    keep, sys.stdout = sys.stdout, cap
    try:
        run(fresh, cmds)
    finally:
        sys.stdout = keep
    t('a re-run changes nothing', 'nothing to change' in cap.getvalue())
    d = peek(fresh)
    t('a re-run adds no second hook',
      len(d.get('hooks', {}).get('UserPromptSubmit', [])) == 1
      and len(d.get('hooks', {}).get('Stop', [])) == 1)

    # the UPGRADE path: the command changed, so it must be rewritten in place
    newer = {'UserPromptSubmit': cmds['UserPromptSubmit'] + ' --newer',
             'Stop': cmds['Stop']}
    run(fresh, newer)
    d = peek(fresh)
    t('a changed command is rewritten in place',
      our_command(d, 'UserPromptSubmit') == newer['UserPromptSubmit'])
    t('rewriting the command adds no second entry',
      len(d.get('hooks', {}).get('UserPromptSubmit', [])) == 1)

    # somebody else's settings.json - the Mac fixture, verbatim
    busy = os.path.join(sb, 's.json')
    with open(busy, 'w', encoding='utf-8') as f:
        f.write(json.dumps({
            'model': 'opus', 'language': 'english',
            'hooks': {
                'UserPromptSubmit': [{'hooks': [{'type': 'command', 'command': 'other-tool'}]}],
                'PreToolUse': [{'matcher': 'Bash',
                                'hooks': [{'type': 'command', 'command': 'guard'}]}]},
            'statusLine': {'type': 'command', 'command': 's 中文'}}, ensure_ascii=False))
    run(busy, cmds)
    d = peek(busy)
    t('an existing language value is left alone', d.get('language') == 'english')
    t("other tools' hooks and keys survive",
      canonical(d.get('hooks', {}).get('UserPromptSubmit', [])).count('other-tool') == 1
      and canonical(d.get('hooks', {}).get('PreToolUse')) == canonical(
          [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'guard'}]}])
      and d.get('model') == 'opus'
      and (d.get('statusLine') or {}).get('command') == 's 中文')
    t('our two hooks are appended beside them',
      our_command(d, 'UserPromptSubmit') == cmds['UserPromptSubmit']
      and our_command(d, 'Stop') == cmds['Stop'])
    t('key order is preserved',
      list(d)[:2] == ['model', 'language'])

    # refusals - each must leave the file byte-identical
    for name, body in (('invalid JSON', '{ broken\n'),
                       ('hooks that is not an object', '{"hooks": "nope"}'),
                       ('hooks.Stop that is not an array', '{"hooks": {"Stop": 1}}')):
        p = os.path.join(sb, 'bad.json')
        with open(p, 'w', encoding='utf-8') as f:
            f.write(body)
        rc = run(p, cmds)
        t('%s is refused and left byte-identical' % name,
          rc == 1 and open(p, encoding='utf-8').read() == body)

    # --- the hook, run the way settings.json will run it ---------------------------
    # shell=True is cmd.exe here, so this exercises the REAL quoting of the string
    # that gets written into settings.json, not a tidy argv we built by hand.
    def hook_run(verb, stdin_bytes=b''):
        p = subprocess.run(cmds['UserPromptSubmit' if verb == 'remind' else 'Stop'],
                           shell=True, input=stdin_bytes,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p.stdout, p.stderr, p.returncode

    def quiet(verb, stdin_bytes=b''):
        """'The hook said nothing' - and SAID it, rather than dying before it could.
        ⛔ Asserting an empty stdout alone passes on a CRASH, which is exactly how this
        hook fails when its stdin is decoded in the console codepage: the measured M1
        mutation (drop -X utf8) left this case green until the exit code and stderr
        were added to it."""
        out, err, rc = hook_run(verb, stdin_bytes)
        return out.strip() == b'' and err.strip() == b'' and rc == 0

    out, err, rc = hook_run('remind')
    t('remind: the raw bytes are UTF-8, not the console codepage',
      b'\xe6\x93\x81\xe6\x9c\x89' in out and b'\xbe\xd6\xa6\xb3' not in out)
    t('remind: exits 0 and says nothing on stderr', rc == 0 and err.strip() == b'')
    try:
        ctx = json.loads(out.decode('utf-8'))['hookSpecificOutput']['additionalContext']
    except (ValueError, UnicodeDecodeError, KeyError):
        ctx = ''
    t('remind: prints the rule as additionalContext', '正體中文' in ctx)

    def transcript(path, text):
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(json.dumps({'type': 'user',
                                'message': {'role': 'user', 'content': 'hi'}}) + '\n')
            f.write(json.dumps({'type': 'assistant',
                                'message': {'role': 'assistant',
                                            'content': [{'type': 'text', 'text': text}]}},
                               ensure_ascii=False) + '\n')

    en = ('This is a long English paragraph written for the owner, which the rule '
          'says must be in Chinese instead.')
    zh = '這一段是給擁有者看的正體中文說明，提到 install.ps1 也沒關係。'
    enp = os.path.join(sb, 'en.jsonl')
    transcript(enp, en)
    # A Chinese DIRECTORY name, so the payload itself exercises stdin decoding: under
    # the console codepage json.load(sys.stdin) mangles this path and the hook dies.
    zhdir = os.path.join(sb, '中文目錄')
    os.makedirs(zhdir)
    zhp = os.path.join(zhdir, 'zh.jsonl')
    transcript(zhp, zh)

    def payload(**kw):
        return json.dumps(kw, ensure_ascii=False).encode('utf-8')

    blocked, berr, brc = hook_run('stop', payload(transcript_path=enp))
    try:
        decision = json.loads(blocked.decode('utf-8')).get('decision')
    except (ValueError, UnicodeDecodeError):
        decision = None
    t('stop: an English turn is blocked',
      decision == 'block' and brc == 0 and berr.strip() == b'')
    t('stop: a Chinese turn passes, through a Chinese path in the payload',
      quiet('stop', payload(transcript_path=zhp)))
    t('stop: never blocks twice (stop_hook_active)',
      quiet('stop', payload(transcript_path=enp, stop_hook_active=True)))

    # ⛔ A WINDOWS-PATH FIXTURE, AND IT IS PINNED HERE BECAUSE THE MACOS SELF-TEST CANNOT
    # CATCH IT: every path that one writes has forward slashes. zh-tw-reply.py strips
    # paths before measuring, and until 2026-11-02 the pattern knew only "/" - so a
    # short, entirely Chinese reply citing two unbackticked D:\... paths counted their
    # letters as English prose and the turn was BLOCKED. Measured on Windows, reported,
    # and fixed in the shared hook as [/\\].
    winp = os.path.join(sb, 'win.jsonl')
    # The user name here is deliberately a placeholder, not this machine's: a fixture
    # that names a real account puts a machine identifier into a published file.
    transcript(winp, r'我改好了，請看 D:\WorkSpace\dev-workstation\reply-language\install.ps1 '
                     r'和 C:\Users\someone\.claude\settings.json 這兩個檔案。')
    t('stop: a Chinese turn citing two unbackticked WINDOWS paths passes',
      quiet('stop', payload(transcript_path=winp)))

    # ---- the skill-banner exemption, driven end to end through the real command ------
    # dispatch-guard's unattended-work skill requires an English banner as a session's
    # FIRST output, verbatim. Measured 2026-11-02: that line alone, and that line with a
    # full Chinese reply after it, were judged mostly English - so every such turn was
    # blocked and the two rules could not both be met. Standard agreed by M1, W1 and both
    # DispatchGuard sessions at the owner's request: at most ONE anchored banner line per
    # segment is dropped before measuring.
    banner = ('⭐ **`unattended-work` ACTIVE** — sequential dispatch · plan '
              'on disk before dispatch · refute the fix, not just the code · '
              'stall test at 2 rounds · mutation-check every fail-open guard · '
              'exit bar before handing back.')
    # ⚠ THIS CASE ALSO PINS THE ORDER OF TWO SUBSTITUTIONS. The banner carries its own
    # backticks around the skill name, so if the inline-code strip ran first it would eat
    # them, the anchored pattern would no longer match, and the banner would be measured
    # as the English it is. The exemption must run BEFORE that strip (M1, zh-tw-reply.py).
    bnp = os.path.join(sb, 'banner.jsonl')
    transcript(bnp, banner + '\n\n我已經做完了，測試全部通過，請你確認。')
    t('stop: a skill ACTIVE banner followed by a Chinese reply passes',
      quiet('stop', payload(transcript_path=bnp)))

    # ...and the exemption must not become a licence for the rest of the turn.
    enb = os.path.join(sb, 'banner-en.jsonl')
    transcript(enb, banner + '\n\n' + en)
    out3, _, _ = hook_run('stop', payload(transcript_path=enb))
    try:
        d3 = json.loads(out3.decode('utf-8')).get('decision')
    except (ValueError, UnicodeDecodeError):
        d3 = None
    t('stop: English AFTER the banner is still blocked', d3 == 'block')

    # ---- only the FINAL reply is measured (owner, 2026-11-02) -----------------------
    # The rule is for reporting to and discussing with the owner, not for the work in
    # progress, so a running note between tool calls may be in any language. M1 narrowed
    # the hook to the text after the turn's LAST tool call (final_reply(), 5aa0b40).
    def transcript_turn(path, note, reply):
        """A realistic turn, in the shape a real transcript has it: a running note and a
        tool call in one assistant message, the tool_result as a user entry, then the
        reply.

        ⚠ WHAT THESE CASES PIN IS THE BEHAVIOUR, NOT THE MECHANISM, and the first draft
        of this comment claimed otherwise. final_reply() has TWO guards that reach the
        same answer here - a tool_use block discards what came before it, and a
        tool_result user entry does not start a new turn. Measured by mutation
        2026-11-02: removing the tool_use reset alone turns the next case red (D-1), but
        removing BOTH at once leaves this suite fully green (D-3), because either one
        alone still discards the note. In every real turn shape a tool_use is followed by
        a tool_result, so the two are redundant in practice and no fixture here separates
        them. The owner's rule only asks that the FINAL reply be measured, which both
        satisfy; this note exists so nobody reads D-1 as proof that the pair is pinned."""
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            for entry in (
                    {'type': 'user', 'message': {'role': 'user', 'content': 'hi'}},
                    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                        {'type': 'text', 'text': note},
                        {'type': 'tool_use', 'id': 'tu1', 'name': 'Bash', 'input': {}}]}},
                    {'type': 'user', 'message': {'role': 'user', 'content': [
                        {'type': 'tool_result', 'tool_use_id': 'tu1', 'content': 'ok'}]}},
                    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                        {'type': 'text', 'text': reply}]}}):
                f.write(json.dumps(entry, ensure_ascii=False) + '\n')

    note_en = os.path.join(sb, 'note-en.jsonl')
    transcript_turn(note_en, en, '我已經做完了，測試全部通過，請你確認。')
    t('stop: an English running note, then a Chinese final reply, passes',
      quiet('stop', payload(transcript_path=note_en)))

    # ...and the narrowing must not become a way out: the FINAL reply still counts.
    note_zh = os.path.join(sb, 'note-zh.jsonl')
    transcript_turn(note_zh, '先讀一下檔案，確認目前的狀態。', en)
    out4, _, _ = hook_run('stop', payload(transcript_path=note_zh))
    try:
        d4 = json.loads(out4.decode('utf-8')).get('decision')
    except (ValueError, UnicodeDecodeError):
        d4 = None
    t('stop: a Chinese note, then an English final reply, is blocked', d4 == 'block')

    shutil.rmtree(sb, ignore_errors=True)
    print('')
    print('  %d PASS  %d FAIL' % (state['pass'], state['fail']))
    return 1 if state['fail'] else 0


def main(argv):
    if len(argv) == 2 and argv[1] == 'selftest':
        return self_test()
    if len(argv) != 5 or argv[1] not in ('merge', 'check'):
        sys.stderr.write(__doc__.split('\n\n')[1] + '\n')
        return 2
    python, hook = argv[3], argv[4]
    commands = {'UserPromptSubmit': hook_command(python, hook, 'remind'),
                'Stop': hook_command(python, hook, 'stop')}
    return (merge if argv[1] == 'merge' else check)(argv[2], commands)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
