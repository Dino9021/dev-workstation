# Updating the public repo

**"更新 public repo" means exactly this:**

```bash
python Tools/publish-public.py            # show the plan, then type `confirm` to publish
python Tools/publish-public.py --push     # publish without asking: sync, commit, push
```

Nothing else. No copying by hand, no working out what changed since the last snapshot.

| | |
|---|---|
| private | `C:\WorkSpace\dev-workstation` → `ssh://git@atlas.dino9021.com:2222/Dino9021/dev-workstation.git` |
| public | `C:\WorkSpace\dev-workstation_public` → `https://github.com/Dino9021/dev-workstation` |

The private repository is the only working copy: full history, and `Memory/` tracked. The
public one is a **published snapshot** — one commit per publish, no `Memory/`, and every
commit names the private commit it came from, so the reasoning is one lookup away.

---

## What the script does, and why each part is the way it is

**1. It refuses while the private tree has uncommitted tracked changes.**
A snapshot must never contain work that exists nowhere else.

**2. It publishes `git archive HEAD`, not the working tree.**
Exactly what is committed: no untracked scratch, no ignored files, nothing half-finished.

**3. It MIRRORS the tree — it does not compute a delta.**
⛔ "Copy what changed since version X" is the obvious shape and it is wrong: a delta carries
additions and edits and silently misses **deletions** and renames, so a file removed privately
lives on in public for ever. A mirror cannot miss one, and it is idempotent — run it twice and
the second run publishes nothing.

**4. `Memory/` never leaves, by rule.**
⛔ Not by `.gitignore`: neither repository ignores it, because the private one **tracks** it on
purpose. The exclusion lives in the script, and the `Memory/` line in the public `.gitignore`
is the second lock.

**5. `.gitignore` belongs to the public repository and is never mirrored.**
Two reasons. It is the only thing keeping the work log out by hand, so no private edit may
remove it. And the private file's rules are written for a repository that tracks `Memory/` —
publishing them would carry a rule that contradicts its own purpose. ⚠ Because it is never
mirrored, a **new private ignore rule never arrives either** — so the script prints the
difference on every run. Silent drift is what is being avoided, not drift.

⚠ The `.gitignore` line inside the public `.gitignore` is **documentation of intent, not
enforcement**: that file is tracked there, and git's ignore rules do not apply to tracked
files. What actually stops the private one travelling is `PUBLIC_OWNED` in the script.

**6. After every sync it ensures these rules exist in the public `.gitignore`:**
`Memory/`, `.gitignore`, `CLAUDE.local.md*`, `__pycache__/`, `*.pyc`.

**7. Every publish is secret-scanned, with a positive control.**
This is the one direction where a mistake cannot be taken back, so an empty result must be
distinguishable from a scan that never ran. ⛔ The only exemption is keyed on the **matched
string** — a match containing `FAKE`, `NOT-A-REAL`, `EXAMPLE`, `PLACEHOLDER`, `DUMMY` or
`REDACTED` is not a secret — never on a file or a path. A scanner taught to ignore *files*
ignores the wrong one the day a real key lands in a file somebody exempted last year.

**8. It checks the target can commit before it touches anything.**
⛔ A step that mutates before it knows it can finish turns one clear failure into two confusing
ones: a half-applied tree that the mirror's own idempotence then reads as "nothing to publish".

---

## What it does NOT do

- **It does not stamp a version.** This repository ships no manifest, so a snapshot is named by
  the private commit it came from and the day it was taken. ⛔ Do not add a version file just
  to make this look like `dispatch-guard`'s script — the private sha is the identifier that can
  actually be looked up.
- It does not touch the private repository at all.
- It does not delete `Memory/` from anywhere. It only declines to copy it.

## First-time setup of the public folder

The script needs `C:\WorkSpace\dev-workstation_public` to already be a git repository with the
GitHub remote and its own identity:

```bash
git init -b main C:/WorkSpace/dev-workstation_public
git -C C:/WorkSpace/dev-workstation_public remote add origin https://github.com/Dino9021/dev-workstation.git
git -C C:/WorkSpace/dev-workstation_public config user.name  "<name>"
git -C C:/WorkSpace/dev-workstation_public config user.email "<email>"
```

Then run the script once to have it write the `.gitignore`, and **commit that file by hand**:

```bash
python Tools/publish-public.py          # answer anything but `confirm`
git -C C:/WorkSpace/dev-workstation_public add -f -- .gitignore
git -C C:/WorkSpace/dev-workstation_public commit -F <a message file>
```

⛔ **That hand commit is not optional, and `-f` is not a typo.** The script stages
`.gitignore` only on a run that ADDS a missing rule; once every rule is present it is never
staged again, so it would sit untracked for ever and a clone would have no `Memory/` lock at
all. And while it is untracked it **ignores itself** — its own `.gitignore` line applies — so
`git status` shows nothing and a plain `git add` is silently refused.

## If it refuses

| it says | do |
|---|---|
| uncommitted changes to tracked files | commit them privately first |
| secret scan hits | look. If it is a fixture, put `FAKE` in the string — never widen the scanner |
| the public repository has no `user.name` / `user.email` | run the line it prints |
| `... is not a git repository` | run the first-time setup above |
| nothing to publish | the snapshot already matches the private HEAD |
