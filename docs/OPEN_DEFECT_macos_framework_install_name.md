# Open defect — the embedded macOS framework carries a build-machine path

Found by the packaging gate on its **first run on infrastructure that is not
the developer's Mac** (GitHub Actions, 2026-09-01, run 33482838982). It had
never been observed before because every previous build happened in one
directory, where a path baked into the binary still resolves.

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

## What is and is not wrong

The **shipped artifact in this repository is correct**. Every slice of
`packages/pt_transport_darwin/macos/Frameworks/PtTransport.xcframework`
reports the right identifier:

```
$ otool -D .../macos-arm64_x86_64/PtTransport.framework/PtTransport
@rpath/PtTransport.framework/PtTransport
```

The absolute path appears only in the **copy embedded during the macOS
release build**. So something in that build re-writes the identifier from
`@rpath/...` to the absolute location it happened to be built in. A binary
carrying that identifier resolves on the machine that produced it and fails
anywhere else — which is exactly the class of defect this gate exists to
catch, and it caught it the first time it ran somewhere else.

## Scope

- Affects: the macOS desktop release bundle.
- Does not affect: iOS builds, the Dart packages, the test suites, or any
  measurement in `h3_results.tsv` / `e2e_ios_results.tsv`.

## What must NOT be done

Do not relax `tools/check_embedded_framework.sh`. The check is correct and
the finding is real; widening its allowed-prefix list would convert a true
report into a silent shipping bug.

## Next step

Reproduce locally with `flutter build macos --release`, then read the
identifier of the embedded copy and compare it with the source slice. The
fix belongs wherever the identifier is being rewritten — the podspec's
embed/sign phase is the first place to look — and the gate then confirms it
without any change to the gate itself.
