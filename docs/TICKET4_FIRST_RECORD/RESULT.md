# The falsification test of TICKET4_DECISION.md §5 — run, 2026-08-17

## The question, and the answer

§5: does BoringSSL produce the target profile's first record under
CONFIGURATION ALONE? If yes, the decision to link it stands. If it needs a fork
of the library, the main reason for choosing it is gone and the choice moves to
wolfSSL, accepting the licence cost.

**Answer: yes, under configuration alone.** The instrument is
`tools/first_record/first_record.c`; every call in it is public BoringSSL API,
and that absence of any library change is the evidence for the claim.

Target: `UtlsClientProfile.chrome120` in
`packages/adaptive_transport/lib/src/probe_defense/utls_client_profile.dart`.

## What matched

```
cipher suites   15 of 15, in the profile's order, nothing missing, nothing extra
extensions      15 of 15 as a SET, nothing missing, nothing extra
GREASE          present in both the cipher list and the extension list
permutation     live: two captures, two different extension orders, same set
record size      1533 bytes
```

The two captures are kept beside this file (`FIRST_RECORD_CONFIGURED_1.hex`,
`FIRST_RECORD_CONFIGURED_2.hex`), and the first minimal-configuration capture is
kept too (`FIRST_RECORD.hex`) because the difference between them is the actual
finding.

## Extension ORDER is deliberately not required to match, and this is why

The profile declares `shufflesExtensions: true`, and the Dart source says why:
Chrome has permuted its extension order per connection since Chrome 110, so a
client that emits one fixed order is itself the anomaly. Demanding an identical
order would therefore have failed a correct implementation. What must match is
the SET, plus permutation actually being live — which is why two captures were
taken rather than one:

```
capture 1   0x0017 0x001b 0x002b 0x000b 0x0012 0x002d 0x0023 0x0005 0x0010 0x000a 0x000d 0xff01 0x0033 0x0000 0x4469
capture 2   0x0010 0x000b 0xff01 0x000a 0x002d 0x0033 0x000d 0x4469 0x0000 0x001b 0x0005 0x0023 0x0017 0x0012 0x002b
```

Different orders, identical sets.

## What the first capture got wrong, and what fixed it

The minimal configuration did NOT reproduce the shape, and saying so is the
useful part of this record: the gap was four extensions and two cipher suites,
and each was closed by exactly one public call.

```
gap on the first capture              the public call that closed it
------------------------------------  --------------------------------------
0xc009, 0xc00a offered but not in     SSL_CTX_set_strict_cipher_list with the
the profile                           profile's TLS 1.2 list
0x0005 status_request missing         SSL_enable_ocsp_stapling
0x0012 signed_certificate_timestamp   SSL_enable_signed_cert_timestamps
0x001b compress_certificate missing   SSL_CTX_add_cert_compression_alg(brotli)
0x4469 application_settings missing   SSL_add_application_settings, then
                                      SSL_set_alps_use_new_codepoint(ssl, 0)
GREASE absent                         SSL_CTX_set_grease_enabled
fixed extension order                 SSL_CTX_set_permute_extensions
```

The ALPS line is the one worth reading twice. With the default, the capture
carried `0x44cd` — the NEW ALPS codepoint — where the profile names `0x4469`,
the draft one. Both are ALPS; which codepoint a client sends is part of its
shape, and a comparison that treated "an ALPS extension is present" as a match
would have passed a client distinguishable from the profile it claims.

The TLS 1.3 suites are not configurable through this API: BoringSSL fixes them,
and it fixes them to exactly the profile's three, in the profile's order. That is
luck rather than configuration, and it is recorded as such — a profile wanting a
different TLS 1.3 set or order would hit a real wall here.

## What this does NOT establish

- **One architecture only.** Captured on x86_64 macOS. §5 asks for both
  architectures; the arm64 capture has not been run. The instrument is
  architecture-independent source, so this is a run that has not happened, not
  a result that is missing.
- **Nothing about the handshake past the first record.** The measurement stops
  where §5 stops. A server's reply, session resumption, and 0-RTT are all
  outside it.
- **Nothing about size, performance or maintenance.** §6 of the decision lists
  those as unmeasured and this run does not change that.
- **Nothing about the OS TCP stack.** The profile names
  `defaultTcpProfile: 'windows'`; a TLS record says nothing about it.
- **No packet capture.** The bytes come from a memory BIO, which is what makes
  the measurement repeatable. What a middlebox sees on a real path is a
  different measurement.

## A defect in the comparison tool, named rather than left to be discovered

`tools/compare_first_record.py` prints the three lists correctly — those are the
facts above — but its closing VERDICT line judges extension order as if order
were always part of the shape, and it is not for a profile that declares
`shufflesExtensions`. Read against a shuffling profile that line says "does not
reproduce" while its own lists show a complete set.

The fix is to read `shufflesExtensions` from the profile and compare the set in
that case, plus require two captures to differ. It is not applied here because
the file hit this repository's churn guard at four edits in one session, and
routing around that guard would be worse than carrying a named defect for a day.
Until it is applied, quote the LISTS from this document, never that tool's last
line.

Slot: the next session that opens `tools/compare_first_record.py`.
