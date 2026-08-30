#!/usr/bin/env python3
"""Deploy this repository's CLAUDE.md templates to a user profile or a project.

    python Tools/deploy.py --user                          # what user scope needs
    python Tools/deploy.py --repo C:\\WorkSpace\\thing       # what that project needs
    python Tools/deploy.py --user --repo <path> --apply    # do it
    python Tools/deploy.py --repo <path> --apply --with-graph-servers --with-dispatch-guard

⭐ WHAT THIS IS. `general-claude-md/` holds two files that belong in every profile and one
template that belongs in every project. This script puts them there, refuses to overwrite
anything a human has edited, and writes the differences it refused to touch into a prompt
you can hand straight to an agent.

⛔ DEFAULT IS --check. Nothing is written without --apply. And --check NEVER ASKS A
QUESTION: it has nothing to authorise, so it prints the question it *would* ask along with
the consequence, and stops. The whole plan is computed before a single file is touched -
a half-applied tree is harder to diagnose than a clean refusal.

⛔ THE TWO INSTALLERS ARE OPT-IN, both off by default (owner, 2026-08-29). Without
--with-graph-servers / --with-dispatch-guard this script only moves CLAUDE.md files, and
the toolchain checks those installers need are not even run - a file copy has no reason to
be blocked by somebody's Python layout.

⛔ IT OWNS THREE FILES AND NO MORE. `install.ps1` and `install.py` own their own targets,
and both already have backups, post-write checks and rollback. This script CALLS them and
relays their output VERBATIM; it never compares their files against its own manifest,
because two owners for one file is how a file gets clobbered by the owner that lost track.

⚠ NO LITERAL HOME PATH ANYWHERE. The plan for this script was written on one machine and
reviewed on another, where six of seven measured paths were different and its own preflight
gate would have cancelled the run. Everything goes through HOME below.

⚠ COMPARISON AND COPYING ARE BINARY. These files are full of CJK and ⛔/⚠/⭐, and one
text-mode round trip on Windows rewrites every newline - after which the hash never matches
again and the script reports "you customised this" on a file it wrote itself, for ever.
"""

import datetime
import hashlib
import io
import json
import os
import shutil
import site
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO, "general-claude-md")
HOME = os.path.expanduser("~")

# ⭐ A LITERAL TUPLE, not a config file - same call as EXCLUDE_TOP in publish-public.py.
# (path relative to the scope root, source basename, strategy)
#
# ⛔ THE STRATEGY IS NOT DECORATION, and it is written into the manifest at first deploy.
# `upgradable`  - ours for ever; a newer template is offered as an upgrade.
# `oneshot`     - the moment it is placed it belongs to the project. Never re-compared,
#                 never flagged. A template whose FILL slots have been answered is not a
#                 stale copy of anything, and reporting it as one is pure noise.
USER_FILES = (
    (os.path.join(".claude", "CLAUDE.md"), "user-CLAUDE.md", "upgradable"),
    (os.path.join(".claude", "docs", "VERIFICATION-LESSONS.md"),
     "VERIFICATION-LESSONS.md", "upgradable"),
)
REPO_FILES = (
    ("CLAUDE.md", "project-CLAUDE.md", "oneshot"),
)

MANIFEST = os.path.join(".claude", ".deploy-manifest.json")

# ⛔ NAMED PREFIXES, NEVER `/.claude/*.json`. This repository's own .gitignore carries the
# warning and the reason: `.claude/` holds both one machine's state AND the shared,
# version-controlled settings.json, so a rule about a file EXTENSION hides the second one
# the day somebody adds it, with `git status` saying nothing at all.
GITIGNORE_LINES = ("/.claude/.deploy-manifest.json", "/.claude/deploy-report-*.md")

# ⭐ Read off this machine's own settings.json, 2026-08-29, rather than retyped from memory.
MARKETPLACE = ("dispatch-guard", {"source": {"source": "github",
                                             "repo": "Dino9021/dispatch-guard"}})
PLUGIN = "dispatch-guard@dispatch-guard"

