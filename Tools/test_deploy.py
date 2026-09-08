#!/usr/bin/env python3
"""One runnable check for Tools/deploy.py.    python Tools/test_deploy.py

⭐ IT TESTS THE RENAME BRANCH, not the easy path. On the machine this was written on, both
user-scope files are byte-identical to their templates, so a normal run is a no-op and the
hardest, most destructive path - rename the project's own CLAUDE.md, place the template,
generate the merge prompt - has no natural trigger at all. A test of the path that already
works would prove nothing about the one that can lose somebody's file.

⛔ EVERYTHING HAPPENS IN A SCRATCH DIRECTORY. --repo is given a temporary folder, and the
--user runs are pointed at a temporary one too by overriding USERPROFILE, which is what
os.path.expanduser reads on Windows - measured, not assumed. The real ~/.claude is never
opened, however badly a check fails.

⚠ IT DRIVES THE SCRIPT AS A SUBPROCESS rather than importing it. The gate is answered on
stdin and the answer decides whether files move; importing and calling the pieces would
test a different program from the one anybody runs.
"""

import glob
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPLOY = os.path.join(REPO, "Tools", "deploy.py")
TEMPLATE = os.path.join(REPO, "general-claude-md", "project-CLAUDE.md")

OLD_TEXT = """# CLAUDE.md — 舊的專案檔

這個專案的資料庫是 PostgreSQL 14，跑在 db-01 上。
Never `git push --force` to main.
"""


