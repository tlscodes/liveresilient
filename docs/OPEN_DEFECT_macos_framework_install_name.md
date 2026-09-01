# Resolved — the "build-machine path" in the embedded macOS framework was the gate misparsing otool, not the artifact

Reported by the packaging gate on its first run on GitHub Actions
(2026-09-01, run 33482838982, and identically on eleven runs after it).
Root-caused and fixed on 2026-09-01. **The shipped artifact was correct the
whole time**; the defect was in how `tools/check_embedded_framework.sh`
parsed `otool -L` output on the CI image's toolchain.

## What the gate saw

```
ok     reference_app.app embeds PtTransport.framework
FAIL   reference_app.app/PtTransport links paths that will not exist on a user's machine:
       /Users/runner/work/liveresilient/liveresilient/apps/reference_app/build/
       macos/Build/Products/Release/reference_app.app/Contents/Frameworks/
       PtTransport.framework/PtTransport
ok     reference_app.app/PtTransport exports 12 symbols
PACKAGING GATE FAILED
```

## Root cause

The embedded PtTransport binary is universal (x86_64 + arm64). On the
`macos-26` runner image (default toolchain Xcode 26.6), `otool -L` on that
binary emits the multi-architecture format — one section per slice, each
introduced by an unindented header:

```
<path-to-binary> (architecture x86_64):
	@rpath/PtTransport.framework/PtTransport (compatibility version 0.0.0, ...)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, ...)
<path-to-binary> (architecture arm64):
	...
```

The gate parsed that output positionally: `tail -n +2` dropped only the
first header, and `awk '{print $1}'` then read the second slice's header —
the binary's own absolute path — as if it were a linked library path. The
allowed-prefix list rightly rejected it, and the gate failed on a correct
artifact. Locally (Xcode 26.3), `otool -L` prints only the host slice, so
the same gate on the same bytes passed — which is why the failure appeared
only on infrastructure that was not the developer's Mac.

## The evidence

- CI's own linker saw the correct identifier at link time, in the very runs
  that failed: `ld: warning: ... linking with dylib
  '@rpath/PtTransport.framework/PtTransport'`.
- The flagged string is byte-identical to the path the gate itself passes to
  `otool` (`.../PtTransport.framework/PtTransport`, the top-level symlink,
  no `Versions/A`) — the echo of otool's argument in a slice header, not a
  path any tool would write into a load command.
- No component of the pipeline rewrites install names: the generated
  CocoaPods scripts (checked at 1.15.2, 1.16.2 and 1.17.0), the Flutter
  tool (3.44.6 through 3.44.8), the Runner project's build phases, and this
  repository contain no `install_name_tool` invocation on this framework.
- Reproduced locally: `otool -arch all -L <embedded binary>` fed through the
  old parsing pipeline flags exactly one "bad" path — the binary's own
  location — on a binary whose every load command is clean.

## The fix

`tools/check_embedded_framework.sh` now parses structurally instead of
positionally, and inspects every slice instead of whichever one the host
toolchain picks:

- `otool -arch all -L` pins the output to one format on every toolchain and
  covers x86_64 as well as arm64;
- only tab-indented lines (real load-command entries) are checked — header
  lines never are;
- the exported-symbol count runs per architecture (`nm -gU -arch <a>`), so a
  slice that lost its exports cannot hide behind a healthy one.

The allowed-prefix list is unchanged, character for character. The check is
strictly stronger than before: a doctored binary with an absolute
`LC_ID_DYLIB` still fails the gate (verified 2026-09-01), and the
2026-08-01 class of defect (an absolute `/usr/local/opt/openssl@3` link
path) is now caught in both slices, not just the host's.

## Scope

- Affects: only `tools/check_embedded_framework.sh` on toolchains that print
  per-slice otool output.
- Does not affect: the shipped xcframework, iOS builds, the Dart packages,
  or any measurement in `h3_results.tsv` / `e2e_ios_results.tsv`.
