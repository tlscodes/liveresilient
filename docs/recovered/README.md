# Work that was destroyed here, and what is left of it

## 2026-08-18 — the narrator's evidence wiring

**What happened.** During the night run I switched branches with a dirty working
tree. Files that had been sitting modified-but-uncommitted from earlier sessions
were reverted, and files that a side branch had newly tracked were deleted. Two
restore passes put back everything that existed on that side branch
(`30b8d68`, `cd5f2ac`), but one piece could not be restored from anywhere,
because it had never been committed to any branch and was only ever on disk.

**What is gone.** Uncommitted changes to
`packages/on_device_assistant/lib/src/rule_based_assistant.dart` that added an
evidence-citation mechanism — at minimum a `setEvidenceSource(...)` entry point
taking a `List<String> Function()`. The committed version of that class has no
citation mechanism at all, so this was a feature in progress, not a one-line
setter.

**What survives.** Its caller AND the tests written against it, preserved as
diffs in this directory:

```
docs/recovered/intelligence_director_uncommitted_2026-08-18.diff
docs/recovered/intelligence_director_test_uncommitted_2026-08-18.diff
```

The test half was found the way it should be: the workspace suite went red on
`intelligence_director_test.dart` — two cases expecting the citation feature —
after the caller had been reverted. Both halves are now back at the same
committed state, so the tree is consistent rather than half-migrated, and both
diffs are here.

It shows the intended design clearly: the assistant cites the newest ids from
the hub's persisted evidence ring, and each connectivity snapshot journals the
two measurements it observed *before* narrating, so a narration cites exactly
the measurements it was based on and both survive a restart.

**Why the caller was reverted rather than kept.** With the callee's half gone,
`intelligence_director.dart` did not compile —
`The method 'setEvidenceSource' isn't defined for the type 'RuleBasedAssistant'`
— and a tree that does not compile hides every other result. The caller is back
at its last committed state (`2689c17`), which is green, and the intent is in
the diff above rather than in anybody's memory.

**Why the assistant's half was not re-authored.** Guessing a destroyed API from
its call site would have put a design nobody chose into a feature somebody else
was building. The diff records what the call expects; the person who wrote it
can restore it in minutes and will get it right.

**The lesson, so it does not happen twice.** Staging by directory
(`git add -A <dir>`) on a tree carrying other people's uncommitted work decides
what a later branch switch keeps. Stage by file; before switching branches, look
at what is modified-but-uncommitted and commit or stash it explicitly.
