// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';

/// Icon for a detection shown as an individual map pin.
///
/// Map pins used to collapse every detector hit onto a single generic
/// `Icons.radar`, so a Ring doorbell, an AirTag following you and an Axon body
/// camera were visually identical. These map a detection to *what it is*,
/// reusing the icon vocabulary already used by `detectorSignatures` and
/// `Engine.icon` so the map matches the rest of the app.
///
/// Wardrive detections are not pinned — they cluster as points — but they still
/// get an icon here for cluster legends and list rows.
IconData detectionMapIcon(Detection d) => switch (d.engine) {
      Engine.detector => detectorMethodIcon(d.method),
      // Flock cameras, either radio: one symbol, because it is one device.
      Engine.axon => Icons.local_police,
      Engine.flockWifi => Icons.videocam,
      Engine.skySpy => Icons.flight,
      Engine.uniPwn => Icons.smart_toy,
      Engine.foxhunter => Icons.gps_fixed,
      Engine.wardrive => Icons.wifi,
      Engine.pcap => Icons.fiber_manual_record,
    };

/// Icon for a detector hit, keyed on the decoded method name.
///
/// Method strings come from `BleProtocol` (`Engine.detector` table): the 15
/// values below. An unknown method falls back to the engine's generic radar
/// rather than guessing.
IconData detectorMethodIcon(String method) => switch (method) {
      'tracker' => Icons.track_changes,
      // Consumer surveillance cameras (Ring, Nest, Wyze, Arlo...). Distinct
      // from the Flock videocam so the two are not confused on the map.
      'camera' => Icons.photo_camera,
      'stream' => Icons.videocam,
      'glasses' => Icons.visibility,
      'axon' => Icons.local_police,
      'mesh' => Icons.hub,
      // Wireless-audit hardware, folded into one symbol as the signature
      // bitmask already folds them into one bit.
      'flipper' || 'pwnagotchi' || 'pineapple' => Icons.developer_board,
      'deauth_storm' || 'wifi_attack' => Icons.wifi_off,
      'ble_spam' => Icons.bluetooth_disabled,
      'probe_ssid' => Icons.wifi_find,
      'evil_twin' => Icons.wifi_tethering_error,
      // The user's own watchlist targets.
      'ble_watchlist' || 'wifi_watchlist' => Icons.radar,
      _ => Icons.radar,
    };
