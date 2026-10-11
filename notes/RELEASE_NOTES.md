# Since v0.6.1

## App redesign

Four-tab navigation (Home, Detections, Wardrive, Settings) replaces the
five-tab layout. All corner radii standardized to 10pt. Dark-first palette
with muted neon engine colors. Outline/filled icon pairs on the nav bar with
a top border divider. Screens use cards for dashboards, dense rows for data
feeds, grouped lists only for settings.

## Device classifier

Fieldwatch signature engine classifies BLE devices by vendor OUI, advertised
service UUIDs, and manufacturer data patterns. Categories include cameras,
law enforcement (Axon), drones, trackers, smart glasses, medical, industrial,
and IoT. Raw advertisement bytes decoded and displayed per device. Co-travel
and flood detection score device behavior over time.

## Axon / law enforcement detection

Detector engine matches Axon BLE service UUIDs FE6B and FE6C. Foxhunt
unblocked when Axon presence detected. Presence tones fire on Axon proximity.

## Assignable alert melodies

Per-engine alert sounds configurable from the app. Melody state synced to
firmware over GATT. Alert sounds screen with preview playback.

## Inline RSSI and streamlined device rows

Device list shows RSSI and unit inline on one line instead of stacked.
Last-seen timestamp removed from device rows. Confidence dot retained.

## Classifier accuracy

- iBeacon label changed from "Retail beacons" to "Beacons"
- Honeywell reclassified from POS to industrial
- POS description narrowed to payment terminals and barcode scanners
- Missing noun map entries for `router` and `iot` buckets added so
  TSV-loaded vendors with those categories are no longer silently dropped

## Notification consolidation

Five granular ClassAlert toggles (cameras, law enforcement, drones, glasses,
trackers) removed from the settings UI. Class alerts stay always-on by
default. Four engine-level toggles remain: Flock Safety, Watchlist/Detector,
Drone/Sky Spy, Foxhunt Proximity.

## OUI-only flock mode

Toggle in device config to report only OUI-matched flock detections, filtering
out unresolved BLE advertisements.

## Also

- Engines started by physical button persist through phone disconnect
- WiGLE session launchable from home screen without waiting for location fix
- Offline filter persist uses content-compare instead of count-compare,
  preventing false no-ops when filter list is replaced with same-length data
- Per-pill filter colors on detection and device lists
- Multi-line comments stripped from companion codebase
