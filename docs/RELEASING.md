# Releasing

The order matters: Obtainium and Android both read a release the moment it is
published.

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
3. On this machine: `tools/release_apk.sh`. It refuses an APK signed with
   anything but the release key, or whose versionName is not `X.Y.Z`.
4. Attach `companion/build/release/oui-snitch-vX.Y.Z-arm64.apk` and its
   `.sha256` to the draft. **Exactly one `.apk` per release**; a second one
   makes Obtainium stop and ask instead of updating.
5. Publish the draft as a normal release (not a pre-release) and leave it
   marked **Latest**. Publish only after the APK is attached; Obtainium checks
   a published release straight away.

The release keystore and `companion/android/key.properties` exist only on the
release machine. Keep a backup of both off that machine: if the key is lost,
installed apps can never be updated, only uninstalled and reinstalled with
their data lost.