# ⚠ THE KEYS DO NOT DOWNLOAD THE PLUGIN. Measured against the docs 2026-08-29:
# "As of Claude Code v2.1.195, adding the marketplace doesn't install plugins that come
# from an external source, on any path that loads plugins" - code.claude.com/docs/en/
# discover-plugins.md, "Configure team marketplaces". So the keys alone leave the plugin
# uninstalled and nothing says so. Print the command; never run it - relaying an installer
# is this script's whole contract with the two it already calls.
INSTALL_HINT = ("- ⚠ the keys alone do NOT download the plugin. Run once:\n"
                "  `claude plugin install %s`\n"
                "  It takes effect at the next start, or after `/reload-plugins`.\n" % PLUGIN)

STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def die(msg):
    print("⛔ %s" % msg)
    raise SystemExit(2)


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True)
    return (r.returncode,
            r.stdout.decode("utf-8", "replace"),
            r.stderr.decode("utf-8", "replace"))


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def sha256(path):
    return hashlib.sha256(read_bytes(path)).hexdigest()


def write_text(path, text):
    """⚠ Explicit UTF-8 and explicit \\n. The default on Windows is neither."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    io.open(path, "w", encoding="utf-8", newline="\n").write(text)


def load_manifest(root):
    path = os.path.join(root, MANIFEST)
    if not os.path.exists(path):
        return {}
    try:
        return json.load(io.open(path, encoding="utf-8"))
    except (ValueError, OSError):
        # ⚠ FAIL CLOSED. An unreadable manifest is not an empty one: empty means "never
        # deployed", which sends every changed file down the CLEAN-UPGRADE path and
        # overwrites edits. Unknown provenance must mean "do not overwrite".
        return {"__unreadable__": True}


# --------------------------------------------------------------------- deciding

INSTALL, NOOP, UPGRADE, CONFLICT, DONE, GATE = (
    "INSTALL", "NOOP", "UPGRADE", "CONFLICT", "DONE", "GATE")


def decide(target, source, kind, manifest, key):
    """The three-state table, plus the two states the table does not cover.

    ⛔ `oneshot` NEVER REACHES THE COMPARISON. Its whole point is that after placement the
    file is the project's, so "differs from the template" is the expected steady state and
    not a finding.

    ⛔ NO MANIFEST ENTRY + DIFFERENT CONTENT = CONFLICT, never a clean upgrade. The manifest
    is the only evidence that WE wrote what is on disk; without it, different content is
    somebody's work and the fail-closed answer is the correct one.
    """
    entry = manifest.get(key)
    broken = manifest.get("__unreadable__")

    if kind == "oneshot":
        if entry and os.path.exists(target):
            return DONE, "placed on %s; it is the project's file now" % entry.get("at", "?")
        if entry and not os.path.exists(target):
            return INSTALL, "manifest says deployed but the file is gone - placing it again"
        if not os.path.exists(target):
            return INSTALL, "no CLAUDE.md here"
        return GATE, "this project already has its own CLAUDE.md"

    if not os.path.exists(target):
        return INSTALL, "not deployed yet"
    if read_bytes(target) == read_bytes(source):
        return NOOP, "byte-identical to the template"
    if broken:
        return CONFLICT, "the manifest does not parse - refusing to assume we wrote this"
    if entry and entry.get("sha256") == sha256(target):
        return UPGRADE, "unchanged since we deployed it - a clean upgrade"
    if entry:
        return CONFLICT, "edited since we deployed it"
    return CONFLICT, "no manifest entry - we cannot show we wrote this"


# --------------------------------------------------------------------- preflight

def have(exe, *args):
    """⛔ RESOLVE THROUGH shutil.which FIRST. On Windows npm is `npm.cmd`, and CreateProcess
    - which is what subprocess uses without a shell - only ever appends `.exe`. So a bare
    ["npm", ...] raises FileNotFoundError on a machine where npm works perfectly from the
    command line, and the preflight then refuses to deploy over a tool that is right there.
    Measured 2026-08-29: exactly that happened. shutil.which honours PATHEXT.
    """
    resolved = shutil.which(exe)
    if resolved is None:
        return None
    try:
        r = subprocess.run([resolved] + list(args), capture_output=True)
    except (OSError, ValueError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace").strip().splitlines()[0][:60]


def probe_site_packages():
    """Where would `pip install` actually land? Returns (path, shared, control_ok).

    ⛔ NOT `sys.prefix`. Measured 2026-08-29: an interpreter in C:\\Program Files still
    installs into %APPDATA% because pip prints "Defaulting to user installation because
    normal site-packages is not writeable" and does exactly that. Gating on the
    interpreter's location cancels the whole run for a condition that is not happening.

    ⛔ AND NOT `os.access(p, os.W_OK)`. On Windows that reads the read-only attribute and
    ignores the ACL. Same machine, same directory: os.access said True, the open() raised
    PermissionError. The only honest test is to write.

    ⚠ NOT `pip --dry-run` either, tempting as it is: it needs the package index, so on an
    offline or locked-down box the GATE ITSELF errors - and a broken gate must never be
    read as a gate that passed.
    """
    target = None
    for p in site.getsitepackages():
        if p.lower().endswith("site-packages"):
            target = p
            break
    # ⭐ POSITIVE CONTROL, in the same run and through the same code path: a directory that
    # MUST be writable. If this comes back False the probe is broken, and an unwritable
    # answer below means nothing at all.
    control = _writable(tempfile.gettempdir())
    if target is None:
        return None, False, control
    under_home = os.path.normcase(target).startswith(os.path.normcase(HOME) + os.sep)
    if under_home:
        return target, False, control        # already the user's own; nothing to warn about
    return target, _writable(target), control


def _writable(d):
    probe = os.path.join(d, ".deploy-write-probe")
    try:
        with open(probe, "w") as f:
            f.write("probe")
    except OSError:
        return False
    finally:
        try:
            os.remove(probe)
        except OSError:
            pass
    return True


def preflight(want_graph, want_guard):
    """⚠ Only what the selected work actually needs. Copying a Markdown file has no
    business failing because somebody's Python lives in an unusual place."""
    lines = []
    rc, out, _e = git(REPO, "rev-parse", "--abbrev-ref", "HEAD")
    lines.append("source repo     : %s @ %s" % (REPO, out.strip() if rc == 0 else "?"))
    lines.append("home            : %s" % HOME)

    # ⛔ SCOPED TO THE FILES BEING COPIED, not the whole tree. This script copies from the
    # WORKING tree, so the question is whether the templates are modified - not whether
    # some unrelated file is. A whole-tree check also makes the script refuse to run in the
    # very session that is editing it.
    rc, _o, _e = git(REPO, "diff", "--quiet", "HEAD", "--", "general-claude-md")
    if rc != 0:
        die("general-claude-md/ has uncommitted changes. Commit them first - deploying a\n"
            "   template that exists nowhere in the history makes the manifest hash point\n"
            "   at a version nobody can look up.")
    lines.append("templates       : clean (no uncommitted changes under general-claude-md/)")

    if want_graph:
        for exe, args, label in (("pwsh", ("-NoProfile", "-Command",
                                           "$PSVersionTable.PSVersion.ToString()"), "pwsh"),
                                 ("npm", ("config", "get", "prefix"), "npm prefix")):
            v = have(exe, *args)
            if v is None:
                die("--with-graph-servers needs %s on PATH, and it is not there." % exe)
            lines.append("%-16s: %s" % (label, v))
        target, shared, control = probe_site_packages()
        lines.append("site-packages   : %s  [write probe control: %s]"
                     % (target, "OK" if control else "BROKEN"))
        if not control:
            die("the write probe could not write to the temp directory either, so its\n"
                "   answer about site-packages means nothing. Fix that before deploying.")
        if shared:
            die("pip would install into %s, which is outside %s and writable by you -\n"
                "   so packages would land where every account on this machine sees them.\n"
                "   Install Python under your own profile, or run graph-servers/install.ps1\n"
                "   yourself if that is genuinely what you want." % (target, HOME))
        lines.append("pip target      : user scope (or pip falls back to it) - OK")

    if want_guard:
        p = find_install_py()
        lines.append("dispatch-guard  : %s" % (p or "NOT FOUND - see the report"))
    return lines


