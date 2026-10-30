#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Sign a release's firmware for over-the-air updates, on the release machine.
#
#   tools/sign_release.sh DIR
#
# DIR holds the firmware .bin files and SHA256SUMS downloaded from the draft
# release that CI built. Each app image is checked against SHA256SUMS, signed
# for its role and chip, and written next to it as <name>-ota.bin; SHA256SUMS
# gets their lines. Upload the -ota.bin files and the new SHA256SUMS to the
# draft. The key never leaves this machine (docs/RELEASING.md).
set -euo pipefail
shopt -s nullglob

DIR="${1:?usage: tools/sign_release.sh DIR}"
KEY="${OTA_KEY:-$HOME/.keystores/oui-snitch-ota.pem}"
SIGN="$(cd "$(dirname "$0")" && pwd)/sign_firmware.py"

[ -f "$KEY" ] || { echo "no signing key at $KEY (set OTA_KEY)"; exit 1; }
[ -f "$DIR/SHA256SUMS" ] || { echo "no SHA256SUMS in $DIR"; exit 1; }
cd "$DIR"

# Release asset board name -> chip, as built in release.yml.
chip_of() {
  case "$1" in
    xiao_s3|s3_devkitc|tdongle_s3) echo esp32s3 ;;
    xiao_c5|tdongle_c5)            echo esp32c5 ;;
    xiao_c3)                       echo esp32c3 ;;
    wroom|stickc|stickc_plus|stickc_plus2) echo esp32 ;;
    *) return 1 ;;
  esac
}

n=0
for f in oui-snitch-*.bin; do
  case "$f" in *-bootloader.bin|*-partitions.bin|*-boot_app0.bin|*-ota.bin) continue ;; esac
  grep -q "  $f\$" SHA256SUMS || { echo "$f is not in SHA256SUMS"; exit 1; }
  grep "  $f\$" SHA256SUMS | sha256sum -c --quiet -
  # oui-snitch-<role>-<board>-<version>.bin
  rest="${f#oui-snitch-}"
  role="${rest%%-*}"; rest="${rest#*-}"
  board="${rest%-v*}"
  case "$role" in node) ;; mgr) role=manager ;; *) echo "$f: unknown role $role"; exit 1 ;; esac
  chip="$(chip_of "$board")" || { echo "$f: unknown board $board"; exit 1; }
  out="${f%.bin}-ota.bin"
  rm -f "$out"
  python3 "$SIGN" sign --key "$KEY" --target "$role-$chip" "$f" "$out"
  python3 "$SIGN" verify --target "$role-$chip" "$out" >/dev/null
  sed -i "/  ${out//./\\.}\$/d" SHA256SUMS
  sha256sum "$out" >> SHA256SUMS
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "no firmware images in $DIR"; exit 1; }
echo
echo "Signed $n image(s). Upload to the draft release:"
ls -1 *-ota.bin
echo "SHA256SUMS (replace the existing one)"
