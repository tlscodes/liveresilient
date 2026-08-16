# Ticket 4 review, part A — licence, size, maintenance

Self-contained. Everything needed to answer Q1–Q3 is on this page; do not
open another file.

This part deliberately excludes the functional criterion that ordered the
candidates. That criterion is not an input to any question below — the
licence, the size measurement and the pinned-commit cost are the same
whatever the library is being used for — so it lives in a separate document
with its own questions.

---

## The measured table

Every figure came from a build run on one Mac, 2026-08-16. Commands, raw and
stripped byte counts, and architecture verification are recorded in
`docs/TICKET4_native_binding_candidates.md`.

```
                 licence            iOS arm64   Android     static, stripped   C ABI
BoringSSL        Apache-2.0         PASS 3m29s  PASS 3m27s   3.80 / 6.37 MB    direct
OpenSSL 4.0.1    Apache-2.0         PASS 7m02s  PASS 6m48s  10.21 / 13.54 MB   direct
mbedTLS 4.2.0    Apache or GPL-2    PASS 50s    PASS 44s     1.21 / 1.96 MB    direct
wolfSSL 5.9.2    GPLv3 or paid      PASS 15s    PASS 15s     0.92 / 1.42 MB    direct
rustls-ffi 0.15  permissive         PASS 2m46s  PASS 2m28s  20.07 / 26.69 MB   wrapper
```

Context for weighing these:

- The product is a Flutter application, closed source, shipped through app
  stores on iOS and Android. The library would be statically linked.
- The current build is a 128 MB arm64 app bundle.
- BoringSSL publishes no releases at all; using it means pinning a commit.
- rustls-ffi is a C wrapper over a Rust core and trails it by roughly three
  months of releases; it also adds a Rust toolchain to CI (measured: 2m34s
  and 246 MB of targets, plus a 304 MB build directory).
- mbedTLS 4.x broke its API against the 3.6 long-term-support line.

## What was NOT measured

The final linked contribution of any candidate to the 128 MB bundle. The
figures above are static-archive upper bounds, so they are not an answer to
"how much does the app grow". Between the two smallest candidates, size
decided nothing.

---

## The proposed decision, for context only

BoringSSL at a pinned commit, with wolfSSL as the backup. The reasoning that
ordered them is in the other document. Your job here is not to confirm that
order — it is to test the three claims below, each of which stands on its
own.

---

## Questions — answer one at a time

**Q1 — licence.** For a closed product shipped through app stores, does
GPLv3-or-commercial genuinely disqualify wolfSSL from being the default
choice, or is that overstated? If a commercial licence is the only route,
say plainly what that obligation looks like in practice.

**Q2 — the pinned-commit cost.** BoringSSL publishes no releases. Over a
three-year horizon, compare a pinned-commit policy against a library with a
stated support window and published advisories. Name what breaks first, and
what it costs when it does. Treat "no releases" as work moving to us, not as
work disappearing — or say why that framing is wrong.

**Q3 — the size claim.** The table ranks by static-archive size, but the
linked contribution was never measured. What would a correct comparison
actually require, what would it cost to run, and is it worth running at all
given the 128 MB baseline?

For each: if the honest answer is "the reasoning holds", say so and list
what you checked. Do not invent a disagreement to look thorough.
