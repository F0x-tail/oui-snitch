# Third-party notices

This project is MIT licensed (see `LICENSE`). Some files in this repository, and
some libraries it builds against, are not — they keep their own terms, which are
recorded here.

## Provenance

This firmware descends from `colonelpanichacks/oui-spy-unified-blue` by way of
`lukeswitz/oui-spy-unified-blue`. Neither repository carries a LICENSE file at
the time of writing. This project proceeds on the basis that the original is MIT
licensed, pending confirmation from its author. If that turns out to be wrong,
the MIT grant in `LICENSE` covers only the modifications made here.

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

## Projects studied but not copied

No code from these is present. They are listed because their designs informed
this one, and because the last entry must stay excluded.

- **MeshCore** (`meshcore-dev/meshcore`), MIT — the BLE pairing model used here
  follows its approach: LE Secure Connections with bonding and MITM protection,
  a default passkey the user changes, and connection state gated on the pairing
  result rather than on the GATT link coming up.
- **axeoff** (`colonelpanichacks/axeoff`), MIT — duty-equipment radio signatures.
  Signatures are facts about third-party hardware, not expression.
- **Sky-Spy** (`colonelpanichacks/Sky-Spy`), no licence — Remote ID signatures,
  likewise facts. No code taken, and none can be while it is unlicensed.
- **piglet** (`hamspiced/piglet`), **CC BY-NC-SA 4.0** — reviewed as a
  comparison for Wi-Fi wardriving. Its licence is not an open-source licence and
  is incompatible with this one: the NonCommercial condition cannot be imposed
  downstream through MIT, and ShareAlike would force copyleft onto the combined
  work. **No code from piglet may enter this repository.** Ideas that are not
  copyrightable, such as gating a GPS fix on HDOP, may be reimplemented
  independently.
