#!/bin/bash
# Builds and runs tools/ech_probe_host.c — the same probe the phone runs, in a
# process on this machine that can definitely reach the helper.
#
# Its whole purpose is to separate "the probe is wrong" from "the phone cannot
# reach this host". It links packages/pt_transport_darwin/ios/Sources/pt_shim.c
# itself, so a green here is a statement about the shipped shim and not about a
# reimplementation of it.
#
# Reads the address, port, configuration list and inner name out of the recorded
# helper configuration, so it cannot be run against a peer nobody started.
#
#   exit 0  the peer applied the configuration
#   exit 1  it answered something else — the answer is printed
#   exit 2  the helper's recorded configuration is missing or incomplete
#   exit 3  the pinned archives are not built for the host

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${BORINGSSL_SRC:-$HOME/.cache/tlsapi/boringssl}"
HELPER="$REPO/docs/evidence/step5_helper_config.txt"
BIN="${TMPDIR:-/tmp}/ech_probe_host"
HOST="127.0.0.1"

[ -f "$HELPER" ] || { echo "no recorded helper configuration at $HELPER" >&2; exit 2; }
[ -f "$SRC/build-host/libssl.a" ] || { echo "the host archives are not built" >&2; exit 3; }

field() { awk -F': ' -v k="$1" '$1==k {print $2; exit}' "$HELPER"; }

PORT="$(field port)"
CONFIG_HEX="$(field ech_config_list_hex)"
INNER_NAME="$(field real_name)"
PIN="$(field pin)"
[ -n "$PORT" ] && [ -n "$CONFIG_HEX" ] && [ -n "$INNER_NAME" ] || {
  echo "the recorded configuration is incomplete" >&2; exit 2; }

# clang++ drives the link because the library's own ssl target is C++; the
# source is still compiled as C, which is what a real embedder does through the
# public headers. `-x none` after the sources matters: without it the archives
# are handed to the C front end.
clang++ -O1 -I "$SRC/include" \
  -DPT_SHIM_HAVE_BORINGSSL=1 -DPT_SHIM_BORINGSSL_PIN="${PIN:0:8}" \
  -o "$BIN" \
  -x c "$REPO/tools/ech_probe_host.c" \
       "$REPO/packages/pt_transport_darwin/ios/Sources/pt_shim.c" \
  -x none "$SRC/build-host/libssl.a" "$SRC/build-host/libcrypto.a" || {
  echo "the harness did not compile" >&2; exit 3; }

"$BIN" "$HOST" "$PORT" "$CONFIG_HEX" "$INNER_NAME"