def find_install_py():
    """⛔ "THE PLUGIN CACHE" IS NOT ONE LOCATION. Measured 2026-08-29: four install.py on
    one machine, three distinct hashes, including a 15KB v0.1.0 under a DIFFERENT
    marketplace that "first one found" picks in preference to the 92KB current one. So the
    marketplace name is pinned and the version directory is chosen by version, not by
    whatever os.listdir happens to return first.
    """
    cache = os.path.join(HOME, ".claude", "plugins", "cache", "dispatch-guard",
                         "dispatch-guard")
    if os.path.isdir(cache):
        def key(name):
            return tuple(int(x) if x.isdigit() else -1 for x in name.split("."))
        for ver in sorted(os.listdir(cache), key=key, reverse=True):
            p = os.path.join(cache, ver, "install.py")
            if os.path.exists(p):
                return p
    for p in (os.path.join(HOME, ".claude", "plugins", "marketplaces", "dispatch-guard",
                           "install.py"),
              os.path.join(os.path.dirname(REPO), "dispatch-guard", "install.py")):
        if os.path.exists(p):
            return p
    return None


# --------------------------------------------------------------------- the plan

def compute_plan(scopes):
    """Everything decided before anything is touched (chapter 七, step 2)."""
    items = []
    gate = None
    for scope, root, files in scopes:
        manifest = load_manifest(root)
        for rel, src_name, kind in files:
            target = os.path.join(root, rel)
            source = os.path.join(SOURCE, src_name)
            if not os.path.exists(source):
                die("missing template: %s" % source)
            # ⛔ THE MANIFEST KEY IS RELATIVE TO THE SCOPE ROOT, never absolute. An
            # absolute key stops matching the moment the folder is renamed or the profile
            # sits at a different path - and "no entry" means CONFLICT, so the script would
            # start refusing to upgrade files it owns and could not say why.
            key = rel.replace("\\", "/")
            state, why = decide(target, source, kind, manifest, key)
            item = {"scope": scope, "root": root, "target": target, "source": source,
                    "kind": kind, "state": state, "why": why, "key": key}
            if state == GATE:
                gate = item
            items.append(item)
    return items, gate


