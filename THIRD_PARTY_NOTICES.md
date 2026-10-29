# Third-party notices

This project is MIT licensed (see `LICENSE`). Some files in this repository, and
some libraries it builds against, are not — they keep their own terms, which are
recorded here.

## Provenance

This project descends from `colonelpanichacks/oui-spy-unified-blue` by way of
`lukeswitz/oui-spy-unified-blue` (OUI-APEX).

- **colonelpanichacks/oui-spy-unified-blue** is MIT licensed, "Copyright (c)
  2026 colonelpanichacks"
  ([LICENSE](https://github.com/colonelpanichacks/oui-spy-unified-blue/blob/master/LICENSE),
  added in October 2026). `LICENSE` here reproduces that copyright line and its
  permission notice unchanged, as the licence requires.
- **lukeswitz/oui-spy-unified-blue** carries no LICENSE file as of 28 October
  2026. What it added on top of the original, including the first version of
  the companion app, is used here on the assumption that it is offered under
  the same MIT terms as the project it forks. If that turns out to be wrong,
  the MIT grant in `LICENSE` covers only the original project and the
  modifications made here.

## Files in this repository under other licences

These are vendored, not written for this project. They keep their own headers
and are **not** relicensed by `LICENSE`:

| File | Licence | Copyright |
| --- | --- | --- |
| `src/opendroneid.c` | Apache-2.0 | 2019 Intel Corporation |
| `src/opendroneid.h` | Apache-2.0 | 2019 Intel Corporation |
| `src/odid_wifi.h` | Apache-2.0 | 2019 Intel Corporation |
| `src/wifi.c` | Apache-2.0 | 2020 Simon Wunderlich, Marek Sobe; 2020 Doodle Labs |

From the OpenDroneID reference implementation. Apache-2.0 requires that these
notices and the licence travel with any redistribution.

| File | Licence | Copyright |
| --- | --- | --- |
| `companion/assets/fonts/AtkinsonHyperlegible-*.ttf` | OFL-1.1 | 2020 Braille Institute of America, Inc. |
| `companion/assets/fonts/AtkinsonHyperlegibleMono-*.ttf` | OFL-1.1 | 2020-2024 The Atkinson Hyperlegible Mono Project Authors |

The app's typefaces, taken from the Google Fonts repository. The two Mono
files are static Regular and SemiBold instances cut from the upstream variable
font, which the OFL permits; neither font declares a Reserved Font Name. The
licence texts sit next to the fonts as `OFL-*.txt` and ship inside the app.

| File | Licence | Copyright |
| --- | --- | --- |
| `docs/images/badge_obtainium.png` | GPL-3.0 | ImranR98 and Obtainium contributors |

The "Get it on Obtainium" badge from `assets/graphics/badge_obtainium.png` in
github.com/ImranR98/Obtainium, trimmed of its transparent padding as the
Obtainium wiki suggests. It is an image shown in the README, not part of the
firmware or the app.

## Build-time dependencies

Fetched by PlatformIO and pub, not stored here, but linked into what you ship:

| Dependency | Licence | Note |
| --- | --- | --- |
| NimBLE-Arduino | Apache-2.0 | |
| TinyGPSPlus | **LGPL-2.1-or-later** | See below |
| Arduino-ESP32 core | LGPL-2.1-or-later | |
| Flutter and pub packages | MIT / BSD-3-Clause / Apache-2.0 | A few Linux-desktop transitives (`dbus`, `bluez`, `geoclue`, `gsettings`) are MPL-2.0 and are not shipped in the Android build. |

### The LGPL obligation

TinyGPSPlus and the Arduino-ESP32 core are LGPL. That does **not** make this
project's own source LGPL, and MIT code may link against them freely. It does
attach a condition to **distributing a compiled firmware binary**: the recipient
must be able to replace the LGPL parts with their own version. For a statically
linked firmware image that means offering the object files, or the source and a
means to relink, alongside the binary.

Publishing source only — which is what this repository does — carries no such
obligation. It becomes live the moment prebuilt `.bin` files are handed out, for
example through a web flasher.
