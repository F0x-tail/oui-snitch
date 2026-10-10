# App UI rebuild spec

Inventory source: subagent sweep of companion/lib (file:line refs in session). Research: Material/HIG 3–5 bottom tabs, tabs navigate only, status-first + progressive disclosure, color = status only.

## Problems (measured in code)
- START/STOP wardrive in 3 places; only wardrive_screen.dart:1161 runs permission + radio-role prechecks (home hero card engine_card.dart:85 skips them).
- Radio selection in 4 places, two stores synced by hand (appState.engineRadio vs wd.radio).
- Engine on/off in 5 places, each its own toggle path.
- 5+ detection list implementations; 3 filter/sort sheet copies; 4 export paths; 3 PCAP file managers.
- Home engine state = wardrive-derived when wd.isActive (home_screen.dart:493) else fw state: Home "controlled by wardrive".
- Config = 9 sections mixing settings, data browsing (HISTORY, PCAPS), accounts, hardware.

## Target IA — 4 tabs
1. SCAN (home): status header (node, GPS, mesh, uptime) → ONE session control (start/stop/pause, prechecks always) → engine grid (state only + tap for engine sheet) → live alert strip.
   - Wardrive is not special: a "session" records whatever engines run. Targets = engines. Removes WardriveTarget↔engine duality from UI.
2. MAP: current wardrive map + detections layer + geofences entry.
3. DETECTIONS: one list (live + history via toggle), one filter sheet, one export menu, device detail sheet (classifier verdict + presence). Merges Feed, Devices, Config>HISTORY, wardrive det list.
4. SETTINGS: grouped
   - Detection rules: watchlist (import/export/edit), signatures (catalog browser + toggles), ignore list, alerts/notifications.
   - Radios & scanning: radio per engine (single store), scan timing, band, channel range.
   - Node & mesh: hardware, mesh, firmware/OTA, WiFi creds, danger zone.
   - Data & accounts: sessions, PCAP library, export/backup, WiGLE/WDGWars, OUI DB.
   - App: theme, units, time, autoconnect.

## Engineering rules
- One code path per action: SessionController.start() owns prechecks; EngineController.set(engine,on,radio) owns toggles; one RadioSelection store.
- Reuse: CommandSheet/CommandBar/Config* widgets, DetectionRow, DeviceDetailSheet, EngineCard sizes, map widgets. Extract private wardrive parts that are reused.
- Delete replaced screens only after their replacement covers every control (inventory checklist per screen).
- No behavior change to BLE/firmware protocol in the rebuild.

## Progress
- [x] 1a session start: features/wardrive/session_launch.dart startWardriveSession (location perm + radio roles + start) used by wardrive START and Home hero card; dialogs moved, _syncToPeers no-op deleted.
- [x] 1b radio: setWardriveRadio(ref, mask) single path (wardrive picker, Home card cycle, role popup).
- [x] 1c core/engine_control.dart setEngineEnabled (wardrive-owned stop via stopOwnedEngine) used by engine_card, detector, skyspy, unipwn; WardriveController.ownsEngine shared with Home.
- [x] 2 Settings: IGNORE -> RULES (WatchlistPanel + SignaturesPanel + ignore list); HISTORY moved out. Watchlist/signature UI extracted to features/engines/detection_rules.dart (Detector screen reuses it).
- [x] 3 Detections tab (/detections): LIVE (feed) | DEVICES | HISTORY segments; shared one-line CommandHeader on all three; filter badge removed everywhere.
- [x] 4 Home: engine cards owned by a wardrive session say "Running in wardrive session"; on/off derivation uses wd.ownsEngine.
- [x] 5 Map tab = wardrive screen (nav label MAP).
- [x] 6 nav: HOME | DETECTIONS | MAP | SETTINGS; /feed, /devices routes removed (no remaining callers).
- [x] Class alerts: core/notifications/class_alerts.dart — cameras / law-enforcement / drones / glasses / trackers from Fieldwatch signature kind or classifier bucket (confidence >= medium); once per device per app session; toggles in Settings > ALERTS. test/class_alerts_test.dart.
- [x] Fieldwatch decode maps ported: core/classify/fleet_decode.dart (19 fleets), DECODED group in device detail. Ruuvi RAWv5 published vector passes.
- [x] Vendor classification: 190 hand rules + Bluetooth SIG (4047 company IDs / 717 member UUIDs) + 2100 Haiku-classified companies (assets/classify).
- Verified: flutter analyze lib test clean; flutter test +152 (incl. rebuild_widgets_test at 360px). GUI-UNVERIFIED on device.

## Phases (each: analyze clean + tests + widget tests on new screens)
1. Single action paths (session, engine toggle, radio store) — refactor under existing UI.
2. Settings tab regroup (moves only, existing widgets).
3. Detections tab merge.
4. Scan (home) rebuild on phase-1 controllers.
5. Map tab = wardrive screen minus controls.
6. Remove dead screens/routes; nav to 4 tabs.
