# Detector / classifier / UX plan (issue #23 + classifier ports)

Paths relative to companion/lib unless noted. Effort S/M/L.

## Issue #23 eval
1. Notification title = target description — VALID, S. notification_service.dart:287-291 hardcodes 'Watchlist Hit' and body `name|mac rssi`. `det.detector?.filterDescription` (filled ble_protocol.dart:541) and `det.method` are on hand, unused. Title = description (fallback method label), body = MAC · RSSI · reason · classifier label. Sanitize (radio-sourced name/SSID: strip control chars, cap length).
2. Menu duplication — VALID, partial. Detector screen (features/engines/detector_screen.dart) = WATCHLIST + SIGNATURES + DETECTIONS; Config>Detections (config_detections_tab.dart, 1725 lines) = all-engine history + filters/map/CSV. Only the Detector DETECTIONS list is redundant. Fix: rename Config>Detections to "History" (or move it to Feed), Detector screen keeps watchlist+sigs, its detection list becomes a link into History filtered to detector. S/M.
3. Watchlist import/export — VALID, S/M. WatchlistEntry (watchlist_state.dart:16-67) already has toJson/fromJson + replaceAll; no import/export UI exists. Add JSON + CSV (identifier,matchType,description,enabled) import (merge/dedup, validate OUI/MAC/UUID format, cap count) and export via share sheet.
   - Also missing: edit entry; add dialog (detector_screen.dart:196-255) can't create name/UUID entries though the model supports them. S.
4. More signatures — mostly already done. Fieldwatch catalog (253 fleets, 6982 rules) ported in d6da495. Gap: whether classifier labels reach the detector/alerts (verify). Sources: Fieldwatch (OffGridPete, credited in companion/NOTICE) and AntiHunter only; no other third-party signature sets. S.
   - To source and verify independently (own captures/vendor docs) before adding: Axon SSID prefixes AB2-/AB3-/AB4-/AXON-; BT-classic names HC-03/HC-05/HC-06/RN42/BT04-A, Flock_Setup, FS Ext Battery.
   - "1200 OUI" list: ship as low-confidence tier gated on corroboration (owner's own point: OUI alone = false positives).

## Classifier ports
5. AntiHunter BLE classifier (AntiHunter/full/src/ble_class.cpp 226 LOC + ble_id_class.h table) — M. Pure first-match cascade over svc-data UUID, Apple/MS/Google/Samsung mfg subtypes, svc UUID, UUID16/company tables, appearance; bounds-checked. Port the cascade + tables to Dart as a fallback layer under the Fieldwatch engine (Fieldwatch = fleet/surveillance signatures, AntiHunter = generic device type). Raw adv already reaches the app (d6da495). Firmware port optional — app-side covers all nodes w/o wire change.
6. AntiHunter C2 baseline classifier (device-classification.types.ts:28-55, ~30 LOC) — S. Stationary / frequent-flier / visitor / new / transient from first/last seen, visits, presence. Feeds co_travel.dart: "following you" = visitor/frequent-flier across distinct GPS cells.
7. Fieldwatch parity check — M. Diff Dart port vs Kotlin SignatureEngine.kt: minPeers/peerWindowSec, clusterByOui, sequentialMac, decode maps, VENDOR_IE_OUI (needs IE data from fw — check wire). Catalog update path (Fieldwatch ships catalog JSON; app could pull newer signed/pinned version — NET-0: opt-in only).
8. Combined verdict — M. One explain string per device: fleet match (Fieldwatch) + type (AntiHunter) + behavior (baseline) + confidence, shown in device detail, feed rows, and the notification.

## Security (owner's "trust nothing")
9. Untrusted-string sweep — S/M. SSID/name/adv flow into notifications, CSV export (config_detections_tab.dart:380-396), map popups, share text. Guard CSV formula injection (leading = + - @, Fieldwatch has this bug: LogStore.kt:278), control chars/RTL override, length caps, imported watchlist/catalog validation.

## UX redesign
10. IA cleanup — L. 5 tabs + 8 pushed screens + Config with 9 sections (~30 headers). Proposed: Home (status + engines), Feed (live), Devices (classified, fed by 5-8), History (current Config>Detections), Settings (grouped: Detection rules [watchlist, signatures, ignore, alerts], Radios/Wardrive, Hardware/Mesh/Firmware, App). Engine screens keep only engine controls. Do 1-3 first; they fit into this layout without rework.

## Order
1 → 3 → 2 → 9 → 5 → 6 → 8 → 7 → 4 → 10.

## Todo (2026-10-09) — analyze clean, flutter test +130 ~1 pass; GUI-UNVERIFIED (rebuild in Xcode)
- [x] 1 notification: title = filterDescription (fallback 'Watchlist Hit'), body = name MAC · RSSI · method (notification_service.dart). Radio strings stripped of control/C1 bytes at decode (ble_protocol.dart _extractString).
- [x] 3 watchlist import (JSON/CSV, validated, deduped, desc sanitized+31B cap, 2MB cap) + JSON export via share sheet; add dialog gets OUI/MAC/UUID picker + validation + dup check. NAME omitted from dialog: name entries never reach fw (ble_manager.dart:1080), only WiGLE import uses them. test/watchlist_import_test.dart.
- [x] 2 (user picked rename+link) Config>DETECTIONS renamed HISTORY; Detector screen list replaced by DETECTOR HISTORY tile → Config/HISTORY pre-filtered to detector (historyFilterRequestProvider). _DetectionTile removed (dead after swap, guard acked).
- [x] 9 CSV formula-injection guard (csvCell) for detections CSV + Config>Detections export. WiGLE CSV deliberately untouched (prefix would alter uploaded SSIDs).
- [x] 5 AntiHunter BLE classifier → core/classify/antihunter_class.dart (208 UUID16 + 108 company + MS/Google/Samsung subtypes + Eddystone + Appearance), fed into DeviceExplain.guess at weight 3-6. test/antihunter_class_test.dart.
- [x] 6 AntiHunter presence classifier → core/classify/presence_class.dart (+ sightings→visits/presence). test/presence_class_test.dart.
- [x] 8 device detail shows Presence (category · visits/7d · sightings) from DB; schema 7→8 adds idx_detections_mac (one-time index build on upgrade).
- [x] 7 Fieldwatch parity: 11 rule kinds identical, catalog 91 = 91. Ported cluster fleets (minPeers/peerWindowSec/clusterByOui/sequentialMac; cluster fleets no longer match as single devices) + hiddenSsid from wifi_ap empty SSID. test/signature_cluster_test.dart.
  - OPEN: VENDOR_IE_OUI (5 catalog rules) dead — fw never sends beacon vendor IEs; needs a wire change (fleet re-flash). Not done.
  - OPEN: fleet `decode` maps (TPMS pressure, GoPro/DJI model, DULT state) not ported; display-only, detection unaffected.
- [x] 4 BT-classic names DROPPED: ESP32-S3/C3/C5 have no BR/EDR radio (Espressif ESP-ADF docs, Bluepad32 FAQ). Axon SSID prefixes: no public source found; Axon already detected by OUI 00:25:DF in fw ISR. Add only from own capture.
- [x] 10 user chose rename+link over full IA redesign; no further nav moves.
- Final: flutter analyze lib test → No issues; flutter test → +132 ~1 All tests passed. Nothing committed.