def tracked_by_git(repo, rel):
    rc, _o, _e = git(repo, "ls-files", "--error-unmatch", "--", rel)
    return rc == 0


SYMBOL = {INSTALL: "+", NOOP: "=", UPGRADE: "^", CONFLICT: "!", DONE: ".", GATE: "?"}


def print_plan(items, gate, relays, apply_mode):
    print()
    for it in items:
        print(" %s %-8s %s" % (SYMBOL[it["state"]], it["state"], it["target"]))
        print("     %s" % it["why"])
    for label, cmd, cwd in relays:
        print(" > RELAY    %s" % label)
        print("     %s" % " ".join(cmd))
        print("     cwd: %s" % cwd)
    if not items and not relays:
        print(" (nothing selected - pass --user and/or --repo <path>)")
    print()
    if gate is not None:
        print_gate(gate, apply_mode)


def print_gate(gate, apply_mode):
    repo = gate["root"]
    print("=" * 72)
    print("⚠ %s already exists." % gate["target"])
    if tracked_by_git(repo, "CLAUDE.md"):
        print()
        print("⚠ IT IS TRACKED BY GIT, so your colleagues have it too. Renaming it makes")
        print("  git see a deletion (D CLAUDE.md) plus a new file nobody recognises.")
        print("  IF THAT COMMIT IS PUSHED, THEIR CLAUDE.md IS GONE. This script only ever")
        print("  touches your working copy - it never commits and never stages anything.")
    print()
    print("  rename : %s -> CLAUDE.md.%s, template placed, merge prompt written" %
          (os.path.basename(gate["target"]), STAMP))
    print("  anything else : THE WHOLE RUN IS CANCELLED, --user half included.")
    print("                  Not 'skip this file and carry on' - nothing happens at all.")
    print("=" * 72)
    if not apply_mode:
        print()
        print("⭐ --check asks nothing. Re-run with --apply to be asked this for real,")
        print("   before any file is touched.")


