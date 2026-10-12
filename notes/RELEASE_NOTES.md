# Since v0.6.1

## New

- Device classifier: DETECTIONS → DEVICES lists and classifies every nearby device.
- 20 classes including cameras, surveillance, public safety, drones, finder tags.
- Also glasses, wearables, vehicles, pentest tools, locks, health, home IoT.
- Co-travel and flood detection flag suspicious device behavior.
- Phone scan: phone Bluetooth scans alongside the board, off by default.
- Alert sounds: choose or compose a melody per alert type.
- Manager pushes tones and previews to every mesh node.
- Axon detection via BLE UUIDs FE6B/FE6C, with presence tones.
- Foxhunt can now target any device, including law enforcement.
- Watchlist import/export as CSV or JSON, up to 5000 rows.
- Fieldwatch catalog of 253 fleets added.
- Optional OUI-only Flock WiFi hits.
- XIAO ESP32-C5 mesh manager, available in the web flasher.
- `ouispy-flash.sh` detects T-Dongle and StickC boards, lists all firmware.

## Changed

- New four-tab layout; history and rules moved, refreshed list rows.
- Watchlist notifications titled by entry description, with device details.
- Notifications: four engine toggles; class alerts always on.
- Wardrive WiFi / BLE / Both selector always visible while idle.
- Button-started engines keep running when the phone disconnects.
- WiGLE sessions start without waiting for a GPS fix.
- Classifier: iBeacon now "Beacons", Honeywell moved to industrial.

## Fixed

- Mesh nodes scanning BLE missed manager commands, on every chip.
- Nodes now find a manager powered on after them.
- LilyGO T-Dongle S3 reboot loop when receiving an ignore list.
- XIAO ESP32-C5 nodes missing from the app's connect list.
- Manager tone changes not reaching nodes; removed tones kept playing.
- Connect screen scan list squeezed left and not scanning.
- Web flasher did not restart the board after flashing.
- Same-length offline filter list replacements were not saved.
- Classifier dropped router and IoT vendors.
