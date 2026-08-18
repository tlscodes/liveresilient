/* Implementation of pt_shim.h.
 *
 * TWO BUILDS, ONE HEADER
 * When the pod is installed on a machine that has the pinned archives, the
 * podspec attaches PT_SHIM_HAVE_BORINGSSL and the linker flags, and the
 * composing branch below is compiled. Everywhere else — simulators, machines
 * without the cache — the stub branch is compiled and every function answers
 * honestly that the backend is not here. Neither branch reports the flag to a
 * caller; the caller reads a returned value.
 *
 * DUPLICATION, STATED
 * The configuration below mirrors tools/first_record/first_record.c:55-161 call
 * for call. That is a duplicate, and duplicates drift. What stops this one from
 * drifting silently is that step 4 of docs/PLAN_REMAINING.md compares the bytes
 * this file composes on the phone against the bytes that file composed on the
 * host: a divergence in configuration shows up as a failing comparison, not as
 * a surprise months later. The single-source alternative — one .c compiled by
 * both the pod and the host driver — is the better end state and is recorded
 * there as such; it was not taken tonight because changing the instrument that
 * produced the recorded baseline, in the same session that compares against
 * that baseline, would invalidate the thing being compared.
 */
#include "pt_shim.h"

#include <string.h>

#ifdef PT_SHIM_HAVE_BORINGSSL

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/ssl.h>

/* The pin arrives from the podspec unquoted, so it is stringified here rather
 * than escaped through Ruby, xcconfig and the compiler command line in turn. */
#define PT_SHIM_STRINGIFY_(x) #x
#define PT_SHIM_STRINGIFY(x) PT_SHIM_STRINGIFY_(x)

#ifndef PT_SHIM_BORINGSSL_PIN
#define PT_SHIM_BORINGSSL_PIN unknown
#endif

static const char kPin[] = PT_SHIM_STRINGIFY(PT_SHIM_BORINGSSL_PIN);

/* A client only ever needs the decompress direction, and the API documents NULL
 * for the other. Nothing calls this — there is no server — so it refuses rather
 * than pretending to decode: a fake success would be a lie about a code path
 * that never runs. */
static int pt_shim_refuse_decompress(SSL *ssl, CRYPTO_BUFFER **out,
                                     size_t uncompressed_len, const uint8_t *in,
                                     size_t in_len) {
  (void)ssl;
  (void)out;
  (void)uncompressed_len;
  (void)in;
  (void)in_len;
  return 0;
}

int32_t pt_shim_backend_linked(void) { return 1; }

int32_t pt_shim_build_pin(char *buf, int32_t cap) {
  const int32_t needed = (int32_t)strlen(kPin);
  if (cap < 0 || (buf == NULL && cap > 0)) return PT_SHIM_ERR_ARG;
  if (buf == NULL || cap < needed + 1) return needed;
  memcpy(buf, kPin, (size_t)needed + 1);
  return needed;
}

int32_t pt_shim_first_record(uint8_t *buf, int32_t cap) {
  if (cap < 0 || (buf == NULL && cap > 0)) return PT_SHIM_ERR_ARG;

  SSL_CTX *ctx = SSL_CTX_new(TLS_method());
  if (ctx == NULL) return PT_SHIM_ERR_INTERNAL;

  int32_t result = PT_SHIM_ERR_INTERNAL;
  SSL *ssl = NULL;

  /* The profile offers TLS 1.2 and 1.3; pinning both ends removes a variable
   * from the measurement. */
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);

  /* The profile's TLS 1.2 suites, in the profile's order. The 1.3 suites are
   * not configurable through this API and the library fixes them to exactly the
   * three the profile names. */
  if (!SSL_CTX_set_strict_cipher_list(ctx,
                                      "ECDHE-ECDSA-AES128-GCM-SHA256:"
                                      "ECDHE-RSA-AES128-GCM-SHA256:"
                                      "ECDHE-ECDSA-AES256-GCM-SHA384:"
                                      "ECDHE-RSA-AES256-GCM-SHA384:"
                                      "ECDHE-ECDSA-CHACHA20-POLY1305:"
                                      "ECDHE-RSA-CHACHA20-POLY1305:"
                                      "ECDHE-RSA-AES128-SHA:"
                                      "ECDHE-RSA-AES256-SHA:"
                                      "AES128-GCM-SHA256:"
                                      "AES256-GCM-SHA384:"
                                      "AES128-SHA:"
                                      "AES256-SHA")) {
    goto done;
  }

  {
    static const unsigned char kAlpn[] = {2,   'h', '2', 8,   'h', 't',
                                          't', 'p', '/', '1', '.', '1'};
    SSL_CTX_set_alpn_protos(ctx, kAlpn, sizeof(kAlpn));
  }

  /* GREASE and per-connection permutation: the profile declares both, and a
   * fixed order would itself be the anomaly the profile exists to avoid. */
  SSL_CTX_set_grease_enabled(ctx, 1);
  SSL_CTX_set_permute_extensions(ctx, 1);

  /* compress_certificate, brotli = IANA id 2. */
  SSL_CTX_add_cert_compression_alg(ctx, 2, NULL, pt_shim_refuse_decompress);

  ssl = SSL_new(ctx);
  if (ssl == NULL) goto done;
  SSL_set_connect_state(ssl);
  SSL_set_tlsext_host_name(ssl, "example.com");
  SSL_enable_ocsp_stapling(ssl);
  SSL_enable_signed_cert_timestamps(ssl);

  {
    static const unsigned char kH2[] = {'h', '2'};
    if (!SSL_add_application_settings(ssl, kH2, sizeof(kH2), NULL, 0)) goto done;
  }
  /* The draft codepoint, which is the one the profile names. */
  SSL_set_alps_use_new_codepoint(ssl, 0);

  {
    BIO *rbio = BIO_new(BIO_s_mem());
    BIO *wbio = BIO_new(BIO_s_mem());
    if (rbio == NULL || wbio == NULL) {
      if (rbio != NULL) BIO_free(rbio);
      if (wbio != NULL) BIO_free(wbio);
      goto done;
    }
    SSL_set_bio(ssl, rbio, wbio);

    /* Stopping with WANT_READ after writing IS the end of the measurement:
     * whatever reached the memory pair is the record. */
    (void)SSL_connect(ssl);

    {
      const unsigned char *bytes = NULL;
      long written = BIO_get_mem_data(wbio, (char **)&bytes);
      if (written <= 0 || bytes == NULL) {
        result = PT_SHIM_ERR_INTERNAL;
      } else if (buf == NULL || (int32_t)written > cap) {
        result = (int32_t)written;
      } else {
        memcpy(buf, bytes, (size_t)written);
        result = (int32_t)written;
      }
    }
  }

done:
  if (ssl != NULL) SSL_free(ssl);
  SSL_CTX_free(ctx);
  return result;
}

#else /* the backend is not in this image */

int32_t pt_shim_backend_linked(void) { return 0; }

int32_t pt_shim_build_pin(char *buf, int32_t cap) {
  (void)buf;
  (void)cap;
  return PT_SHIM_ERR_UNLINKED;
}

int32_t pt_shim_first_record(uint8_t *buf, int32_t cap) {
  (void)buf;
  (void)cap;
  return PT_SHIM_ERR_UNLINKED;
}

#endif