def ask_gate():
    print()
    print("Type  rename  to take the rename branch. Anything else cancels everything.")
    try:
        answer = input("  ").strip().lower()
    except EOFError:
        answer = ""        # ⚠ a closed or piped stdin is not consent
    return answer == "rename"


# --------------------------------------------------------------------- applying

def backup(path):
    """⚠ Beside the original, timestamped. A backup somewhere central is a backup nobody
    finds while staring at the directory the file was in."""
    dst = "%s.bak-%s" % (path, STAMP)
    shutil.copy2(path, dst)
    return dst


def place(item, manifest):
    """Copy, verify by hash, roll back if the verification fails."""
    target, source = item["target"], item["source"]
    saved = backup(target) if os.path.exists(target) else None
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    shutil.copy2(source, target)          # ⚠ binary copy - never a read/write round trip
    if sha256(target) != sha256(source):
        if saved:
            shutil.copy2(saved, target)
            die("post-write check failed for %s - rolled back from %s" % (target, saved))
        os.remove(target)
        die("post-write check failed for %s - removed the partial copy" % target)
    manifest[item["key"]] = {"sha256": sha256(target), "kind": item["kind"],
                             "source": os.path.relpath(source, REPO).replace("\\", "/"),
                             "at": STAMP}
    return saved


def save_manifest(root, manifest):
    manifest.pop("__unreadable__", None)
    write_text(os.path.join(root, MANIFEST),
               json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def ensure_gitignore(repo):
    """⚠ READ THEN APPEND, never rewrite. graph-servers/install.ps1 appends to this same
    file, and so may the project's own owner."""
    path = os.path.join(repo, ".gitignore")
    text = io.open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    have_lines = set(l.strip() for l in text.splitlines())
    missing = [l for l in GITIGNORE_LINES if l not in have_lines]
    if not missing:
        return []
    block = ("\n# Written by Tools/deploy.py. Per-run, per-machine: the manifest is this\n"
             "# clone's own deployment state and a copy of it on a machine that has\n"
             "# nothing installed would lie about what is deployed.\n")
    write_text(path, text.rstrip("\n") + "\n" + block + "".join(l + "\n" for l in missing))
    return missing


def merge_prompt(old_abs, new_abs):
    """⭐ THIS IS AN AGENT PROMPT, so it follows this project's own prompt rules: it stands
    completely alone, every path is absolute, and it says where each thing goes. The agent
    reading it has none of this conversation.

    ⛔ IT FILLS THE TEMPLATE'S OWN FILL SLOTS. Not a second file under .claude/rules/ -
    project facts are exactly what those slots exist to hold, and splitting them across two
    files gives one fact two homes.
    """
    return """\
You are merging one project's old CLAUDE.md into the shared template that has replaced it.
Work only on the two absolute paths below. Do not commit anything.

  OLD (the project's own file, renamed, unchanged):  %s
  NEW (the shared template, just placed):            %s

Do this:

1. Read both files in full.
2. Find every `<!-- FILL: ... -->` slot in NEW. Each one names what belongs there.
3. For each slot, take the matching content OUT OF OLD and write it into NEW, replacing the
   FILL comment. Keep the project's own wording; you are moving facts, not rewriting them.
4. Content in OLD that is a GENERAL engineering rule - one that would hold in any project -
   must NOT be moved. Those rules now come from the user-level CLAUDE.md, and copying them
   here creates a second live copy of one rule, which is the failure this template exists
   to prevent.
5. Delete every section of NEW this project has nothing to put in. Deleting is expected,
   not a loss.
6. Print a three-part summary for the human: what you moved, what you judged general and
   therefore dropped, and anything you were not sure about.

Do not delete OLD. The human decides when it goes.
""" % (old_abs, new_abs)


def relay(label, cmd, cwd):
    """⛔ VERBATIM, NEVER PARSED. install.ps1 -CheckOnly exits 0 whether everything is
    installed or nothing is, and prints fixed-width human text; anything built on parsing
    that goes silently wrong the day a column width changes. So the output is passed
    through and the human reads it.

    ⚠ cwd IS ALWAYS EXPLICIT. install.py's removal path uses os.getcwd(), and a relay that
    inherits whatever directory it was launched from is a relay that acts on the wrong
    project one day.
    """
    print()
    print("=" * 72)
    print("RELAY %s" % label)
    print("  %s" % " ".join(cmd))
    print("  cwd: %s" % cwd)
    print("=" * 72)
    lines = ["## RELAY %s\n" % label, "```\n", "%s\n" % " ".join(cmd)]
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True)
    except OSError as e:
        print("⛔ could not run it: %s" % e)
        lines.append("could not run it: %s\n" % e)
        lines.append("```\n")
        return "".join(lines)
    out = (r.stdout + r.stderr).decode("utf-8", "replace")
    print(out)
    print("(exit %d)" % r.returncode)
    lines.append(out)
    lines.append("(exit %d)\n" % r.returncode)
    lines.append("```\n")
    return "".join(lines)


