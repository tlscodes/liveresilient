# Ticket 4 — the capability question, measured

Date: 2026-08-16. Method: shallow-clone each library, grep its PUBLIC
headers for the symbols that decide each capability. Reproducible — anyone
can re-run the greps and get the same table.

## Why this file exists instead of an adjudication

The capability ranking in `TICKET4_DECISION.md` §4 was engineering judgement,
and that file said so. The question was put to a model five times, in five
shapes, in fresh sessions, and stopped every time by the review pass.

It was never a question of opinion. A symbol either exists in a public
header or it does not. So it was answered the way every other cell in the
candidate table was answered: by running something.

Recorded per the consult rule: this scope is UNCHECKED by an external
adjudication, after five stops. The reason is written here rather than left
implicit.

## Headers scanned

```
BoringSSL   282     OpenSSL   520 (.h and .h.in)
mbedTLS      57     wolfSSL   587
rustls-ffi    1
```

OpenSSL ships its headers as `.h.in` templates; a first pass that globbed
only `*.h` reported it as ABSENT across the board. That was a measurement
error in the tool, not a property of the library, and it is recorded because
the same trap will catch the next person.

## The table

```
capability                    BoringSSL  OpenSSL  mbedTLS  wolfSSL  rustls-ffi
1 cipher list AND order         PUBLIC   PUBLIC   PUBLIC   PUBLIC     read-only
2 groups/curves AND order       PUBLIC   PUBLIC   PUBLIC   PUBLIC     ABSENT
3 add a custom extension        ABSENT   PUBLIC   ABSENT   PUBLIC     ABSENT
4 control extension ORDER       PUBLIC   ABSENT   ABSENT   ABSENT     ABSENT
5 client padding of a size      ABSENT   ABSENT   ABSENT   ABSENT     ABSENT
```

Evidence for each non-obvious cell:

```
1  SSL_CTX_set_cipher_list / SSL_CTX_set_ciphersuites (BoringSSL, OpenSSL,
   wolfSSL) · mbedtls_ssl_conf_ciphersuites (mbedTLS)
   rustls-ffi exposes only rustls_connection_get_negotiated_ciphersuite and
   rustls_accepted_cipher_suite — reading what was negotiated, not setting it.
2  SSL_CTX_set1_curves / _curves_list / _groups (BoringSSL, OpenSSL, wolfSSL)
   mbedtls_ssl_conf_groups (mbedTLS) · nothing in rustls.h
3  SSL_CTX_add_client_custom_ext / SSL_CTX_add_custom_ext (OpenSSL, wolfSSL)
   BoringSSL: grep for any symbol containing `custom_ext` in include/ returns
   NOTHING. mbedTLS's only match was conf_extended_master_secret, which is a
   named protocol feature, not an arbitrary-extension API.
4  SSL_CTX_set_permute_extensions (BoringSSL only). wolfSSL has no symbol
   containing Order, Permut or Shuffle anywhere in its headers.
5  OpenSSL's record_padding / add_record_padding are TLS RECORD padding, a
   different thing from a padding extension in the client's first message.
   wolfSSL's UseMaxFragment is fragment length, also different. Counted
   ABSENT for all five rather than credited on a near-match.
```

## What this changes

**No candidate has all five.** The two that matter split cleanly, and each
is missing what the other has:

- **BoringSSL** is the ONLY library exposing extension ORDER control
  (`SSL_CTX_set_permute_extensions`), and it also exposes GREASE control
  (`SSL_CTX_set_grease_enabled`, `SSL_CTX_set_grease_sigalgs_enabled`) —
  the levers that shape the message's shape. It has NO public API for adding
  an arbitrary extension.
- **OpenSSL and wolfSSL** expose arbitrary custom extensions but no ordering
  control at all.

So §4 of the decision file was too generous to BoringSSL on one axis and too
harsh on OpenSSL/wolfSSL on another. The measured position is narrower than
the adjudication assumed: **the choice turns on which of the two missing
halves the target profile actually needs.**

## What must be decided next, and it is one question

Does the target profile require adding an extension that BoringSSL does not
already emit?

```
NO   -> BoringSSL stands. Its ordering and GREASE control are unique among
        the five, and are the levers a profile needs most.
YES  -> BoringSSL cannot do it through its public API. The choice moves to
        wolfSSL (custom extensions, licence cost) — and even then, ordering
        would still be unavailable.
```

That is answerable by listing the extensions the target profile contains and
comparing them with what BoringSSL emits by default. It is another
measurement, not another opinion.

## Honesty limits of this inventory

- ABSENT means "no declaration matched the patterns searched". A library
  could expose the same power under a name not looked for. Read the header
  before acting on any ABSENT.
- Presence of a symbol is not proof it does what the name suggests, or that
  it is reachable in the build configuration this project would use.
- `SSL_CTX_set_permute_extensions` RANDOMISES order. Whether a profile needs
  a specific fixed order or merely a non-default one is not settled here,
  and the two are different requirements.

## Re-running this

```
cd ~/.cache/tlsapi   # clones live here, 729 MB
grep -rhoE '<pattern>' --include='*.h' --include='*.h.in' <lib>
```
