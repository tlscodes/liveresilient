/* Prints the exact bytes of the first record an SSL client writes.
 *
 * WHY THIS IS A REAL FILE
 * It started as a heredoc inside tools/first_record_dump, which meant every
 * change to the measurement was a change to the runner — four in a row, until
 * the repository's churn guard objected. It was right: this is the measurement
 * INSTRUMENT and the runner is scaffolding around it. They change for different
 * reasons, so they are different files, and this one can be read, diffed and
 * compiled by hand.
 *
 * WHAT IT ANSWERS
 * docs/TICKET4_DECISION.md section 5: does BoringSSL produce the target
 * profile's first record under CONFIGURATION ALONE? Every line below is a
 * public API call. That is the whole point — a line that needed a library
 * change would itself be the answer "no", so the absence of any such line is
 * the evidence.
 *
 * The target is UtlsClientProfile.chrome120 in
 * packages/adaptive_transport/lib/src/probe_defense/utls_client_profile.dart.
 *
 * NO NETWORK, NO SERVER
 * A memory BIO pair replaces the socket. A client hands its first record to
 * the transport before any server has spoken, so this measurement needs no
 * peer — and with no peer it is repeatable and cannot be perturbed by what a
 * real server negotiates. SSL_connect stopping with WANT_READ after writing IS
 * the end of the measurement.
 *
 * Build (see tools/first_record_dump for the driver):
 *   clang++ -O1 -I <boringssl>/include -o first_record \
 *       -x c first_record.c -x none libssl.a libcrypto.a
 */
#include <stdio.h>
#include <string.h>

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/ssl.h>

/* Registering a certificate-compression algorithm is what puts the
 * compress_certificate extension on the wire. A client only ever needs the
 * decompress direction, and the API documents NULL for the other. Nothing
 * calls this — no server replies — so it refuses rather than pretending to
 * decode, which is the honest stub: a fake success here would be a lie about
 * a code path that never runs. */
static int refuse_decompress(SSL *ssl, CRYPTO_BUFFER **out, size_t uncompressed_len,
                             const uint8_t *in, size_t in_len) {
  (void)ssl;
  (void)out;
  (void)uncompressed_len;
  (void)in;
  (void)in_len;
  return 0;
}

int main(void) {
  SSL_CTX *ctx = SSL_CTX_new(TLS_method());
  if (ctx == NULL) {
    fprintf(stderr, "SSL_CTX_new failed\n");
    return 2;
  }

  /* The profile offers TLS 1.2 and 1.3; pinning both ends removes a variable
   * from the capture. */
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);

  /* The profile's TLS 1.2 cipher list, in its order.
   *
   * MEASURED, not guessed: without this call the first capture also offered
   * ECDHE_ECDSA_WITH_AES_128_CBC_SHA (0xc009) and its 256-bit sibling
   * (0xc00a), which the profile does not. The TLS 1.3 suites are not
   * configurable through this API — BoringSSL fixes them — and it fixes them
   * to exactly the profile's three, in the profile's order, which is why the
   * list below names only the 1.2 suites. */
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
    fprintf(stderr, "cipher list rejected\n");
    ERR_print_errors_fp(stderr);
    return 2;
  }

  /* The profile's ALPN, in its order. */
  static const unsigned char alpn[] = {2,   'h', '2', 8,   'h', 't',
                                       't', 'p', '/', '1', '.', '1'};
  SSL_CTX_set_alpn_protos(ctx, alpn, sizeof(alpn));

  /* GREASE (RFC 8701) and per-connection extension permutation. The profile
   * declares usesGrease and shufflesExtensions, and Chrome has permuted its
   * extension order per connection since Chrome 110 — so emitting a FIXED
   * order would itself be the anomaly the profile exists to avoid. One public
   * call each. */
  SSL_CTX_set_grease_enabled(ctx, 1);
  SSL_CTX_set_permute_extensions(ctx, 1);

  /* compress_certificate (0x001b), brotli = IANA id 2. */
  SSL_CTX_add_cert_compression_alg(ctx, 2, NULL, refuse_decompress);

  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    fprintf(stderr, "SSL_new failed\n");
    return 2;
  }
  SSL_set_connect_state(ssl);
  /* SNI: a name is part of the record's shape, so it must be set. */
  SSL_set_tlsext_host_name(ssl, "example.com");

  /* status_request (0x0005) and signed_certificate_timestamp (0x0012). */
  SSL_enable_ocsp_stapling(ssl);
  SSL_enable_signed_cert_timestamps(ssl);

  /* application_settings / ALPS (0x4469) — the extension BoringSSL added for
   * Chrome. Configured per ALPN protocol, so it goes on "h2". */
  static const unsigned char h2[] = {'h', '2'};
  if (!SSL_add_application_settings(ssl, h2, sizeof(h2), NULL, 0)) {
    fprintf(stderr, "ALPS configuration rejected\n");
    ERR_print_errors_fp(stderr);
    return 2;
  }
  /* MEASURED: with the default, the capture carried 0x44cd — the NEW ALPS
   * codepoint — where the profile names 0x4469, the draft one. Both are ALPS;
   * they are different codepoints for the same extension, and which one a
   * client sends is part of its shape. One public call selects the profile's. */
  SSL_set_alps_use_new_codepoint(ssl, 0);

  BIO *rbio = BIO_new(BIO_s_mem());
  BIO *wbio = BIO_new(BIO_s_mem());
  if (rbio == NULL || wbio == NULL) {
    fprintf(stderr, "BIO_new failed\n");
    return 2;
  }
  SSL_set_bio(ssl, rbio, wbio);

  int rc = SSL_connect(ssl);
  int err = SSL_get_error(ssl, rc);
  if (rc > 0 || (err != SSL_ERROR_WANT_READ && err != SSL_ERROR_WANT_WRITE)) {
    fprintf(stderr, "unexpected SSL_connect result rc=%d err=%d\n", rc, err);
    ERR_print_errors_fp(stderr);
    /* Not a hard exit: whatever reached the BIO is still the answer. */
  }

  const unsigned char *bytes = NULL;
  long n = BIO_get_mem_data(wbio, (char **)&bytes);
  if (n <= 0) {
    fprintf(stderr, "no bytes were written to the transport\n");
    return 3;
  }
  for (long i = 0; i < n; i++) printf("%02x", bytes[i]);
  printf("\n");
  fprintf(stderr, "%ld bytes captured\n", n);
  return 0;
}