# --------------------------------------------------------------------- entry point

def usage():
    print(__doc__)
    return 1


def main(argv):
    apply_mode = "--apply" in argv
    want_graph = "--with-graph-servers" in argv
    want_guard = "--with-dispatch-guard" in argv
    patch_only = "--patch-only" in argv
    do_user = "--user" in argv
    repo_path = None
    if "--repo" in argv:
        i = argv.index("--repo")
        if i + 1 >= len(argv):
            die("--repo needs a path after it.")
        repo_path = os.path.abspath(argv[i + 1])
        if not os.path.isdir(repo_path):
            die("not a directory: %s" % repo_path)
    if not (do_user or repo_path):
        return usage()

    print("Tools/deploy.py  %s   [%s]" % (STAMP, "APPLY" if apply_mode else "CHECK - nothing will be written"))
    for line in preflight(want_graph, want_guard):
        print("  %s" % line)

    scopes = []
    if do_user:
        scopes.append(("user", HOME, USER_FILES))
    if repo_path:
        scopes.append(("repo", repo_path, REPO_FILES))
    items, gate = compute_plan(scopes)

    relays = []
    if want_guard:
        p = find_install_py()
        if p:
            # ⚠ The absolute path AND its hash go in the report: see find_install_py().
            relays.append(("dispatch-guard install.py (%s)" % sha256(p)[:16],
                           [sys.executable, p, "--all"] +
                           ([] if apply_mode else ["--check"]), HOME))
    if want_graph and repo_path:
        ps = os.path.join(REPO, "graph-servers", "install.ps1")
        args = ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps,
                "-Repo", repo_path]
        # ⛔ -PatchOnly IS NEVER SENT IN CHECK MODE, and this is not tidiness. In
        # install.ps1 the -PatchOnly branch (line 930) runs and exits BEFORE -CheckOnly is
        # ever consulted, so `-PatchOnly -CheckOnly` PATCHES - it writes settings.json and
        # CLAUDE.local.md while this script is promising it changed nothing.
        if apply_mode:
            args += ["-PatchOnly"] if patch_only else []
        else:
            args += ["-CheckOnly"]
        relays.append(("graph-servers install.ps1", args, repo_path))

    print_plan(items, gate, relays, apply_mode)

    if not apply_mode:
        for it in items:
            if it["state"] == CONFLICT:
                print()
                print("-" * 72)
                print("MERGE PROMPT that --apply would write for %s" % it["target"])
                print("-" * 72)
                print(merge_prompt(it["target"] + ".bak-" + STAMP, it["target"]))
        print("⭐ --check: NOTHING was written. Re-run with --apply to carry that out.")
        return 0

    if gate is not None and not ask_gate():
        print()
        print("cancelled - not one file was touched, in either scope.")
        return 3

    # ------------------------------------------------------------------ writes
    report = ["# deploy report %s\n\n" % STAMP,
              "Source: `%s`\n\nHome: `%s`\n\n" % (REPO, HOME)]
    for scope, root, _files in scopes:
        manifest = load_manifest(root)
        touched = False
        for it in items:
            if it["root"] != root:
                continue
            state = it["state"]
            if state in (NOOP, DONE):
                report.append("- `%s` — %s (%s)\n" % (it["target"], state, it["why"]))
                continue
            if state == GATE:
                old = it["target"] + "." + STAMP
                os.rename(it["target"], old)
                place(it, manifest)
                touched = True
                report.append("\n## renamed and replaced: `%s`\n\n" % it["target"])
                report.append("- old file: `%s`\n- template: `%s`\n\n" % (old, it["source"]))
                report.append("Hand the block below to an agent verbatim.\n\n```\n")
                report.append(merge_prompt(old, it["target"]))
                report.append("```\n")
                continue
            if state == CONFLICT:
                saved = backup(it["target"])
                touched = True
                report.append("\n## refused to overwrite: `%s`\n\n" % it["target"])
                report.append("- %s\n- backup: `%s`\n- template: `%s`\n\n"
                              % (it["why"], saved, it["source"]))
                report.append("Hand the block below to an agent verbatim.\n\n```\n")
                report.append(merge_prompt(saved, it["target"]))
                report.append("```\n")
                continue
            saved = place(it, manifest)
            touched = True
            report.append("- `%s` — %s%s\n" % (it["target"], state,
                                               (", backup `%s`" % saved) if saved else ""))
        if touched:
            save_manifest(root, manifest)
        if scope == "repo":
            added = ensure_gitignore(root)
            if added:
                report.append("\n- added to `%s/.gitignore`: %s\n"
                              % (root, ", ".join("`%s`" % a for a in added)))

    if want_guard:
        report.append("\n" + settings_keys())
    for label, cmd, cwd in relays:
        report.append("\n" + relay(label, cmd, cwd))

    # ⛔ THE SCRIPT CANNOT VERIFY /context. Its checks cover bytes on disk and whether
    # settings.json still parses - nothing about what a session actually loads. So the
    # steps a human has to take go in the report rather than being quietly assumed.
    report.append("""
## What only you can check

The checks above cover files on disk. Whether Claude Code actually LOADS them is not
something this script can see, so:

1. Start a new Claude Code session in the project.
2. Run `/context` and look at "Memory files" — both CLAUDE.md files should be listed.
3. Confirm the `unattended-work` confirmation line prints at session start.
""")

    # ⛔ ONE REPORT, AND IT GOES TO YOUR OWN PROFILE WHENEVER --user IS IN PLAY. It used to
    # be written once per scope, and since the report accumulates BOTH scopes, a
    # `--user --repo X` run dropped your home-directory paths and the diffs of your own
    # customised ~/.claude/CLAUDE.md into a file inside X - somebody else's project.
    # Git-ignored, so never committed, but written there all the same.
    report_root = HOME if do_user else repo_path
    path = os.path.join(report_root, ".claude", "deploy-report-%s.md" % STAMP)
    write_text(path, "".join(report))
    print()
    print("⭐ report: %s" % path)
    return 0


