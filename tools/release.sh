#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The whole release, on the release machine, in one go:
#
#   tools/release.sh X.Y.Z
#
#  1. checks: on main, in step with GitHub, nothing uncommitted, both keys
#     present, gh logged in, the tag not taken
#  2. bumps the version in all four places (docs/RELEASING.md step 1), with
#     the Android build number one higher than before
#  3. runs the host tests and builds the release APK, which must carry the
#     release key and the new versionName (tools/release_apk.sh). All of
#     this happens before anything is pushed, so a failure leaves nothing
#     public behind.
#  4. commits, tags and pushes over SSH; CI builds the firmware draft
#  5. waits for CI, downloads the draft's firmware, signs it for over-the-air
#     updates (tools/sign_release.sh) and uploads the -ota.bin files, the new
#     SHA256SUMS, the APK and its .sha256
#  6. checks the draft has exactly one APK (Obtainium stops on two), then
#     publishes it as Latest, and checks what was published against what was
#     built
#
# Both private keys stay on this machine. gh needs a login with access to the
# repository (gh auth login); git itself pushes over SSH.
#
# Env: COMMIT_TRAILER is appended to the release commit message if set.
set -euo pipefail

V="${1:?usage: tools/release.sh X.Y.Z}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z, got $V"; exit 1; }
TAG="v$V"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export JAVA_HOME="${JAVA_HOME:-$HOME/toolchains/jdk21}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/toolchains/android-sdk}"
export PATH="$JAVA_HOME/bin:$HOME/toolchains/flutter/bin:$HOME/.local/bin:$PATH"
OTA_KEY="${OTA_KEY:-$HOME/.keystores/oui-snitch-ota.pem}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n== %s\n' "$*"; }
die() { echo "release: $*" >&2; exit 1; }

