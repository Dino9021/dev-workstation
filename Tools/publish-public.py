#!/usr/bin/env python3
"""Publish the private repository's committed tree to the public GitHub snapshot.

    python Tools/publish-public.py            # show the plan, then ask for `confirm`
    python Tools/publish-public.py --push     # do it without asking: sync, commit, push

⭐ WHAT THIS IS. The private repository is the only working copy: full history, and `Memory/`
tracked. The public repository is a published SNAPSHOT: one commit per publish, no `Memory/`,
and each commit names the private commit it came from so the reasoning is one lookup away.

    private : C:\\WorkSpace\\dev-workstation        -> atlas.dino9021.com:2222/Dino9021/dev-workstation
    public  : C:\\WorkSpace\\dev-workstation_public -> github.com/Dino9021/dev-workstation

⛔ IT MIRRORS THE TREE - IT DOES NOT COMPUTE A DELTA. "Copy what changed since version X" is
the obvious shape and it is wrong: a delta carries additions and edits and silently misses
DELETIONS and renames, so a file removed privately lives on in public for ever. A mirror
cannot miss one, and it is idempotent - running it twice changes nothing the second time.

⛔ AND IT PUBLISHES `git archive HEAD`, NOT THE WORKING TREE. The archive contains exactly what
is committed: no untracked scratch, no ignored files, nothing half-finished. Publishing a
working tree publishes whatever happened to be open at the time.

⛔ `Memory/` IS EXCLUDED BY RULE, NOT BY .gitignore, and that is deliberate. Neither repository
ignores it - the private one TRACKS it on purpose - so the only thing standing between a
private work log and a public repository is this script. Belt and braces: the public
`.gitignore` also gets a `Memory/` line, so a stray folder cannot be committed by hand either.

⚠ EVERY PUBLISH IS SECRET-SCANNED, with a positive control. This is the one direction where a
mistake cannot be taken back.

⚠ THERE IS NO VERSION NUMBER HERE. dev-workstation ships no manifest, so a snapshot is named
by the private commit it came from and the day it was taken. Do not invent a version file to
make this script look like dispatch-guard's - the private sha is the identifier that can
actually be looked up.
"""

import datetime
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

PRIVATE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUBLIC = os.path.join(os.path.dirname(PRIVATE), "dev-workstation_public")
EXCLUDE_TOP = ("Memory",)          # never published, whatever git thinks

# ⭐ ENSURED IN THE PUBLIC .gitignore AFTER EVERY SYNC, because that file is not mirrored and
# so inherits nothing. `Memory/` is the one that matters - the second lock on the private work
# log. The rest is what a copied folder actually brings with it.
# ⚠ `.gitignore` itself is DOCUMENTATION of intent, not enforcement: that file is TRACKED in
# the public repository, and git's ignore rules do not apply to tracked files. What actually
# stops the private one travelling is PUBLIC_OWNED below.
IGNORE_LINES = ("Memory/", ".gitignore", "CLAUDE.local.md*", "__pycache__/", "*.pyc")

# ⛔ FILES THE PUBLIC REPOSITORY OWNS. The mirror neither writes nor deletes these, and they
# are dropped from BOTH sides of the comparison - which is the part that bites: dropping a
# name from the SOURCE side alone makes it "present in the target, absent from the source",
# and a mirror deletes exactly that.
PUBLIC_OWNED = (".gitignore",)

SECRETS = re.compile(
    r"sk-ant-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}")

# ⭐ THE ONE EXEMPTION, AND IT IS KEYED ON THE MATCHED STRING - never on a file, a line number
# or a path. A real credential cannot contain the word FAKE; a test fixture can be made to.
# ⛔ A scanner taught to ignore FILES is a scanner that will ignore the wrong one the day a
# real key lands in a file somebody exempted last year.
FAKE = re.compile(r"FAKE|NOT-A-REAL|EXAMPLE|PLACEHOLDER|DUMMY|REDACTED", re.I)


def git(repo, *args, **kw):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, **kw)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def die(msg):
    print("⛔ %s" % msg)
    raise SystemExit(2)


def export_head(repo, dest):
    """The committed tree, and only that. ⚠ Piped through tarfile so no external tar is needed."""
    r = subprocess.run(["git", "-C", repo, "archive", "--format=tar", "HEAD"],
                       capture_output=True)
    if r.returncode != 0:
        die("git archive failed: %s" % r.stderr.decode("utf-8", "replace")[:200])
    with tarfile.open(fileobj=io.BytesIO(r.stdout)) as tar:
        for m in tar.getmembers():
            top = m.name.split("/", 1)[0]
            if top in EXCLUDE_TOP:
                continue
            tar.extract(m, dest)
    return dest