def settings_keys():
    """Add the two plugin keys, and only if absent. ⚠ Backed up and re-parsed, because a
    settings.json that no longer parses takes the whole harness down with it."""
    path = os.path.join(HOME, ".claude", "settings.json")
    if not os.path.exists(path):
        return "- `%s` does not exist; plugin keys not added.\n" % path
    try:
        data = json.load(io.open(path, encoding="utf-8"))
    except ValueError as e:
        return "- ⛔ `%s` does not parse (%s); left alone.\n" % (path, e)
    name, source = MARKETPLACE
    changed = []
    if name not in data.setdefault("extraKnownMarketplaces", {}):
        data["extraKnownMarketplaces"][name] = source
        changed.append("extraKnownMarketplaces.%s" % name)
    if PLUGIN not in data.setdefault("enabledPlugins", {}):
        data["enabledPlugins"][PLUGIN] = True
        changed.append("enabledPlugins.%s" % PLUGIN)
    if not changed:
        return ("- `%s`: both plugin keys already present, left alone.\n" % path) + INSTALL_HINT
    saved = backup(path)
    write_text(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    try:
        json.load(io.open(path, encoding="utf-8"))
    except ValueError as e:
        shutil.copy2(saved, path)
        die("settings.json no longer parses after the edit (%s) - rolled back from %s"
            % (e, saved))
    return ("- `%s`: added %s (backup `%s`)\n"
            % (path, ", ".join(changed), saved)) + INSTALL_HINT


if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    sys.exit(main(sys.argv[1:]))
