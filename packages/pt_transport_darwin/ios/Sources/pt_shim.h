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

#ifdef __cplusplus
}
#endif

#endif /* PT_SHIM_H_ */
