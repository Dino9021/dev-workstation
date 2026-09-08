<!-- PORTABLE. Every rule here was paid for by a measured failure on a real project; none is
     a preference. Nothing in it names a specific codebase, so it can be adopted unchanged.
     Add your own project's incidents to your rule-history file, not to this one. -->

# Verification Lessons

**Required reading before you run, write, or edit any test harness, deployment step, or
hardware verification — and before you ANSWER any question about what a live system did,
does, or will do.** These rules bind CLAIMS, not just gates: a conversational answer is a
claim the owner acts on.

Rules only, as imperatives. When one of them catches something in your project, record the
incident in your rule-history file and leave this file alone.

## 1. Evidence standards

1. **A green suite is evidence of nothing on the path that has no coverage.** Measured: a
   mutation deleting an entire database table left the suite fully green, because every
   test exercised the pure half. Verify data-custody logic by executing against real
   constraint shapes (a scratch schema with the real foreign keys, or a live-shaped
   database) — never by suite colour, never by reasoning alone.
2. **When a claim can be executed, execute it.** A refuter that only reasons is half a
   refuter.
3. **The trigger is making a claim, not running a gate.** If a sentence asserts what a
   reachable system did, does, or will do — execute before speaking, or mark it plainly as
   a guess. This includes small mid-conversation sentences and queries against guessed
   table or column names.
4. **"every", "always", "never", "only" are measurements, not emphasis.** Writing one is
   making a claim. **Citing a handler is not citing a caller**: for "when does X happen?",
   the senders and call sites are the evidence — `git grep` them.
5. **"Already covered by X" is a coverage claim.** If X has not been opened in this
   session, the sentence is a guess wearing a citation's clothes. Re-read before dismissing;
   when recording something twice costs four lines, prefer the redundancy to the argument.
6. **Keep corrections as corrections** — strike through the wrong text and leave it
   visible. A silent rewrite destroys the evidence that the project once believed something
   else, which is exactly what the next reader needs.

## 2. Instruments — the measurement lies before the system does

1. **A zero against a wrong, unreadable, or unfollowed path is indistinguishable from a
   real absence.** Confirm the path resolves and is readable BEFORE trusting zero
   (symlinks: `find` does not follow them and `ls` does; permissions; directories that do
   not exist from the current working directory).
2. **A truncated view answers confidently and wrongly — worse than a zero, because a zero
   invites doubt and a plausible list does not.** `git log -N`, a file reader's first page,
   `head`, `LIMIT`, `git log <file>` without `--follow`. Before concluding anything about a
   WHOLE from a listing, ask what the command left out, and prefer a command that answers
   the actual question (`git branch --contains`, `git merge-base --is-ancestor`) over
   generalising from a window.
3. **An explanation of a measurement failure is itself a measurement — verify it too.**
4. **A state-changing remote command must (a) run from a file** — copy a script over, invoke
   it by path — **and (b) print BEFORE and AFTER measurements of what it changed, from
   inside the script.** The readback that decides must come from a DIFFERENT invocation than
   the one that wrote. Measured twice on one box: nested quoting (shell → ssh → remote
   shell) turned a deploy into a silent no-op that printed nothing and reported nothing;
   "deployed" and "did nothing" are byte-identical on stdout.
5. **A noise filter can delete the signal, and it looks exactly like the feature not
   working.** Measured: a filter hiding an ssh banner containing the word "warning" also
   removed every `[warning]`-level line the product emitted — which is the level security
   refusals are logged at. Check a filter's vocabulary against the tool you are actually
   reading, and prefer filtering FOR what you want, with a positive control.
6. **`| head` / `| tail` replaces `$?` with the pipe's.** Run the search bare, read `$?`,
   and pipe it for readability only as a second command.
7. **A status code with two causes needs a control** — an anonymous or unauthenticated
   request separates "the resource is restricted" from "your session is invalid".
8. **Error sentinels must not compare equal.** Two failed lookups both returning `'?'` pass
   an equality assertion vacuously. Guard both sides against the sentinel.
9. **Read the verdict from the artefact, not the wrapper.** A compound command's exit code
   is the last command's; read the harness's own PASS/FAIL line out of its log.
10. **Reconcile every count against a second source.** A prose baseline that cannot be
    re-derived is drift waiting to be believed. `count()` on an associative array counts
    KEYS. A comment stating a marker's count, spelled literally, counts itself.
11. **A substring match is not a token match.** Anchor on the real token or settle it
    behaviourally — a substring search reported a rename as deployed while the old code was
    live, then reported the old name as present when the only hit was a comment about the
    rename.
12. **A probe that succeeds OUTSIDE the failing context refutes nothing.** Measured: a
    service under a filesystem sandbox died creating a directory that a manual command as
    the same user created successfully — same user, same path, different filesystem view.
    Reproduce a failure INSIDE the environment that produced it; for a service, starting the
    real unit IS the matching probe and costs one command.
