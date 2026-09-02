#!/usr/bin/env bash
# Create the Android release signing key.
#
# NOT RUN BY AUTOMATION, and not by anyone but the owner. This produces a
# credential: whoever holds it can ship an update that every installed copy
# will accept, and whoever loses it can never ship an update again. Google's
# store has no recovery for a lost upload key on a self-signed track, so the
# backup step below is the whole point of this script existing rather than
# being a line in a document.
#
# Run it once, on a machine you control, with the keystore written outside the
# repository. Then copy the .jks to two places that are not the same disk and
# not the same cloud account. Then verify you can read it back.
#
#   bash tools/make_android_release_key.sh ~/keys/liveresilient-release.jks
#
set -euo pipefail

OUT=${1:-}
[ -n "$OUT" ] || { echo "usage: $0 <path/to/keystore.jks>   (outside this repo)" >&2; exit 2; }

case "$(cd "$(dirname "$OUT")" && pwd)" in
  "$(git rev-parse --show-toplevel 2>/dev/null)"*)
    echo "refusing: $OUT is inside the repository. A signing key must never be committable." >&2
    exit 2;;
esac

[ -e "$OUT" ] && { echo "refusing: $OUT already exists — this script never overwrites a key." >&2; exit 2; }

command -v keytool >/dev/null || { echo "keytool not found; install a JDK." >&2; exit 2; }

echo "About to create a release signing key at: $OUT"
echo "You will be asked for a keystore password and a key password. Use a"
echo "password manager; there is no recovery if you lose them."
echo

keytool -genkeypair \
  -alias liveresilient \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -keystore "$OUT"

chmod 600 "$OUT"

echo
echo "Created. The signing-certificate fingerprint, which is what users can"
echo "check an APK against — publish it on a second channel:"
keytool -list -v -keystore "$OUT" -alias liveresilient | grep -E 'SHA256|SHA-256' || true

cat <<'NEXT'

Now, before you do anything else:

  1. Copy the .jks to two places that are not this disk and not the same cloud
     account as each other. A key that exists once does not exist.
  2. Store both passwords in your password manager, not in a file beside it.
  3. Write android/key.properties from key.properties.example, pointing at the
     path above. That file is gitignored — confirm with:
       git check-ignore -v apps/reference_app/android/key.properties
  4. Build one release APK and confirm it is signed by this key:
       apksigner verify --print-certs <apk>

A lost signing key means no updates for anyone who already installed. That is
worse than any bug this project will ever ship.
NEXT
