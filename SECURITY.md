# Security policy

## Reporting a vulnerability

Report privately through GitHub's **private vulnerability reporting** on this
repository (Security → Report a vulnerability). Please do not open a public
issue for a security problem.

Expected first response: **within 7 days.** If a report is confirmed, we agree
a disclosure date with the reporter; the default is 90 days or the day a fix
ships, whichever comes first.

Supported for fixes: the latest release on the default branch. There are no
long-term support branches yet.

## What this project has NOT had

**No independent security audit has been performed.** Nothing in this
repository should be read as an audited guarantee. An external audit is
planned and is part of the project's funding roadmap; until it happens, treat
every security property below as *designed and tested by the authors*, not
*verified by a third party*.

## Trust boundaries, stated plainly

- **Media encryption** uses the WebRTC standard path: DTLS-SRTP. Call content
  is encrypted between endpoints. **Metadata is not hidden**: a network
  observer can see that a session exists, its size and timing, and the
  addresses involved.
- **The datagram lane** used for bulk transfers on lossy links does not yet
  carry its own end-to-end encryption layer. This is a known gap; closing it
  (a Noise or DTLS layer over that lane) is tracked work, not a completed
  feature. Do not assume parity with the media path.
- **The signalling server** sees connection metadata by construction: which
  identifiers are talking, and when. It is not designed to see message
  content.
- **Nothing verifies the DTLS fingerprint out of band.** The media path and the
  text data channel both ride DTLS, which protects them from an observer on the
  network. It does not protect them from the party that relays the session
  description: a signalling server that is malicious or coerced can substitute
  fingerprints and sit in the middle of a call or a conversation. Until the two
  parties can verify the binding themselves, do not read the encryption on
  those lanes as end-to-end against the server.

  The planned fix is the established one rather than a novel design: a safety
  number derived from both parties' long-term identity keys, displayed as
  digits and as a QR code, compared once in person or over a channel the
  signalling server does not control, and re-verified when it changes. Reading
  a short string aloud mid-call is the weaker fallback for parties who cannot
  meet, not the primary mechanism — a caller under duress can be talked past
  it, and it verifies one session rather than the identity behind it.
- **The Android transport library ships prebuilt.** `libpt_transport.so`
  (arm64-v8a and x86_64) is committed under `apps/reference_app/android/`
  because the Android build consumes it directly and no source build exists in
  this repository yet. A reader cannot currently reproduce those two files from
  source; building them from source is open work, and until it lands they carry
  the same caveat as any vendored binary.
- **Prebuilt native dependencies** are outside our audit surface. The WebRTC
  implementation arrives as a prebuilt binary through its package; we do not
  build it from source, and we cannot vouch for what upstream shipped. The
  package version is pinned in the lockfile so the exact binary is
  identifiable.
- **The ultralight codecs** in `packages/` are our own code, with their own
  tests and byte-budget gates.

## Operational advice for deployers

The code in this repository contains no server addresses, keys, or hostnames —
by design. Those belong to a deployment, not to the source tree, and should be
distributed to users through a channel you control rather than committed here.

## Measured claims

Performance numbers in this repository are produced by the gate scripts under
`tools/` and recorded with the log that produced them. Numbers measured on a
physical device are labelled as such and are not reproducible on CI runners.
A claim without a matching log line is a bug in our documentation — please
report it as one.