def run(repo, *args, **kw):
    cmd = [sys.executable, DEPLOY, "--repo", repo] + list(args)
    r = subprocess.run(cmd, capture_output=True, cwd=REPO,
                       input=kw.get("stdin", b""))
    return (r.returncode,
            r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace"))


# ⚠ WHAT install.ps1 WOULD HAVE LEFT BEHIND. The scratch repo is seeded with a real
# .gitignore, because ensure_gitignore() is documented as read-then-append and an empty
# file cannot tell an append from a rewrite.
SEEDED_GITIGNORE = "# the project's own rules\n*.log\nnode_modules/\nCLAUDE.local.md*\n"


def make_repo(with_claude_md=True, track=True):
    d = tempfile.mkdtemp(prefix="deploy-test-")
    subprocess.run(["git", "-C", d, "init", "-q"], capture_output=True)
    io.open(os.path.join(d, ".gitignore"), "w", encoding="utf-8",
            newline="\n").write(SEEDED_GITIGNORE)
    subprocess.run(["git", "-C", d, "config", "user.email", "t@example.com"],
                   capture_output=True)
    subprocess.run(["git", "-C", d, "config", "user.name", "t"], capture_output=True)
    if with_claude_md:
        io.open(os.path.join(d, "CLAUDE.md"), "w", encoding="utf-8",
                newline="\n").write(OLD_TEXT)
        if track:
            subprocess.run(["git", "-C", d, "add", "CLAUDE.md"], capture_output=True)
            subprocess.run(["git", "-C", d, "commit", "-qm", "add"], capture_output=True)
    return d


def report_of(repo):
    hits = glob.glob(os.path.join(repo, ".claude", "deploy-report-*.md"))
    assert len(hits) == 1, "expected exactly one report, got %r" % hits
    return io.open(hits[0], encoding="utf-8").read()


def manifest_of(repo):
    return json.load(io.open(os.path.join(repo, ".claude", ".deploy-manifest.json"),
                             encoding="utf-8"))


# ------------------------------------------------------------------ the checks

def test_check_never_writes_and_never_asks():
    d = make_repo()
    # ⚠ stdin is CLOSED. A --check that asks anything would hang or read EOF; either way
    # the assertion below catches a version that started prompting.
    rc, out = run(d, stdin=b"")
    assert rc == 0, out
    assert "GATE" in out, out
    assert "--check asks nothing" in out, out
    assert io.open(os.path.join(d, "CLAUDE.md"), encoding="utf-8").read() == OLD_TEXT
    assert not glob.glob(os.path.join(d, ".claude", "*")), "check mode wrote something"
    shutil.rmtree(d, ignore_errors=True)
    print("ok   --check writes nothing and asks nothing")


def test_gate_cancels_on_anything_but_rename():
    d = make_repo()
    rc, out = run(d, "--apply", stdin=b"yes please\n")
    assert rc == 3, out
    assert "cancelled" in out, out
    assert io.open(os.path.join(d, "CLAUDE.md"), encoding="utf-8").read() == OLD_TEXT
    assert not os.path.exists(os.path.join(d, ".claude")), "cancel still wrote something"
    shutil.rmtree(d, ignore_errors=True)
    print("ok   the gate cancels on anything but the word rename")


def test_gate_cancels_on_closed_stdin():
    """⛔ A CLOSED STDIN IS NOT CONSENT. Fail-closed, not 'nobody objected'."""
    d = make_repo()
    rc, out = run(d, "--apply", stdin=b"")
    assert rc == 3, out
    assert io.open(os.path.join(d, "CLAUDE.md"), encoding="utf-8").read() == OLD_TEXT
    shutil.rmtree(d, ignore_errors=True)
    print("ok   EOF on stdin cancels")


def test_rename_branch():
    d = make_repo()
    rc, out = run(d, "--apply", stdin=b"rename\n")
    assert rc == 0, out

    # the tracked-file warning must have been shown BEFORE the question
    assert "TRACKED BY GIT" in out, out

    olds = glob.glob(os.path.join(d, "CLAUDE.md.20*"))
    assert len(olds) == 1, "expected one renamed old file, got %r" % olds
    assert io.open(olds[0], encoding="utf-8").read() == OLD_TEXT, "old file was altered"

    # ⛔ BYTE-IDENTICAL. Not "looks right" - a text-mode copy would pass a line-by-line
    # comparison and fail this one, and it is this one the three-state logic depends on.
    with open(os.path.join(d, "CLAUDE.md"), "rb") as a, open(TEMPLATE, "rb") as b:
        assert a.read() == b.read(), "placed template is not byte-identical to the source"

    man = manifest_of(d)
    entry = man["CLAUDE.md"]
    assert entry["kind"] == "oneshot", entry
    assert len(entry["sha256"]) == 64, entry

    # ⛔ THE ASSERTIONS RUN ON THE FENCED BLOCK, not on the whole report. The report is
    # allowed to say "the block below" and to reference this run; the PROMPT is not,
    # because the agent receiving it has none of that. Asserting against the whole file
    # tests the surrounding prose and passes or fails by accident.
    rep = report_of(d)
    blocks = rep.split("```")
    prompt = next((b for b in blocks if "FILL" in b), None)
    assert prompt is not None, "no fenced merge prompt in the report:\n" + rep

    assert olds[0] in prompt, "prompt does not name the old file by absolute path"
    assert os.path.join(d, "CLAUDE.md") in prompt, "prompt does not name the new file"
    for phrase in ("as discussed", "as above", "the block below", "earlier", "this session",
                   "we agreed", "mentioned"):
        assert phrase not in prompt.lower(), \
            "the prompt leans on context the agent will not have: %r" % phrase
    assert "GENERAL engineering rule" in prompt, "prompt omits the do-not-copy rule"
    assert "Do not commit" in prompt, "prompt does not forbid committing"

    gi = io.open(os.path.join(d, ".gitignore"), encoding="utf-8").read()
    assert "/.claude/.deploy-manifest.json" in gi, gi
    assert "/.claude/deploy-report-*.md" in gi, gi
    # ⛔ APPENDED, NOT REWRITTEN. graph-servers/install.ps1 writes to this same file and so
    # does the project's owner; losing their rules would be silent and permanent.
    for kept in SEEDED_GITIGNORE.strip().splitlines():
        assert kept in gi, "append clobbered an existing rule (%r):\n%s" % (kept, gi)
    assert "/.claude/*.json" not in gi, \
        "an extension-wide rule got in - this repo's .gitignore warns about exactly that"

    shutil.rmtree(d, ignore_errors=True)
    print("ok   rename branch: old renamed, template placed, prompt self-contained")


def test_oneshot_is_never_flagged_again():
    """⭐ The second run must be silent. A template whose FILL slots have been answered is
    the project's file, and reporting it as drift for ever is the noise the two strategies
    exist to prevent."""
    d = make_repo()
    rc, out = run(d, "--apply", stdin=b"rename\n")
    assert rc == 0, out
    io.open(os.path.join(d, "CLAUDE.md"), "a", encoding="utf-8").write("\nlocal edit\n")
    rc, out = run(d)
    assert rc == 0, out
    assert "DONE" in out, out
    assert "CONFLICT" not in out, "an answered template was reported as drift:\n" + out
    shutil.rmtree(d, ignore_errors=True)
    print("ok   a placed template is never flagged again, even after editing")


def test_fresh_project_just_gets_the_template():
    d = make_repo(with_claude_md=False)
    rc, out = run(d, "--apply", stdin=b"")
    assert rc == 0, out
    assert "INSTALL" in out, out
    with open(os.path.join(d, "CLAUDE.md"), "rb") as a, open(TEMPLATE, "rb") as b:
        assert a.read() == b.read()
    shutil.rmtree(d, ignore_errors=True)
    print("ok   a project with no CLAUDE.md is not asked anything")


def run_user(home, *args, **kw):
    """⛔ A FAKE HOME, so the upgradable path can be tested without going near the real
    profile. deploy.py's HOME is os.path.expanduser("~"), and on Windows that reads
    USERPROFILE - measured, not assumed. The real ~/.claude is never opened by these runs.
    """
    env = dict(os.environ, USERPROFILE=home, HOME=home)
    r = subprocess.run([sys.executable, kw.get("script", DEPLOY), "--user"] + list(args),
                       capture_output=True, cwd=REPO, env=env, input=kw.get("stdin", b""))
    return (r.returncode,
            r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace"))


def test_user_scope_three_states():
    home = tempfile.mkdtemp(prefix="deploy-home-")
    rc, out = run_user(home, "--apply")
    assert rc == 0, out
    assert out.count("INSTALL") >= 2, out
    target = os.path.join(home, ".claude", "CLAUDE.md")
    src = os.path.join(REPO, "general-claude-md", "user-CLAUDE.md")
    with open(target, "rb") as a, open(src, "rb") as b:
        assert a.read() == b.read(), "user CLAUDE.md is not byte-identical to the template"

    rc, out = run_user(home)
    assert "NOOP" in out, out
    assert "CONFLICT" not in out, "a file we just wrote was called a conflict:\n" + out

    io.open(target, "a", encoding="utf-8").write("\nmy own rule\n")
    rc, out = run_user(home)
    assert "CONFLICT" in out, "an edited file was not protected:\n" + out
    assert "edited since we deployed it" in out, out
    shutil.rmtree(home, ignore_errors=True)
    print("ok   user scope: install -> noop -> conflict once edited")


def test_clean_upgrade_overwrites_and_backs_up():
    """⭐ THE ONE STATE THAT OVERWRITES ON PURPOSE, and the only one where place()'s backup
    and post-write hash check actually run against an existing file.

    ⚠ It cannot be reached by editing the template - the preflight refuses uncommitted
    changes under general-claude-md/, correctly. It is reached from the other side: the
    file on disk matches what the manifest says WE last wrote, and the template has since
    moved on. Rewriting the manifest hash to match a locally changed file produces exactly
    that state without touching the source repository at all.
    """
    home = tempfile.mkdtemp(prefix="deploy-home-")
    assert run_user(home, "--apply")[0] == 0
    target = os.path.join(home, ".claude", "CLAUDE.md")
    man_path = os.path.join(home, ".claude", ".deploy-manifest.json")

    io.open(target, "a", encoding="utf-8").write("\nan older template's line\n")
    man = json.load(io.open(man_path, encoding="utf-8"))
    key = ".claude/CLAUDE.md"
    man[key]["sha256"] = hashlib.sha256(open(target, "rb").read()).hexdigest()
    io.open(man_path, "w", encoding="utf-8", newline="\n").write(json.dumps(man))

    rc, out = run_user(home)
    assert "UPGRADE" in out, out
    assert "clean upgrade" in out, out

    rc, out = run_user(home, "--apply")
    assert rc == 0, out
    src = os.path.join(REPO, "general-claude-md", "user-CLAUDE.md")
    with open(target, "rb") as a, open(src, "rb") as b:
        assert a.read() == b.read(), "upgrade did not land the current template"
    baks = glob.glob(target + ".bak-*")
    assert len(baks) == 1, "an upgrade must leave exactly one backup, got %r" % baks
    assert "an older template's line" in io.open(baks[0], encoding="utf-8").read(), \
        "the backup does not hold what was replaced"
    shutil.rmtree(home, ignore_errors=True)
    print("ok   clean upgrade overwrites, and the backup holds the old content")


def test_report_never_lands_in_the_other_scope():
    """⛔ A --user --repo run must not drop a report carrying home-directory paths into
    somebody else's project."""
    home = tempfile.mkdtemp(prefix="deploy-home-")
    d = make_repo(with_claude_md=False)
    env = dict(os.environ, USERPROFILE=home, HOME=home)
    r = subprocess.run([sys.executable, DEPLOY, "--user", "--repo", d, "--apply"],
                       capture_output=True, cwd=REPO, env=env, input=b"")
    out = (r.stdout + r.stderr).decode("utf-8", "replace")
    assert r.returncode == 0, out
    assert glob.glob(os.path.join(home, ".claude", "deploy-report-*.md")), out
    assert not glob.glob(os.path.join(d, ".claude", "deploy-report-*.md")), \
        "the combined report was written into the project as well:\n" + out
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(d, ignore_errors=True)
    print("ok   the report stays in your own profile when --user is in play")


def test_no_manifest_entry_fails_closed_MUTATION():
    """⛔ MUTATION CHECK on the guard that actually carries the weight.

    The load-bearing line is decide()'s final `return CONFLICT` - the one reached when the
    file differs and the manifest cannot show WE wrote it. It fails open in the worst
    possible way if it is ever softened to UPGRADE: somebody's own edits are backed up and
    overwritten, silently, on a file the script never deployed.

    ⚠ The __unreadable__ marker is asserted too, but honestly: removing it does NOT flip
    the decision, because the no-entry fallthrough below already catches it. It changes the
    MESSAGE, not the safety. The line worth mutating is the fallthrough, so that is the one
    mutated here - and the assertion is that the mutant OVERWRITES what the real script
    refuses to touch.
    """
    home = tempfile.mkdtemp(prefix="deploy-home-")
    assert run_user(home, "--apply")[0] == 0
    target = os.path.join(home, ".claude", "CLAUDE.md")

    # an unparseable manifest still fails closed, with its own message
    man_path = os.path.join(home, ".claude", ".deploy-manifest.json")
    io.open(man_path, "w", encoding="utf-8", newline="\n").write("{ this is not json")
    io.open(target, "a", encoding="utf-8").write("\nmy own rule\n")
    rc, out = run_user(home)
    assert "CONFLICT" in out and "does not parse" in out, out

    # no manifest at all: the case the fallthrough exists for
    os.remove(man_path)
    rc, out = run_user(home)
    assert "CONFLICT" in out, out
    assert "no manifest entry" in out, out
    mine = io.open(target, encoding="utf-8").read()
    assert "my own rule" in mine

    # --- the mutation
    # ⚠ THE MUTANT MUST LIVE IN Tools/. deploy.py derives REPO from its own __file__, so a
    # copy in a temp directory decides the repository is that temp directory, fails the
    # preflight, and "the mutation had no effect" would then be an artefact of the test
    # harness rather than a fact about the guard.
    mutant = os.path.join(REPO, "Tools", "_mutant_deploy.py")
    src = io.open(DEPLOY, encoding="utf-8").read()
    needle = 'return CONFLICT, "no manifest entry - we cannot show we wrote this"'
    assert needle in src, "the guard moved - update this test, do not delete it"
    io.open(mutant, "w", encoding="utf-8", newline="\n").write(
        src.replace(needle, 'return UPGRADE, "MUTANT"'))
    try:
        rc, out = run_user(home, "--apply", script=mutant)
        assert "UPGRADE" in out, "the mutation did not take effect:\n" + out
        after = io.open(target, encoding="utf-8").read()
        assert "my own rule" not in after, \
            "the mutant did NOT overwrite - so the real guard is not what protects this"
    finally:
        os.remove(mutant)
    print("ok   no-manifest-entry fails closed  [mutation: the edit WAS overwritten]")

    shutil.rmtree(home, ignore_errors=True)


def main():
    if not os.path.exists(TEMPLATE):
        raise SystemExit("missing %s" % TEMPLATE)
    for fn in (test_check_never_writes_and_never_asks,
               test_gate_cancels_on_anything_but_rename,
               test_gate_cancels_on_closed_stdin,
               test_rename_branch,
               test_oneshot_is_never_flagged_again,
               test_fresh_project_just_gets_the_template,
               test_user_scope_three_states,
               test_clean_upgrade_overwrites_and_backs_up,
               test_report_never_lands_in_the_other_scope,
               test_no_manifest_entry_fails_closed_MUTATION):
        fn()
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    sys.exit(main())