# --- 1. preflight -----------------------------------------------------------
say "Checks"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
git fetch --quiet origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main differs from origin/main; push or pull first"
# The local Gradle memory caps are deliberately never committed.
DIRTY="$(git status --porcelain | grep -v ' companion/android/gradle.properties$' || true)"
[ -z "$DIRTY" ] || { echo "$DIRTY"; die "uncommitted changes; commit them first"; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists here"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on GitHub"
[ -f companion/android/key.properties ] || die "no companion/android/key.properties (APK release key)"
[ -f "$OTA_KEY" ] || die "no firmware signing key at $OTA_KEY"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
# The repository is the one we push to. Left to itself, gh picks the parent
# of a fork, which is the upstream project, not ours.
REPO="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
export GH_REPO="$REPO"
PERM="$(gh repo view "$REPO" --json viewerPermission -q .viewerPermission)"
[ "$PERM" = ADMIN ] || [ "$PERM" = MAINTAIN ] || [ "$PERM" = WRITE ] || die "gh has $PERM on $REPO, needs write"
echo "repo $REPO, releasing $TAG"

# --- 2. version bump ---------------------------------------------------------
say "Version $V"
IFS=. read -r MA MI PA <<<"$V"
NUM=$(printf '0x%02d%02d%02d' "$MA" "$MI" "$PA")
OLD_BUILD=$(sed -n 's/^version: *[0-9.]*+\([0-9]*\).*/\1/p' companion/pubspec.yaml)
[ -n "$OLD_BUILD" ] || die "no build number in companion/pubspec.yaml"
BUILD=$((OLD_BUILD + 1))
sed -i "s/^\(#define FW_VERSION  *\)\"[0-9.]*\"/\1\"$V\"/" src/protocol.h
sed -i "s/^\(#define FW_VERSION_NUM  *\)0x[0-9a-fA-F]*/\1$NUM/" src/protocol.h
sed -i "s/^version: .*/version: $V+$BUILD/" companion/pubspec.yaml
sed -i "s/kAppVersion = '[0-9.]*'/kAppVersion = '$V'/" companion/lib/core/app_version.dart
grep -q "FW_VERSION     \"$V\"" src/protocol.h || die "FW_VERSION not updated"
grep -q "FW_VERSION_NUM $NUM" src/protocol.h || die "FW_VERSION_NUM not updated"
grep -q "kAppVersion = '$V'" companion/lib/core/app_version.dart || die "kAppVersion not updated"
echo "firmware $V ($NUM), app $V+$BUILD"

# --- 3. tests and APK, before anything is public --------------------------------
say "Host tests"
pio test -e native >"$WORK/pio_test.log" 2>&1 || { tail -20 "$WORK/pio_test.log"; die "host tests failed"; }
tail -1 "$WORK/pio_test.log"

say "APK (about 3 minutes)"
# Capped so a runaway build cannot take the desktop down (as build_apk.sh).
systemd-run --user --scope --quiet -p MemoryHigh=7G -p MemoryMax=9G -p MemorySwapMax=1G \
  -p CPUWeight=20 -p IOWeight=20 --setenv=PATH="$PATH" --setenv=JAVA_HOME="$JAVA_HOME" \
  --setenv=ANDROID_HOME="$ANDROID_HOME" \
  nice -n 15 tools/release_apk.sh >"$WORK/apk.log" 2>&1 || { tail -20 "$WORK/apk.log"; die "APK build failed"; }
APK="companion/build/release/oui-snitch-$TAG-arm64.apk"
[ -f "$APK" ] && [ -f "$APK.sha256" ] || die "APK not where expected: $APK"
tail -2 "$WORK/apk.log"

# --- 4. commit, tag, push ----------------------------------------------------
say "Commit and push"
git add src/protocol.h companion/pubspec.yaml companion/lib/core/app_version.dart
MSG="Release $TAG"
[ -n "${COMMIT_TRAILER:-}" ] && MSG="$MSG"$'\n\n'"$COMMIT_TRAILER"
git commit -q -m "$MSG"
git tag "$TAG"
git push -q origin main
git push -q origin "$TAG"
echo "pushed $(git rev-parse --short HEAD) and $TAG"

# --- 5. CI draft, firmware signing, uploads ------------------------------------
say "Waiting for CI to build the firmware draft"
RUN=""
for _ in $(seq 1 60); do
  RUN=$(gh run list --workflow release.yml --branch "$TAG" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  [ -n "$RUN" ] && break
  sleep 5
done
[ -n "$RUN" ] || die "no release workflow run appeared for $TAG"
gh run watch "$RUN" --exit-status --interval 15 >/dev/null || die "release workflow failed: gh run view $RUN --log-failed"
echo "CI run $RUN done"

say "Signing firmware"
FW="$WORK/fw"; mkdir -p "$FW"
gh release download "$TAG" --dir "$FW" --pattern 'oui-snitch-*.bin' --pattern SHA256SUMS
OTA_KEY="$OTA_KEY" tools/sign_release.sh "$FW"

say "Uploading"
gh release upload "$TAG" --clobber "$FW"/*-ota.bin "$FW/SHA256SUMS" "$APK" "$APK.sha256"

# --- 6. publish and check -----------------------------------------------------
say "Publishing"
ASSETS=$(gh release view "$TAG" --json assets -q '.assets[].name')
NAPK=$(grep -c '\.apk$' <<<"$ASSETS" || true)
[ "$NAPK" = 1 ] || { echo "$ASSETS"; die "draft has $NAPK APKs, Obtainium needs exactly one; not publishing"; }
grep -q -- '-ota\.bin$' <<<"$ASSETS" || die "draft has no signed -ota.bin; not publishing"
gh release edit "$TAG" --draft=false --latest >/dev/null

say "Checking what was published"
PUB="$WORK/pub"; mkdir -p "$PUB"
gh release download "$TAG" --dir "$PUB" --pattern SHA256SUMS --pattern '*-ota.bin' --pattern '*.apk' --pattern '*.apk.sha256'
cmp -s "$PUB/SHA256SUMS" "$FW/SHA256SUMS" || die "published SHA256SUMS differs from the signed one"
# Same checksums as the files sign_release.sh verified, so same signatures.
(cd "$PUB" && grep -- '-ota\.bin$' SHA256SUMS | sha256sum -c --quiet - && sha256sum -c --quiet "$(basename "$APK").sha256")
echo "published https://github.com/$REPO/releases/tag/$TAG"
echo "Obtainium will offer $V on its next check."