13. **A success marker printed unconditionally is evidence of nothing.** Announce what the
    system SAYS — read the state back and assert on it — never what was attempted. Watch for
    a failure routed to `/dev/null` with its status eaten by `|| true`, under a marker whose
    entire purpose was to stop silence being read as evidence.
14. **Same table, two writers, two row shapes.** Before asserting on a record's shape, find
    the writer OF THE ROW THE CONSUMER READS, and prefer borrowing the product's own working
    reader to authoring a new one.
15. **Cross-platform text tools:** Windows and Unix `sort` collate differently, so a diff
    over their outputs is confident garbage — force the same collation on both sides. ANSI
    colour codes defeat anchored patterns; strip them before counting, or every count is 0.

## 3. Mutation testing — a mutation run is TWO measurements: "did it apply" and "what did it do"

1. **Diff or hash the file before trusting a green mutation result.** A pattern that
   silently removed nothing reads exactly like a guard nobody pinned.
2. **A hash change is not a semantic change.** A block inserted one line above its intended
   position applies, hashes differently, and behaves identically. Diff the BEHAVIOUR: state
   which line now runs in which order, and confirm the mutation expresses the defect you are
   trying to reintroduce.
3. **A mutation that fails to COMPILE, followed by a suite run, measures the previous binary
   and reports success.** This is the worst member of the family — a green result produced
   by code that was never built. Read the build's exit status, or a line only a successful
   link prints, BEFORE reading the suite's.
4. **A compiled suite measures the BINARY.** Rebuild after every edit and every revert.
   Write the revert command down BEFORE applying the mutation — an interrupted loop leaves
   the tree mutated.
5. **A copy is not a revert if it preserves the source timestamp.** The build system then
   has nothing to do, the compiler exits 0, the binary still contains the mutation — and a
   hash check confirms the source is correctly restored. Both halves report success.
   Restore with something that updates mtime, and **end every mutation round with a revert
   control run that must come back fully green.**
6. **Know your compiler's argument evaluation order.** Several commands placed in one
   argument list can run in an order you did not write, so the setup never exists when the
   attack is tried and the probe confidently reports "ineffective". Sequence each command as
   its own statement and print its return code.

## 4. Tests that do not test

1. **A test file the runner never scanned reads as coverage** — the most expensive kind of
   nothing. A new test must move the suite's total; prefer discovery over a hardcoded list
   of directories.
2. **Configuration read at the wrong nesting is a silent no-op switch.** The operator sets
   the value, nothing happens, no error appears anywhere, and the next person concludes the
   feature does not work rather than that it was never read. Open the accessor instead of
   assuming its shape.
3. **One green run of a concurrency test is a coin toss.** Run it until you have seen it
   pass a double-digit number of times — a property that holds "usually" is not a property.
   And when a concurrency assertion fails, **suspect the assertion first**: it encodes what
   you believed the design promised, and that belief is younger and less tested than the
   design.

## 5. Deploy and data safety

1. **Deploy fidelity is not commit fidelity.** Before recording a hardware PASS, confirm
   every file the run exercised matches a COMMITTED blob, not the working copy. Ship from
   the commit, never by copying a working tree — line-ending differences alone break some
   targets.
2. **Merge a verified fix into the trunk before, or immediately after, recording the PASS.**
   Measured: a hardware-proven security fix lasted fifteen hours, then the target was
   reinstalled from a branch that never contained it and the defect reproduced 24 minutes
   later. Nothing failed and nothing warned. Blob fidelity to *some* commit is not the fix
   being in the line of code that ships.
3. **The live partition is live.** Exclude the current period/shard from any selection that
   drops; import a snapshot only when its target is ABSENT (imports usually drop and
   recreate); delete a snapshot the moment its restore is done. Rows written between a
   snapshot and a restore are gone forever.
4. **Under `set -e`, your error handling runs only if you let it.** `out="$(cmd)"` dies
   before any status check or cleanup that follows it — exactly when the cleanup was needed.
   Use `rc=0; out="$(cmd)" || rc=$?` for capture, and an idempotent `trap '_restore' EXIT`
   as the net that survives any death.
5. **Walk a delete's foreign keys before shipping it** — which cascade, which restrict, and
   what a partial failure leaves behind when the audit record is written first. **Put the
   refusal on the class that performs the destructive act, not on each caller**: a check in
   one front door is a check the other front doors do not have.
6. **A check-then-act on shared state is not made single-use by adding the act.** The read
   and the write must be one indivisible step — a locking read inside the transaction that
   clears it, or a conditional update whose affected-rows count IS the verdict. Guard the UI
   too: a confirmation dialog with no disabled state can be double-clicked. **And a comment
   asserting a property is not the property** — it is worse than silence, because the next
   reviewer reads it and stops.
