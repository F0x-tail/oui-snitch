#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Builds the release APK to attach to a draft GitHub release, and refuses to
# produce one that would break updates: signed with anything but the release
# key, or carrying a version that does not match the tag (Obtainium compares
# the tag with the app's versionName).
#
# Needs android/key.properties (the release keystore) and the Android SDK
# build tools. Output: companion/build/release/oui-snitch-v<version>-arm64.apk
# and its .sha256 — attach both to the draft release by hand.
set -euo pipefail

# SHA-256 of the release signing certificate, as published in the README.
EXPECT_CERT=7f22ea7faa60473b603b76ead81231b2b0814d10d835121a91fe1f9450f62ec6

cd "$(dirname "$0")/../companion"
V=$(sed -n 's/^version: *\([0-9.]*\)+.*/\1/p' pubspec.yaml)
TAG="v$V"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
BT=$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)
[ -n "$BT" ] || { echo "Android build-tools not found (set ANDROID_HOME)"; exit 1; }

flutter build apk --release --target-platform android-arm64

APK=build/app/outputs/flutter-apk/app-release.apk
CERT=$("$BT/apksigner" verify --print-certs "$APK" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
[ "$CERT" = "$EXPECT_CERT" ] || { echo "Signed with $CERT, not the release key. Not publishing."; exit 1; }
NAME=$("$BT/aapt2" dump badging "$APK" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")
[ "$NAME" = "$V" ] || { echo "APK versionName $NAME does not match $V"; exit 1; }

mkdir -p build/release
OUT="build/release/oui-snitch-$TAG-arm64.apk"
cp "$APK" "$OUT"
(cd build/release && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Ready: companion/$OUT (+ .sha256), release key, versionName $V."
echo "Attach both to the draft release $TAG on GitHub, then publish it."
