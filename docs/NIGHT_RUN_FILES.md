# Every file this night run created, and what each one is for

The companion to `docs/NIGHT_RUN_2026-08-18.md`: that one says what happened,
this one says where it lives. Written so a fresh session can start from the file
list alone, without reading the conversation that produced it.

Branch: **`plan-v4-waves-1-to-6`** (the working branch — `main` here is from
2026-07-29 and holds none of this). The step-6 migration is on
**`ticket4-second-member`**, unmerged.

## The instrument path — measuring the same thing on two machines

```
tools/first_record_dump                   MODIFIED. It used to compile an inline
                                          copy of the measurement program, four
                                          configuration calls older than the file
                                          beside it. Now it stages the real file.
tools/compare_arch_records.py             NEW. Compares two recorded records
                                          under a declared projection, and
                                          refuses a candidate that does not
                                          declare the architecture claimed.
docs/evidence/first_record_projection.json  NEW. Which fields may differ between
                                          machines, and why, per field.
docs/evidence/first_record_x86_64.txt     NEW. The host record, re-captured with
                                          the corrected instrument.
docs/evidence/first_record_arm64.txt      NEW. The phone's record, composed on
                                          the device through the shim.
tools/capture_device_record.sh            NEW. Drives the on-device measurement
                                          and separates "no phone", "the device
                                          refused the app", and "it ran and
                                          failed" — three different stories.
```

## The native path — the module, its bindings, and the app that links it

```
packages/pt_transport_darwin/ios/Sources/pt_shim.h   NEW. Four questions, no
                                          backend include, so bindings can be
                                          generated on a machine with no cache.
packages/pt_transport_darwin/ios/Sources/pt_shim.c   NEW. Two compile branches;
                                          the stub answers honestly everywhere
                                          the archives are absent.
packages/pt_transport_darwin/ios/pt_transport_darwin.podspec   MODIFIED. Links
                                          the pinned archives by absolute path
                                          resolved at install time, device SDK
                                          only, nothing vendored.
packages/native_transport/ffigen.yaml     NEW. Generation config; the generator
                                          is pinned exactly so regenerating is
                                          byte-identical.
packages/native_transport/lib/src/generated/shim_bindings.dart   NEW, generated.
packages/native_transport/lib/src/shim_probe.dart   NEW. The Dart side; a
                                          missing symbol is a STATE, not an
                                          exception.
packages/native_transport/test/shim_probe_test.dart   NEW. The absent path,
                                          which is what every host machine runs.
apps/reference_app/ios/Runner/Info.plist  MODIFIED. NSLocalNetworkUsageDescription
                                          — without it iOS refuses local-network
                                          connections outright.
```

## The device measurements

```
apps/reference_app/integration_test/first_record_on_device_test.dart   NEW.
                                          Asks the phone's process what it
                                          composes; derives the architecture
                                          rather than spelling it out.
apps/reference_app/integration_test/ech_probe_on_device_test.dart      NEW.
                                          Asks a peer to honour the offered
                                          configuration and reports what it did.
tools/probe_device_ech.sh                 NEW. Reads the peer's address and
                                          configuration out of the recorded
                                          helper file, so a pass cannot be
                                          against a peer nobody started.
tools/ech_probe_host.c / .sh              NEW. The same shim function from a host
                                          process — how "the probe is wrong" was
                                          told apart from "the phone cannot reach
                                          this host".
tools/t2/step5_helper.sh                  NEW. Starts the backend's own server
                                          locally with two different names and
                                          records the configuration served.
tools/t2/step7_trace.sh                   NEW, not yet runnable. The privileged
                                          capture; its header carries the exact
                                          sudoers line to grant it.
docs/evidence/step5_helper_config.txt     NEW. The configuration, as served.
docs/evidence/step6_probe_answer.txt      NEW. Every probe run, host and phone,
                                          including the route that worked.
```

## The ledger and the plan

```
docs/PLAN_REMAINING.md                    NEW. Seven steps, no status field;
                                          status is derived from evidence.
tools/plan_check.py                       NEW. Parses only fenced yaml blocks,
                                          runs nothing, names the next step.
docs/gate_backlog.json                    MODIFIED. 4a moved from `blocked` to a
                                          new `blocked_history` with what met
                                          each half of it.
packages/adaptive_transport/test/ticket4_device_probe_test.dart   NEW. Holds the
                                          recorded run to its words; its negative
                                          control rejects `ignored`.
docs/evidence/step1_host_build.txt        NEW. Pin, targets, archive architectures.
docs/evidence/step2_phone_build.txt       NEW. The same pin, arm64 archives.
docs/evidence/step3_bindings_manifest.txt NEW. Generator version, hashes, symbols.
docs/evidence/step6_suites_before_migration.txt   NEW. The green the migration left.
docs/evidence/step6_suites_after_migration.txt    NEW. The green it produced.
```

## The reports

```
docs/NIGHT_RUN_2026-08-18.md              Read this first.
docs/NIGHT_RUN_FILES.md                   This file.
docs/TICKET4_FIRST_RECORD/RESULT.md       MODIFIED. "One architecture" became
                                          "both", and a new section records that
                                          the runner had been compiling a stale
                                          instrument.
docs/TICKET4_INTEGRATION.md               MODIFIED. 4a closed with what met it.
docs/recovered/README.md                  MODIFIED tree, destroyed work: what was
docs/recovered/intelligence_director_uncommitted_2026-08-18.diff
                                          lost to a branch switch, and its intent
                                          preserved as a diff.
```

## On the other branch — `ticket4-second-member`

```
packages/adaptive_transport/lib/src/probe_defense/native_shape_availability.dart
                                          the second member, its probe report,
                                          and a resolver that refuses a yes with
                                          no provenance
packages/adaptive_transport/test/native_shape_availability_test.dart
apps/reference_app/lib/src/ui/network_truth.dart
apps/reference_app/test/native_shape_absent_surface_test.dart
apps/reference_app/test/ui/goldens/*.png  five baselines, compared before replaced
```

## Commits, oldest first

```
2ee2f04  the phone composes the same first record, and the instrument was stale
4b1747c  the capability probe answers, and says which question it answered
1693dd3  the phone answered applied, over the cable
2689c17  gate 4a closes: 39 of 40, and the last one needs a sudoers line
30b8d68  restore the working-tree state a branch switch reverted
cd5f2ac  restore the files the branch switch deleted, and commit them where they live
e84120f  the night report records the branch-switch mistake and both restores
6475d43  one piece of uncommitted work did not survive, and this says so
97251ae  (branch) the sealed type gains its second member, because the device answered
```
