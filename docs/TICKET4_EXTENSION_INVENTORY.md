# Ticket 4 — what BoringSSL emits by default, measured

Date 2026-08-16. Method: read the extension table and the client assembly
function in the library's own source. Reproducible from a shallow clone.

```
source   ssl/extensions.cc:4087   the table, kExtensions[]
         ssl/extensions.cc:4495   ssl_add_clienthello_tlsext, the assembly
         include/openssl/tls1.h   the code points
```

This answers the one question `TICKET4_DECISION.md` §4-bis says the
decision now turns on: does the target profile need an extension BoringSSL
does not already emit? Everything below is what it emits, so a profile
built only from these needs no custom-extension API — which is exactly the
capability BoringSSL lacks.

## The table BoringSSL emits by default

26 entries in `kExtensions[]`. Each has an `add_clienthello` handler; most
are conditional on configuration, so a given connection sends a subset.

| code | extension | notes |
|---|---|---|
| 0x0000 | server_name | present when a hostname is set |
| 0x0005 | status_request | |
| 0x000a | supported_groups | order settable, `SSL_CTX_set1_curves*` |
| 0x000b | ec_point_formats | |
| 0x000d | signature_algorithms | |
| 0x000e | srtp | |
| 0x0010 | application_layer_protocol_negotiation | `SSL_CTX_set_alpn_protos` |
| 0x0012 | certificate_timestamp | |
| 0x0015 | padding | emitted by the library, see below |
| 0x0017 | extended_master_secret | |
| 0x001b | cert_compression | |
| 0x0022 | delegated_credential | |
| 0x0023 | session_ticket | |
| 0x0029 | pre_shared_key | always assembled last, after padding |
| 0x002a | early_data | |
| 0x002b | supported_versions | |
| 0x002c | cookie | |
| 0x002d | psk_key_exchange_modes | |
| 0x002f | certificate_authorities | |
| 0x0033 | key_share | |
| 0x0039 | quic_transport_parameters | |
| 0xff01 | renegotiate | |
| 0x4469 | application_settings_old | |
| 0x44cd | application_settings | |
| 0x7550 | channel_id | |
| 0x3374 | next_proto_neg | |

Also emitted, not table entries: `encrypted_client_hello` (0x0000 in the
ECH namespace) and `quic_transport_parameters_legacy`.

## Three behaviours the assembly function shows

**Order is permutable, not settable.** `ssl_add_clienthello_tlsext` walks
`kExtensions` through `hs->extension_permutation` when one exists
(`extensions.cc:4514-4517`). That vector is what `SSL_CTX_set_permute_extensions`
fills. So the caller can ask for a non-default order; the caller cannot ask
for one specific order. If the target profile needs a FIXED sequence, this
is not the mechanism for it — a distinction §4-bis already flagged as
unsettled and which this reading confirms.

**GREASE is bracketed, not sprinkled.** With `grease_enabled`, one empty
fake extension is added before the loop (`:4507`) and one non-empty fake
after it (`:4535`), per RFC 8701. Two, at fixed positions.

**Padding is the library's, not the caller's.** `TLSEXT_TYPE_padding` is
added at `:4549`, but only when the last real extension was empty, only
outside DTLS/QUIC/HelloRetryRequest, and always with a length of exactly 1.
The comment says why: a specific application server is intolerant of a
zero-length final extension. So the extension exists in the output, and the
caller can neither request it nor choose its size. Capability 5 in
`TICKET4_API_SURFACE.md` stays ABSENT, now for a precise reason rather than
an absent symbol.

## What this means for the decision

If the target profile is composed only of extensions in the table above,
BoringSSL's missing custom-extension API costs nothing, and its unique
ordering and GREASE control decide the choice. The list is broad — it
covers what a mainstream browser profile carries.

If the profile requires an extension NOT in the table, there is no public
route to add it, and the choice moves to wolfSSL under §7-bis's licence
cost, losing ordering control in the trade.

## Not measured

- The exact target profile has not been written down anywhere in this
  repository, so the comparison above is against the library's side only.
  Naming the profile's extension list is the remaining step, and it is the
  owner's input rather than a measurement — nothing in the source can
  supply it.
- Whether a fixed order is required, or merely a non-default one. The two
  need different mechanisms and only one of them exists here.
- Conditionality: the table lists what CAN be emitted. Which subset a real
  connection sends depends on configuration and was not enumerated per
  configuration.
