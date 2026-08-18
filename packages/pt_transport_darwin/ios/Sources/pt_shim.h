/* The smallest surface that answers three questions about the pinned backend:
 * is it linked into this image, what revision was it built from, and what bytes
 * does it compose for the first record it would send.
 *
 * WHY A SHIM AT ALL
 * The Dart side must be able to ask those questions on a phone, where the
 * measurement instrument in tools/first_record/first_record.c cannot run: that
 * one is a host program with a main(). This header is deliberately free of any
 * backend include, so bindings can be generated on a machine that has neither
 * the archives nor their headers.
 *
 * BUFFER CONTRACT
 * Both output functions use two-call length discovery: call with cap = 0 to
 * learn the true length, allocate, call again. When the buffer is too small
 * NOTHING is written, so a caller can never mistake a partial answer for a
 * whole one.
 *
 * WHAT THIS HEADER DOES NOT DO
 * It reports no compile-time flag to any caller. Whether the backend is linked
 * is a value returned at run time, matching the convention in
 * packages/native_transport/lib/src/pt_ffi.dart — a build that was compiled
 * without the backend answers 0 rather than failing to exist.
 */
#ifndef PT_SHIM_H_
#define PT_SHIM_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* `used` matters as much as `visibility`: without it the linker is free to
 * dead-strip a C symbol nothing in the image references, and the Dart side
 * looks symbols up in the process image at run time, where a stripped symbol is
 * indistinguishable from one that was never compiled. */
#define PT_SHIM_EXPORT __attribute__((visibility("default"), used))

enum {
  PT_SHIM_ERR_UNLINKED = -1, /* stub build: the backend is not in this image */
  PT_SHIM_ERR_ARG = -2,      /* buf is NULL with cap > 0, or cap is negative */
  PT_SHIM_ERR_INTERNAL = -3, /* the backend refused a call while composing    */
  PT_SHIM_ERR_ECH_REJECTED = -4, /* the peer read the configuration and refused it */
  PT_SHIM_ERR_TIMEOUT = -5,      /* the bounded wait expired before an outcome  */
  PT_SHIM_ERR_UNREACHABLE = -6,  /* nothing answered at that address           */
};

/* The two ways the exchange can FINISH. Both are positive and neither is zero,
 * so a caller who reaches for the usual `== 0` habit matches nothing and fails
 * loudly rather than quietly treating "the peer ignored it" as success — which
 * is the one distinction this probe exists to report. */
enum {
  PT_SHIM_ECH_APPLIED = 1, /* finished, and the peer used the supplied config */
  PT_SHIM_ECH_IGNORED = 2, /* finished, and the peer did not use it           */
};

/* 1 when the backend is compiled and linked into this image, 0 when this is a
 * stub build. Never reports what a compile-time flag says to a caller; the
 * caller sees only this value. */
PT_SHIM_EXPORT int32_t pt_shim_backend_linked(void);

/* The pinned revision the backend was built from, NUL-terminated when it fits.
 * Returns the length EXCLUDING the terminator, so a caller needs ret + 1 bytes.
 * Stub build: PT_SHIM_ERR_UNLINKED. */
PT_SHIM_EXPORT int32_t pt_shim_build_pin(char *buf, int32_t cap);

/* Composes the first record with the same public-API configuration as
 * tools/first_record/first_record.c:55-161 and returns its true length.
 *
 * There is no network and no peer: a memory pair stands in for the socket,
 * because a client hands its first record to the transport before any server
 * has spoken. Each call builds a fresh client object, so calling twice is safe
 * and the second answer does not depend on the first.
 *
 * Stub build: PT_SHIM_ERR_UNLINKED. */
PT_SHIM_EXPORT int32_t pt_shim_first_record(uint8_t *buf, int32_t cap);

/* Performs one exchange with a cooperating peer at host:port, offering the
 * caller-supplied configuration blob and asking for `inner_name`, and reports
 * what the peer did with that configuration: PT_SHIM_ECH_APPLIED,
 * PT_SHIM_ECH_IGNORED, or one of the negative codes above.
 *
 * MEASUREMENT ONLY, AND THE NAME SAYS SO
 * This probe does NOT check the peer's credentials. That is necessary to
 * measure the extension against a locally-run peer whose certificate no
 * authority signed, and it is exactly why this is named as a probe, takes no
 * payload, returns no connection, and cannot be reused as a general client:
 * there is nothing here to send or receive on.
 *
 * timeout_ms bounds the whole exchange. No value means "forever" — 0 is a
 * single non-blocking attempt and a negative value is PT_SHIM_ERR_ARG — so a
 * caller that wants to wait indefinitely must write the loop itself, in sight
 * of whoever reads it. Stub build: PT_SHIM_ERR_UNLINKED. */
PT_SHIM_EXPORT int32_t pt_shim_ech_probe(const char *host, int32_t port,
                                         const uint8_t *config,
                                         int32_t config_len,
                                         const char *inner_name,
                                         int32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* PT_SHIM_H_ */
