/* Runs the SAME probe the phone runs, on this machine, against the same helper.
 *
 * WHY THIS EXISTS
 * When the on-device probe answers `unreachable`, two very different things
 * could be true: the probe is wrong, or the phone is not on this machine's
 * network. One of those is a defect in this repository and the other is a cable
 * and an access point. This harness separates them by exercising the identical
 * function — packages/pt_transport_darwin/ios/Sources/pt_shim.c — from a host
 * process that can definitely reach the helper.
 *
 * It links the shim itself, not a copy of its logic. A harness that reimplemented
 * the probe would answer a question about the harness.
 *
 * Build and run: tools/ech_probe_host.sh
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../packages/pt_transport_darwin/ios/Sources/pt_shim.h"

static int hex_to_bytes(const char *hex, unsigned char **out, int *out_len) {
  size_t len = strlen(hex);
  if (len == 0 || len % 2 != 0) return 0;
  *out_len = (int)(len / 2);
  *out = (unsigned char *)malloc(len / 2);
  if (*out == NULL) return 0;
  for (size_t i = 0; i < len / 2; i++) {
    unsigned int byte = 0;
    if (sscanf(hex + 2 * i, "%2x", &byte) != 1) {
      free(*out);
      return 0;
    }
    (*out)[i] = (unsigned char)byte;
  }
  return 1;
}

static const char *name_of(int32_t code) {
  switch (code) {
    case PT_SHIM_ECH_APPLIED: return "applied";
    case PT_SHIM_ECH_IGNORED: return "ignored";
    case PT_SHIM_ERR_ECH_REJECTED: return "rejected";
    case PT_SHIM_ERR_TIMEOUT: return "timedOut";
    case PT_SHIM_ERR_UNREACHABLE: return "unreachable";
    case PT_SHIM_ERR_ARG: return "badArgument";
    case PT_SHIM_ERR_UNLINKED: return "noBackendInThisProcess";
    default: return "internalFailure";
  }
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr,
            "usage: ech_probe_host <host> <port> <config-list-hex> <inner-name>\n");
    return 2;
  }
  unsigned char *config = NULL;
  int config_len = 0;
  if (!hex_to_bytes(argv[3], &config, &config_len)) {
    fprintf(stderr, "the configuration argument is not hex\n");
    return 2;
  }

  printf("backend_linked: %d\n", (int)pt_shim_backend_linked());

  char pin[128];
  int32_t pin_len = pt_shim_build_pin(pin, (int32_t)sizeof(pin));
  printf("build_pin: %s\n", pin_len > 0 ? pin : "(none)");

  int32_t code = pt_shim_ech_probe(argv[1], atoi(argv[2]), config, config_len,
                                   argv[4], 15000);
  printf("peer: %s:%s\n", argv[1], argv[2]);
  printf("inner_name_asked_for: %s\n", argv[4]);
  printf("outcome: %s\n", name_of(code));
  printf("outcome_code: %d\n", (int)code);

  free(config);
  /* The exit status is the machine-readable half: only "applied" is a zero. */
  return code == PT_SHIM_ECH_APPLIED ? 0 : 1;
}
