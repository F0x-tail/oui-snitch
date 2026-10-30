# OUI-SNITCH

**A detection device. It watches the air for surveillance hardware and tells your phone what it found.**

ESP32 firmware plus an Android/iOS app. It looks for ALPR cameras, Bluetooth
trackers following you, police duty equipment, drones broadcasting Remote ID
and devices on your own watchlist — and it can wardrive at the same time.

The thing that makes it different from the projects it grew out of: **every
engine you enable runs at once.** Most devices in this space give you a menu
and run one mode at a time. Here, detection and logging run together.

<a href="https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22io.github.f0xtail.ouisnitch%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FF0x-tail%2Foui-snitch%22%2C%22author%22%3A%22F0x-tail%22%2C%22name%22%3A%22OUI-SNITCH%22%7D"><img src="docs/images/badge_obtainium.png" alt="Get it on Obtainium" height="48"></a>

> [!NOTE]
> **OUI-SNITCH is a fork of [OUI-APEX](https://github.com/lukeswitz/oui-spy-unified-blue)**,
> which builds on the OUI-SPY engines by
> [colonelpanichacks](https://github.com/colonelpanichacks). Not affiliated with
> either. Beta software — see **Known limits** before you rely on it for anything.
>
> The fork has diverged: the firmware-to-app wire protocol is no longer
> compatible with OUI-APEX, so the two apps and firmwares cannot be mixed.
> [COMPATIBILITY.md](COMPATIBILITY.md) says exactly where, and what this fork
> adds.

---

## What this document covers

**Hardware v0.1** — a single XIAO ESP32-S3 on a breadboard. No PCB, no
enclosure, no case: one module, a USB cable, and jumper wire for the two
optional extras. It is the cheapest way into this project, and it is the only
hardware that exists.

---

## Build one

### Parts

| Part | Needed? | Notes |
|---|---|---|
| **Seeed XIAO ESP32-S3** | yes | The main board. Talks to your phone, runs the engines |
| Breadboard + jumpers | yes | Any size |
| USB-C cable | yes | Must be a **data** cable. Charge-only cables are the most common reason a board does not appear |
| Passive buzzer | optional | GPIO3 on the S3 |
| NEO-6M / NEO-8M GPS | optional | Lets the board stamp positions without a phone |
| Android or iOS phone | yes | This is the user interface. There is no screen on the board |

The only soldering is the pin headers onto the module. The XIAO ESP32-S3 ships
**without** them, so buy a strip of 0.1" headers at the same time — it is the
one part people forget and the one that stops you breadboarding anything.

### Wiring

Only two optional things get wired on v0.1:

| | XIAO ESP32-S3 pin |
|---|---|
| Buzzer (+) | GPIO3 |
| GPS module TX → board | GPIO44 |
| GPS module RX ← board | GPIO43 |

GPS runs at 9600 baud. Ground is shared; the GPS module takes 3V3.

With neither fitted, v0.1 is a XIAO on a USB cable, and that works — the phone
supplies the position and the alerts.

---

## Flash it

**Flash in DIO mode.** Writing the image as QIO produces a board that boot
loops with `TG0WDT_SYS_RST` and looks bricked. It isn't, but you will lose an
evening to it.

You need [esptool](https://docs.espressif.com/projects/esptool/) either way
(`pip install esptool`). Replace `/dev/ttyACM0` with your port; on Windows it
is `COM3` or similar, on macOS `/dev/cu.usbmodem…`. On Linux you may need to
be in the `dialout` group.

### From a release

From the [latest release](https://github.com/F0x-tail/oui-snitch/releases/latest)
download `oui-snitch-node-xiao_s3-<version>-usb.tar.gz` and unpack it. It holds
the four files below plus `LICENSE` and `THIRD_PARTY_NOTICES.md`. Check them
against `SHA256SUMS` from the same release (`sha256sum -c SHA256SUMS
--ignore-missing`), then, in the unpacked folder:

```bash
V=v0.7.0   # the release you downloaded
python3 -m esptool --chip esp32s3 --port /dev/ttyACM0 --baud 921600 \
  write_flash --flash_mode dio --flash_freq 80m --flash_size 8MB \
  0x0     oui-snitch-node-xiao_s3-$V-bootloader.bin \
  0x8000  oui-snitch-node-xiao_s3-$V-partitions.bin \
  0xe000  oui-snitch-node-xiao_s3-$V-boot_app0.bin \
  0x10000 oui-snitch-node-xiao_s3-$V.bin
```

The board keeps its pairing, settings and offline data across an update. To
update later, flash only the last file at `0x10000`, or update from the app.

### Updating from the app

Once the board runs a release, the app's firmware page offers newer releases
and installs them over Bluetooth, or over the board's own Wi-Fi if you gave it
your network. Each release carries a signed image, `…-ota.bin`. The board
checks the signature before it switches to a new image, and refuses an image
that is unsigned, signed with another key, altered, or built for another
board. So a firmware you built yourself goes on over USB, as above.

A new image runs on trial for its first minute. If it crashes, or the board
loses power in that minute, the board goes back to the previous firmware on
its next start. Leave it powered for a minute after an update.

### Build it yourself

You need [PlatformIO](https://platformio.org/install/cli). Then:

```bash
pio run -e v3_app_controlled        # XIAO ESP32-S3
python3 -m esptool --chip esp32s3 --port /dev/ttyACM0 --baud 921600 \
  write_flash --flash_mode dio --flash_freq 80m --flash_size 8MB \
  0x0     .pio/build/v3_app_controlled/bootloader.bin \
  0x8000  .pio/build/v3_app_controlled/partitions.bin \
  0xe000  ~/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin \
  0x10000 .pio/build/v3_app_controlled/firmware.bin
```

Other board targets exist in `platformio.ini`. None of them is tested, and
none is described here.

### Check it worked

Open a serial monitor at 115200 and press reset. A healthy board says:

```
========================================
  OUI-SNITCH — App-Controlled Mode
========================================
[ENGINE] Registered: Detector (id=0)
...
[INIT] *** OUI-SNITCH READY ***
```

If you see `rst:0x7 (TG0WDT_SYS_RST)` repeating, you flashed QIO. Reflash with
`--flash_mode dio`.

---

## The app

### Install a release (Android)

<a href="https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22io.github.f0xtail.ouisnitch%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FF0x-tail%2Foui-snitch%22%2C%22author%22%3A%22F0x-tail%22%2C%22name%22%3A%22OUI-SNITCH%22%7D"><img src="docs/images/badge_obtainium.png" alt="Get it on Obtainium" height="48"></a>

[Obtainium](https://github.com/ImranR98/Obtainium) installs the app from this
repository's releases and tells you when a new one is out. The badge above adds
it in one tap; or add `https://github.com/F0x-tail/oui-snitch` by hand.

Or download `oui-snitch-<version>-arm64.apk` from the
[latest release](https://github.com/F0x-tail/oui-snitch/releases/latest) and
open it; Android asks once to allow installs from your browser or file manager.
The APK is for 64-bit ARM phones, which is nearly every Android phone sold
since 2017.

**Check it is genuine.** Every release APK is signed with the same key. Its
certificate's SHA-256 fingerprint is:

```
7F:22:EA:7F:AA:60:47:3B:60:3B:76:EA:D8:12:31:B2:B0:81:4D:10:D8:35:12:1A:91:FE:1F:94:50:F6:2E:C6
```

[AppVerifier](https://github.com/soupslurpr/AppVerifier) checks an installed
app against it; or run
`apksigner verify --print-certs oui-snitch-<version>-arm64.apk`. Android
itself refuses an update signed with a different key, so a fake release cannot
replace the app you have. The file's SHA-256 is in the `.sha256` file next to
it in the release.

### Build it yourself

```bash
cd companion && flutter pub get && flutter build apk --release
```

Then `adb install -r build/app/outputs/flutter-apk/app-release.apk`, or build
`ipa` / `macos` instead. A build you sign yourself cannot update a release
install, or the other way round: Android would need you to uninstall first,
which deletes the app's data.

**On Android, set Location to "Allow all the time."** With "only while using
the app", scanning stops the moment the screen goes off. This is an Android
rule, not a choice this project made.

Open the app, tap **CONNECT**, pick your board.

### Pairing — change the passkey

Every board ships with the passkey **123456**, and says so loudly on boot:

```
  BLE pairing passkey: 123456
  THIS IS THE DEFAULT. Anyone in range can
  pair with this board until you change it
```

Until you change it, anyone within Bluetooth range can pair with your board,
read what it has detected and turn its radios on and off. Change it under
**SETTINGS → NODE → PAIRING**; the app shows a warning there while the default
is in use.

The default exists so a board with no screen and no buttons can be set up at
all. It is a starting point, not a setting to leave alone.

You pair once per phone. The board keeps the same Bluetooth address across
reboots, so the bond survives them. Once a phone is paired, the board stops
advertising its name. Your phone still finds it, but a stranger scanning
nearby no longer sees "OUI-SNITCH". Someone who connects without pairing is
dropped after a minute, and can't lock your phone out while connected.

---

## What it detects

| Engine | Finds |
|---|---|
| **Detector** | Your watchlist (MAC, OUI prefix, name, BLE service UUID), plus built-in signatures — all off by default: Find My / AirTag trackers following you (and bursts of fake ones), Flipper Zero, Wi-Fi attacks (deauth and authentication floods, handshake-harvesting sweeps, anonymous reassociation, forged channel switches), evil-twin and KARMA access points, directed probes, Pwnagotchi, Meta Ray-Ban and Oakley glasses |
| **Axon** | Axon / TASER duty equipment — body cameras and the like, close enough to hear |
| **Flock WiFi** | Flock Safety ALPR cameras and Raven gunshot sensors, by Wi-Fi fingerprint |
| **Sky Spy** | Drones broadcasting FAA Remote ID over BLE or Wi-Fi: ID, position, altitude, speed, pilot position |
| **Foxhunter** | Hunts one device. Beep rate rises as you close in; an on-screen RSSI meter when no buzzer is fitted |
| **UniPwn** | Unitree robots, by BLE name (`Go2_`, `G1_`, `H1_`, …) |
| **Wardrive** | Every Wi-Fi AP and BLE device, GPS-stamped, in WiGLE CSV format |
| **PCAP** | Raw 802.11 or BLE advertising frames to a Wireshark `.pcap` |

Run as many as you like together. Wi-Fi engines share the radio and the sweep,
which is the whole point of the design.

> [!IMPORTANT]
> A hit is a **signal match, not an identification.** The Flock OUI list in
> particular matches Ubiquiti, Espressif and other ordinary consumer parts.
> Look with your own eyes before you report anything to anyone.

Flock hits carry a confidence tier — `VERIFIED` (bare-serial name + XUNTONG
`0x09C8` manufacturer ID + TN serial), `HIGH` (one strong signal), `SUSPECTED`
(a listed OUI only). Treat `SUSPECTED` as "worth a look", nothing more.

---

## Using it

The app has four tabs: **HOME · DETECTIONS · MAP · SETTINGS**.

- **HOME** — one card per engine, plus the session bar and a status row showing
  link, GPS fix and node count.
- **DETECTIONS** — LIVE (every hit, filterable), DEVICES (each device classified
  by vendor and advertisement data), HISTORY (the stored log). Tap any row to
  foxhunt it or put it on the map.
- **MAP** — pick targets and radio, hit START. Sessions save as WiGLE CSV, upload
  to [WiGLE](https://wigle.net) and [WDGWars](https://wdgwars.pl), and replay later.
- **SETTINGS** — watchlist, signatures, ignore list, alert sounds, geofences,
  exports, and the board's own configuration under NODE.

**Geofences** are worth setting up early. Inside a zone you have marked, the app
drops detections from the feed, the log and your notifications, and the board
stops beeping. The radios keep scanning — it suppresses the noise, not the data.
Put one around your home before your first long session.

**Offline scan** (SETTINGS → NODE → HARDWARE) keeps the board scanning after the
phone disconnects. Hits buffer to flash and upload when you reconnect. The
setting survives a reboot.

### Wardriving

Wardrive logs every Wi-Fi AP and BLE device it sees, stamped with position, in
the CSV format WiGLE accepts.

The board only logs a device again after the **rediscover interval** has passed
(SETTINGS → ALERTS, 10 s by default). While you are moving, it shortens that
automatically, aiming at roughly one sighting per 50 m travelled — what WiGLE
needs to locate a transmitter is sightings from *different places*, not the same
one repeated from a parked car. Standing still, you get exactly the interval you
configured.

Position comes from your phone unless a GPS module has a fix, in which case the
module wins. With no fix at all, rows are still logged but cannot be uploaded.

With offline scan on and a GPS module fitted, a wardrive carries on while the
phone is away: the board keeps the rows itself, with its own GPS position and
time, and hands them over when you reconnect.

#### WiGLE CSV format

Exports follow [WiGLE CSV v1.6](https://api.wigle.net/csvFormat.html), checked
field by field against the spec:

- the pre-header names the app and firmware versions and the board, and the
  header row is the spec's, in order;
- only wardrive sightings are written: tracker, deauth, camera and drone
  alerts never become rows, so no one's phone is uploaded as an access point;
- AuthMode uses Android's capability format, as the spec asks
  (`[WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]`, `[RSN-SAE-CCMP][ESS]`, ...), with the
  ciphers and BSS type the board read from the beacon; a security type it
  could not read is left blank rather than guessed;
- Channel is the one the access point announces; times are UTC; altitude is
  whole metres; an unknown accuracy is left blank, never written as 0;
- Bluetooth rows have channel 0, no frequency, and the manufacturer ID when the
  device advertises one; Wi-Fi rows carry Passpoint roaming OIs when present;
- the ignore list and your exclusion zones apply to every export.

Uploads check WiGLE's own upload list first, so a session is never sent twice.

---

## Known limits

Read these before trusting the device with anything that matters.

- **The mesh is off by default, and not secure when on.** Turning it on in
  the app starts ESP-NOW, which defaults to plaintext broadcast, and the key
  exchange has flaws that have not been fixed. A board on the mesh also accepts
  firmware updates from other mesh devices. Leave it off unless you need it, and
  do not carry anything over it you would not shout. The phone↔board Bluetooth
  link is separate and is encrypted once paired.
- **Bluetooth scanning is active by default.** To read device names, the board
  sends a scan request to everything it hears, including what it detects. For
  listen-only, turn on *Settings → Radio privacy → Passive Bluetooth scanning*.
- **Your phone may be giving you away.** *Settings → Radio privacy → What does
  my phone give away?* has the board listen while you switch your phone's Wi-Fi
  off and on, then shows which network names it called out and whether it used
  its factory address. Nothing from the check is stored.
- **The default passkey protects nothing.** See *Pairing* above.
- **Detections are signal matches.** No engine identifies a device with
  certainty. Confidence tiers tell you how much evidence there was.
- **Battery, enclosure and antenna placement are up to you** on v0.1. There is no
  power management; it runs off USB.
- **One radio does everything.** Wi-Fi promiscuous capture, BLE scanning and
  the link to your phone are time-sliced on the same chip. It works, and that
  sharing is the honest limit of a single module: nothing is listening to one
  band while it is busy with another.

---

## Build your own version

This is MIT licensed because the point is for the code to be useful to you, in
whatever you are building — in full, in part, or as the one function you needed.
Take it. Surveillance-detection tooling gets better when the work is shared.

Some vendored files and build-time dependencies carry other terms.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists them, including the LGPL
condition that attaches if you hand out prebuilt firmware binaries.

## Credits

Upstream engines by **colonelpanichacks**:
[Detector](https://github.com/colonelpanichacks/ouispy-detector),
[Foxhunter](https://github.com/colonelpanichacks/ouispy-foxhunter),
[Flock You](https://github.com/colonelpanichacks/flock-you),
[Sky-Spy](https://github.com/colonelpanichacks/Sky-Spy),
[UniPwn](https://github.com/colonelpanichacks/Oui-Spy-UniPwn).
App and unified firmware from
[lukeswitz/oui-spy-unified-blue](https://github.com/lukeswitz/oui-spy-unified-blue)
(OUI-APEX), which OUI-SNITCH forked from.

- **Will Greenberg** ([flock-you](https://github.com/wgreenberg/flock-you)) — XUNTONG `0x09C8` detection
- **@NitekryDPaul / OrdoOuroborous** ([@nitekry](https://github.com/nitekry)) — promiscuous Flock OUI set, addr1 receiver technique
- **DeFlockJoplin** ([flock-you](https://github.com/DeflockJoplin/flock-you)) — wildcard-probe signature
- **OffGridPete** ([Fieldwatch](https://github.com/OffGridPete/Fieldwatch)) — device signature catalog and classifier
- Company and service IDs from the [Bluetooth SIG assigned numbers](https://bitbucket.org/bluetooth-SIG/public)
- Vendor OUIs from [OUI-Master-Database](https://github.com/Ringmast4r/OUI-Master-Database),
  [zmattmanz](https://github.com/zmattmanz), [dougborg/AirHound](https://github.com/dougborg),
  [VirtuallyScott](https://github.com/VirtuallyScott)

Firmware libraries: [NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino),
[TinyGPS++](https://github.com/mikalhart/TinyGPSPlus),
[Adafruit GFX](https://github.com/adafruit/Adafruit-GFX-Library); ESP-IDF
ESP-NOW and mbedTLS. Map tiles from [CARTO](https://carto.com/basemaps/),
[Esri](https://www.esri.com/), [OpenStreetMap](https://www.openstreetmap.org/)
and [OpenTopoMap](https://opentopomap.org/).