7. **A credential must not authorise replacing the authority that issued it.** An action
   that changes WHO the trust anchor is must be authorised by something that anchor did not
   grant — a locally provisioned credential, an out-of-band ceremony, or a second party. The
   tell is an asymmetry in cost: wherever issuing a capability is expensive and spending it
   is cheap, look hard at what the cheap side can reach. And **state what a mitigation
   narrows the exposure TO**, not what you would like it to have narrowed it to.

## 6. Gates and staged runs

1. **Gates go stale when interfaces move.** Any redesign of a route, a credential, or a
   lifecycle owes a re-run — or an explicit banner — of every gate that touches it.
2. **Localized pages break English-literal assertions, and can pass them vacuously.**
   Assert structural markers (a CSS class, a redirect target, an HTTP code) or accept every
   locale's string; never grep text that a translation layer renders.
3. **Run hygiene is load-bearing.** Run only what each pause asks, reset every box between
   attempts, and treat any count that differs from a clean run's as a stop signal. When
   driving a queue-based harness: run the step, READ its result, and only then feed the next
   — never in one compound command.
4. **When you copy a working implementation, copy its ENUMERATION as well as its query.** A
   fix that borrows the query and leaves the enumeration behind cannot see the records the
   old enumeration never visited. **And when you add a fail-closed guard, state which class
   of failure it cannot see** — a net named "fail closed" reads like total coverage.

## 7. Reviews, fixes, and records

1. **Same-day, same-author work gets adversarial review — including the supervisor's own
   hunks.** The code most likely to be waved through is the code you just wrote. It costs an
   agent-hour and has paid for itself every time it ran.
2. **The fix for a finding is new code, and the finding it creates is usually worse.**
   Measured: five rounds in one task, four of which found a real defect in the previous
   round's fix, including two of the highest severity that did not exist until somebody
   tried to be helpful. The shape is always the same — the finding names one property, the
   fix optimises for that property alone, and a second property nobody wrote down goes out
   with it. Before shipping a fix, say out loud what the OLD code was buying that the new
   code must keep, and send every fix back to the refuter.
3. **Implementing your own written prescription: open it and tick the clauses off.** "I know
   what I decided" is a coverage claim about your own memory — measured, the same author
   dropped one clause of their own design hours after writing it, and that omission was the
   highest-severity finding of the task.
4. **When implementation contradicts the design you wrote hours earlier, amend the design in
   the SAME change.** The window in which you still hold both halves is the only cheap
   moment.
5. **The record is part of the change, not a follow-up.** If the diff alters a behaviour any
   document describes, that document is in the diff. **And the reason a design looks odd is
   usually written next to it** — read the neighbouring comment before recommending a
   change to it.
6. **A review scoped to the diff will report on the diff.** Name a review by what it
   covered, not by what you hoped it covered, and draw at least one angle from what has NOT
   changed recently. A refuter tells you which findings are REAL; only a completeness critic
   tells you which QUESTIONS were never asked. Both are needed, and neither can be the
   person who drew the angles.
7. **When you edit a row in a findings table, read the rows you did not edit.** You already
   have the file open and the judgement calibrated — it is the cheapest audit that will ever
   be available for that document, and it expires when you close the file. **And a document
   claiming to supersede another is a claim: diff the two, do not adopt.** Regression
   presented as an update is invisible unless you look for it. Re-derive any list you were
   handed.
8. **When a handover cites a line number, open the line.** Not the file, not the function —
   the line. It is the part of a handover most likely to be trusted, least likely to be
   checked, and fastest to decay: every edit above it moves it. The facts a handover states
   about ITSELF are the ones nobody re-derives.
9. **An artefact that is not committed does not exist to anyone but you.** The session that
   wrote it still has it in its working tree, so from the inside the gap is invisible. `git
   add` it in the same breath as writing it — and before concluding something does NOT
   exist, list the directory it would live in.
10. **On a destructive path, check whether the action RAN before concluding that its guard
    did not appear.** A report carries the reporter's hypothesis, not the evidence's, and
    the audit record separates them faster than the screenshot. "Nothing happened" and "it
    completed silently" look identical from outside.

## 8. Answering "what is still open?"

Search for the RESOLUTION, never for markers of incompletion. A finished item is not
required to leave a marker — nobody edits a file to write "still done" — so a marker search
has no chance of being complete while the person running it feels thorough.

1. For each candidate ask "what would completion look like, and where would it have been
   written?" — a commit message, a ruling block, the code itself, another document's result
   column — then look there.
2. Prefer the CODE over any document for anything code-shaped.
3. An item you could not settle is **UNCONFIRMED**, not "open". They are different claims
   and a human acts on them differently. Say which, every row.
4. State the instrument per row, or the table cannot be audited.
5. Name what you did NOT sweep, so its silence does not read as "nothing there".