def tree_files(root):
    out = set()
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in files:
            out.add(os.path.relpath(os.path.join(base, f), root).replace("\\", "/"))
    return out


def main(argv):
    push = "--push" in argv
    for p in (PRIVATE, PUBLIC):
        if not os.path.isdir(os.path.join(p, ".git")):
            die("%s is not a git repository.\n"
                "   Create it first:  git init %s  and give it the GitHub remote." % (p, p))

    # ⛔ COMMITTED STATE ONLY. Uncommitted tracked edits would be published without ever having
    # been recorded privately - the snapshot would show work that exists nowhere else.
    rc, _o, _e = git(PRIVATE, "diff", "--quiet", "HEAD")
    if rc != 0:
        die("the private repository has uncommitted changes to tracked files. Commit first -\n"
            "   a snapshot must never contain work that is not in the history it points at.")

    # ⛔ CAN IT COMMIT AT ALL? Asked BEFORE anything is touched. A step that mutates before it
    # knows it can finish turns one clear failure into two confusing ones: a half-applied tree
    # that the mirror's own idempotence then reads as "nothing to publish".
    # ⚠ Asked on EVERY run, not only under --push, since a run with no arguments can publish
    # once you type `confirm`. Discovering a missing identity AFTER the answer would put the
    # failure on the far side of the consent, which is the one place it must never be.
    for key in ("user.name", "user.email"):
        if not git(PUBLIC, "config", key)[1].strip():
            who = git(PRIVATE, "config", key)[1].strip()
            die("the public repository has no %s. Set it there, not globally:\n"
                "   git -C %s config %s \"%s\""
                % (key, PUBLIC, key, who or "you@example.com"))

    sha = git(PRIVATE, "rev-parse", "--short", "HEAD")[1].strip()
    stamp = datetime.date.today().isoformat()
    print("private : %s at %s" % (stamp, sha))
    print("public  : %s" % PUBLIC)
    print()

    staging = tempfile.mkdtemp(prefix="dw-publish-")
    try:
        export_head(PRIVATE, staging)
        new = tree_files(staging)
        old = tree_files(PUBLIC)

        # ⛔ `.gitignore` BELONGS TO THE PUBLIC REPOSITORY AND IS NEVER MIRRORED. Two reasons.
        # First: it is the only thing keeping Memory/ out by hand, so no private edit can ever
        # remove it. Second, and worse: the private file's own comment reads "Memory/ has no
        # rule here, and that is the point" - true there and a lie here. Mirroring it would
        # publish a rule contradicting its own comment.
        # ⚠ Never copying means a NEW private rule never arrives either, so the difference is
        # REPORTED. Silent drift is the thing being avoided, not drift itself.
        public_gi = os.path.join(PUBLIC, ".gitignore")
        for owned in PUBLIC_OWNED:
            staged = os.path.join(staging, owned)
            if os.path.exists(staged):
                os.remove(staged)
            new.discard(owned)
            old.discard(owned)          # ⛔ or the mirror deletes it - see PUBLIC_OWNED
        pub_text = io.open(public_gi, encoding="utf-8").read() if os.path.exists(public_gi) else ""
        # ⭐ NOT MIRRORED, BUT THE RULES ARE GUARANTEED. Refusing and asking for a manual edit
        # would be a step somebody eventually skips, and the cost of skipping it is a private
        # work log in a public repository.
        gitignore_added = False
        have = set(pub_text.split())
        missing = [l for l in IGNORE_LINES if l not in have]
        if missing:
            pub_text = pub_text.rstrip("\n") + "\n" + "".join(l + "\n" for l in missing)
            io.open(public_gi, "w", encoding="utf-8", newline="\n").write(pub_text)
            print("⭐ added to the public .gitignore: %s" % ", ".join(missing))
            print()
            gitignore_added = True
        priv_rules = set(l.strip() for l in
                         io.open(os.path.join(PRIVATE, ".gitignore"), encoding="utf-8")
                         if l.strip() and not l.lstrip().startswith("#"))
        pub_rules = set(l.strip() for l in pub_text.splitlines()
                        if l.strip() and not l.lstrip().startswith("#"))
        drift = sorted(priv_rules - pub_rules)
        if drift:
            print("⚠ .gitignore is NOT mirrored, and private has rules public lacks:")
            for r in drift:
                print("     %s" % r)
            print("  Add them by hand if they matter here.")
            print()

        added = sorted(new - old)
        removed = sorted(old - new)
        changed = sorted(f for f in (new & old)
                         if io.open(os.path.join(staging, f), "rb").read()
                         != io.open(os.path.join(PUBLIC, f), "rb").read())

        # ⚠ THE SCAN RUNS ON WHAT WILL BE PUBLISHED, not on the source folder, and it prints a
        # control so an empty result cannot be confused with a scan that never ran.
        hits = []
        for f in sorted(new):
            try:
                body = io.open(os.path.join(staging, f), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in SECRETS.finditer(body):
                if FAKE.search(m.group(0)):
                    continue                       # says of itself that it is not a secret
                hits.append("%s: %s" % (f, m.group(0)[:24]))
        print("secret scan     : %d hit(s)   [control: %s]"
              % (len(hits), "OK" if SECRETS.search("ghp_FAKECONTROL0123456789") else "BROKEN"))
        if hits:
            for h in hits[:10]:
                print("   ⛔ %s" % h)
            die("refusing to publish")

        print("files to add    : %d" % len(added))
        for f in added[:20]:
            print("   + %s" % f)
        print("files to update : %d" % len(changed))
        for f in changed[:20]:
            print("   ~ %s" % f)
        print("files to delete : %d" % len(removed))
        for f in removed[:20]:
            print("   - %s" % f)
        # ⛔ THE LITERAL "Memory" IS DELIBERATE - do NOT rewrite this to use EXCLUDE_TOP.
        # It did use EXCLUDE_TOP, and that made the line decoration rather than a check: a
        # mutation run with EXCLUDE_TOP emptied put Memory/notes/... in the add list AND still
        # printed 0, because the counter was asking the same variable that had just failed to
        # filter. A guard measured with the instrument under test cannot fail.
        # ⚠ And it refuses, rather than printing a number nobody reads.
        leaked = sorted(f for f in new if f.split("/", 1)[0] == "Memory")
        print("Memory/ in the publish set: %d  (must be 0)" % len(leaked))
        if leaked:
            for f in leaked[:10]:
                print("   ⛔ %s" % f)
            die("refusing to publish - the private work log reached the publish set")

        if not (added or changed or removed or gitignore_added):
            print("\nnothing to publish - the snapshot already matches %s." % sha)
            return 0
        if not push:
            # ⛔ THE LIST COMES BEFORE THE QUESTION. The code that printed the plan above is the
            # code about to carry it out, so what you approve is exactly what runs. Anything but
            # `confirm` publishes nothing.
            print()
            print('Type  confirm  to publish exactly that. Anything else stops here.')
            try:
                answer = input('  ').strip()
            except EOFError:
                answer = ''        # ⚠ a closed or piped stdin is not consent
            if answer.lower() != 'confirm':
                print()
                print('stopped - nothing was published.')
                # ⚠ NOT 'nothing was changed'. The public .gitignore is written above, BEFORE
                # this question, so that claim would be false on the one run where it matters.
                if gitignore_added:
                    print('  (the public .gitignore keeps the lines added above.)')
                return 3

        for f in removed:
            os.remove(os.path.join(PUBLIC, f))
        for f in added + changed:
            dst = os.path.join(PUBLIC, f)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(staging, f), dst)

        # ⚠ Named paths, never `git add -A`: the house rules refuse that, and the reason applies
        # here too - the set being staged is known, so it may as well be stated.
        # ⚠ `--ignore-unmatch`, because most of what a mirror removes was never tracked. Without
        # it every one of those is a git error this loop would swallow, and a swallowed error is
        # how a real failure to stage a deletion goes unnoticed.
        for f in removed:
            git(PUBLIC, "rm", "--quiet", "--ignore-unmatch", "--", f)
        for f in added + changed:
            git(PUBLIC, "add", "--", f)
        if gitignore_added:
            git(PUBLIC, "add", "--", ".gitignore")

        msg = os.path.join(staging, "COMMIT_MSG")
        io.open(msg, "w", encoding="utf-8", newline="\n").write(
            "dev-workstation snapshot %s\n\nPublished snapshot of the private repository at %s.\n"
            "%d added, %d updated, %d removed.\n" % (stamp, sha, len(added), len(changed),
                                                     len(removed)))
        rc, out, err = git(PUBLIC, "commit", "-F", msg)
        if rc != 0:
            die("commit failed: %s%s" % (out[-400:], err[-400:]))
        rc, out, err = git(PUBLIC, "push", "origin", "HEAD")
        if rc != 0:
            die("push failed: %s%s" % (out[-400:], err[-400:]))
        print("\n⭐ published %s -> %s"
              % (sha, git(PUBLIC, "rev-parse", "--short", "HEAD")[1].strip()))
        print(err.strip().splitlines()[-1] if err.strip() else "")
        return 0
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    sys.exit(main(sys.argv[1:]))
