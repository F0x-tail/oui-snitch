# Releasing

The order matters: Obtainium and Android both read a release the moment it is
published.

## One command

`tools/release.sh X.Y.Z` does every step below on the release machine: version
bump, host tests, the release APK, commit, tag and push, waiting for CI,
signing the firmware, uploading, the one-APK check, publishing as Latest, and
checking the published files against what was built. Everything that can fail
locally runs before anything is pushed.

It needs both keys (below), the toolchains in `~/toolchains`, and `gh` logged
in once with access to the repository: `gh auth login`, choosing GitHub.com,
**SSH** as the git protocol (git keeps pushing over SSH) and the browser login.

## By hand

The same steps, for when something needs doing differently:

1. **Bump the version** in all four places to the same `X.Y.Z` (the tag check in
   `release.yml` refuses a mismatch):
   - `src/protocol.h` — `FW_VERSION` and `FW_VERSION_NUM`
   - `companion/pubspec.yaml` — `version: X.Y.Z+N`, **with N one higher than
     the last release**. Android will not install an update with a lower or
     equal version code.
   - `companion/lib/core/app_version.dart` — `kAppVersion`
2. Commit, push, then push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
   CI builds the firmware and creates a **draft** release with the firmware
   files and `SHA256SUMS`.
3. On this machine, sign the firmware for over-the-air updates. Download every
   `oui-snitch-*.bin` and `SHA256SUMS` from the draft into an empty folder,
   run `tools/sign_release.sh <folder>`, then upload the `*-ota.bin` files it
   writes and replace `SHA256SUMS` on the draft with its new copy. Boards
   install only these signed images; without them the app finds no update.
4. On this machine: `tools/release_apk.sh`. It refuses an APK signed with
   anything but the release key, or whose versionName is not `X.Y.Z`.
5. Attach `companion/build/release/oui-snitch-vX.Y.Z-arm64.apk` and its
   `.sha256` to the draft. **Exactly one `.apk` per release**; a second one
   makes Obtainium stop and ask instead of updating.
6. Publish the draft as a normal release (not a pre-release) and leave it
   marked **Latest**. Publish only after the APK is attached; Obtainium checks
   a published release straight away.

The release keystore and `companion/android/key.properties` exist only on the
release machine. Keep a backup of both off that machine: if the key is lost,
installed apps can never be updated, only uninstalled and reinstalled with
their data lost.

The firmware signing key, `~/.keystores/oui-snitch-ota.pem`, is in the same
position. Its public half is compiled into every board (`src/ota_pubkey.h`).
If it is lost, boards can no longer be updated over the air, only over USB.
If it leaks, anyone can sign firmware those boards will accept; then make a
new key (`tools/sign_firmware.py keygen`), release firmware carrying it, and
tell users to flash that release over USB.
