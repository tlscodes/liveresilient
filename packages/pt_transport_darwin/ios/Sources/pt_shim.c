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

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

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

/* Accepts any credential. This exists only so the probe below can measure the
 * extension against a peer started for the measurement, whose certificate no
 * authority signed. It is deliberately not reachable from anything else in this
 * file, and the only function that installs it is named as a probe. */
static enum ssl_verify_result_t pt_shim_accept_any_credential(SSL *ssl,
                                                              uint8_t *out_alert) {
  (void)ssl;
  (void)out_alert;
  return ssl_verify_ok;
}

static int pt_shim_wait_writable(int fd, int32_t timeout_ms) {
  fd_set write_set;
  struct timeval tv;
  FD_ZERO(&write_set);
  FD_SET(fd, &write_set);
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  return select(fd + 1, NULL, &write_set, NULL, &tv);
}

int32_t pt_shim_ech_probe(const char *host, int32_t port, const uint8_t *config,
                          int32_t config_len, const char *inner_name,
                          int32_t timeout_ms) {
  if (host == NULL || inner_name == NULL || config == NULL || config_len <= 0 ||
      port <= 0 || port > 65535 || timeout_ms < 0) {
    return PT_SHIM_ERR_ARG;
  }

  int32_t result = PT_SHIM_ERR_INTERNAL;
  int fd = -1;
  SSL_CTX *ctx = NULL;
  SSL *ssl = NULL;
  struct addrinfo hints;
  struct addrinfo *addresses = NULL;
  char port_text[8];

  snprintf(port_text, sizeof(port_text), "%d", (int)port);
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, port_text, &hints, &addresses) != 0 || addresses == NULL) {
    return PT_SHIM_ERR_UNREACHABLE;
  }

  fd = socket(addresses->ai_family, addresses->ai_socktype, addresses->ai_protocol);
  if (fd < 0) {
    result = PT_SHIM_ERR_UNREACHABLE;
    goto done;
  }

  /* Connect without blocking, then wait at most the caller's budget. A phone
   * whose screen has locked can otherwise sit here far longer than the test
   * that called it is willing to live. */
  {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, addresses->ai_addr, addresses->ai_addrlen);
    if (rc != 0) {
      if (errno != EINPROGRESS) {
        result = PT_SHIM_ERR_UNREACHABLE;
        goto done;
      }
      int ready = pt_shim_wait_writable(fd, timeout_ms);
      if (ready == 0) {
        result = PT_SHIM_ERR_TIMEOUT;
        goto done;
      }
      if (ready < 0) {
        result = PT_SHIM_ERR_UNREACHABLE;
        goto done;
      }
      int sock_error = 0;
      socklen_t len = sizeof(sock_error);
      if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &sock_error, &len) != 0 ||
          sock_error != 0) {
        result = PT_SHIM_ERR_UNREACHABLE;
        goto done;
      }
    }
    if (flags >= 0) fcntl(fd, F_SETFL, flags);
  }

  /* The same budget bounds the exchange itself, so no phase is unbounded. */
  {
    struct timeval tv;
    int32_t bound = timeout_ms > 0 ? timeout_ms : 1;
    tv.tv_sec = bound / 1000;
    tv.tv_usec = (bound % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
  }

  ctx = SSL_CTX_new(TLS_method());
  if (ctx == NULL) goto done;
  SSL_CTX_set_custom_verify(ctx, SSL_VERIFY_PEER, pt_shim_accept_any_credential);

  ssl = SSL_new(ctx);
  if (ssl == NULL) goto done;
  SSL_set_connect_state(ssl);
  if (!SSL_set_fd(ssl, fd)) goto done;
  if (!SSL_set_tlsext_host_name(ssl, inner_name)) goto done;
  if (!SSL_set1_ech_config_list(ssl, config, (size_t)config_len)) {
    /* The blob the caller handed us is not a configuration list at all, which
     * is an argument fault rather than anything the peer did. */
    result = PT_SHIM_ERR_ARG;
    goto done;
  }

  ERR_clear_error();
  if (SSL_connect(ssl) == 1) {
    result = SSL_ech_accepted(ssl) ? PT_SHIM_ECH_APPLIED : PT_SHIM_ECH_IGNORED;
  } else {
    uint32_t reason = ERR_GET_REASON(ERR_peek_last_error());
    if (reason == SSL_R_ECH_REJECTED) {
      /* A failure that still proves the other side read the configuration. */
      result = PT_SHIM_ERR_ECH_REJECTED;
    } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT) {
      result = PT_SHIM_ERR_TIMEOUT;
    } else {
      result = PT_SHIM_ERR_INTERNAL;
    }
  }

done:
  if (ssl != NULL) SSL_free(ssl);
  if (ctx != NULL) SSL_CTX_free(ctx);
  if (fd >= 0) close(fd);
  if (addresses != NULL) freeaddrinfo(addresses);
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

int32_t pt_shim_ech_probe(const char *host, int32_t port, const uint8_t *config,
                          int32_t config_len, const char *inner_name,
                          int32_t timeout_ms) {
  (void)host;
  (void)port;
  (void)config;
  (void)config_len;
  (void)inner_name;
  (void)timeout_ms;
  return PT_SHIM_ERR_UNLINKED;
}

#endif
