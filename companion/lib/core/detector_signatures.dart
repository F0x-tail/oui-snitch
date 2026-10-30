// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Signature bits are grouped by category rather than one per device, so eight
// bits cover far more than eight devices. sigHacktools folds together the
// wireless-audit hardware that used to hold two bits (Flipper, Pwnagotchi),
// which frees one for sigMesh.
const int sigTracker = 0x01;
const int sigHacktools = 0x02;
const int sigDeauth = 0x04;
const int sigProbe = 0x08;
const int sigMesh = 0x10;
const int sigGlasses = 0x20;
const int sigAxon = 0x40;
const int sigCamera = 0x80;
const int sigAll = 0xFF;

// Confidence reported with each detection (DET_CONF_* in the firmware).
const int detConfNone = 0;
const int detConfSuspected = 1;
const int detConfHigh = 2;
const int detConfVerified = 3;

String detConfLabel(int c) {
  switch (c) {
    case detConfVerified:
      return 'VERIFIED';
    case detConfHigh:
      return 'HIGH';
    case detConfSuspected:
      return 'SUSPECTED';
    default:
      return '';
  }
}

class DetectorSignature {
  final int bit;
  final String label;
  final String short;
  final IconData icon;
  final String desc;
  const DetectorSignature(this.bit, this.label, this.short, this.icon, this.desc);
}

const List<DetectorSignature> detectorSignatures = [
  DetectorSignature(sigTracker, 'Trackers', 'Trackers', Icons.track_changes,
      'Apple Find My / AirTag, Samsung SmartTag, Tile and Google Find My Device trackers. Escalates from nearby, to following you, to moving with you between places (told apart by what the board hears, no GPS needed) or coming back after a restart. A burst of fake tags is reported once as tracker spam'),
  DetectorSignature(sigHacktools, 'Hacking tools', 'Hack\ntools', Icons.developer_board,
      'Wireless-audit hardware: Flipper Zero BLE advertisements and Pwnagotchi handshake-harvester beacons'),
  DetectorSignature(sigDeauth, 'Wi-Fi attacks', 'Wi-Fi\nattacks', Icons.wifi_off,
      'WiFi deauth / disassociation floods, authentication floods, handshake-harvesting sweeps, anonymous reassociation and forged channel switches'),
  DetectorSignature(sigProbe, 'Probes & rogue APs', 'Probe', Icons.wifi_find,
      'Devices probing for saved WiFi networks, evil-twin APs (one SSID from a second BSSID with a different vendor or weaker security) and KARMA APs (one BSSID handing out many SSIDs)'),
  DetectorSignature(sigMesh, 'Mesh nodes', 'Mesh', Icons.hub,
      'Meshtastic (own service UUID) and MeshCore (by name — it rides the generic Nordic UART service) mesh radios'),
  DetectorSignature(sigGlasses, 'Meta glasses', 'Meta glasses', Icons.visibility,
      'Ray-Ban / Oakley Meta smart glasses — Luxottica CID 0x0D53, service 0xFD5F, name or frame OUI (excludes Quest/Portal)'),
  DetectorSignature(sigAxon, 'Law Enforcement', 'LE gear', Icons.local_police,
      'Duty equipment from Axon (Taser, body cameras, Signal — CID 0x034D, service 0xFC81/0xFE6B/0xFE6C, OUI 00:25:DF) and from Motorola Solutions, Hytera, Kenwood, Harris, Tait, WatchGuard and Digital Ally. Those wider vendor OUIs also cover unrelated hardware, so they report as SUSPECTED'),
  DetectorSignature(sigCamera, 'Cameras', 'Cameras', Icons.videocam,
      'Consumer and IP surveillance cameras — Ring, Wyze, Nest, Arlo, Hikvision, Dahua, Reolink, Amcrest, Lorex, Swann, Axis and more, by vendor OUI and by BLE name / WiFi SSID'),
];

class DetectorSigMaskNotifier extends StateNotifier<int> {
  DetectorSigMaskNotifier() : super(0) {
    _load();
  }
  static const _key = 'detector_sig_mask';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = (prefs.getInt(_key) ?? 0) & sigAll;
  }

  Future<void> setBit(int bit, bool on) async {
    state = (on ? (state | bit) : (state & ~bit)) & sigAll;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, state);
  }
}

final detectorSigMaskProvider =
    StateNotifierProvider<DetectorSigMaskNotifier, int>(
        (ref) => DetectorSigMaskNotifier());
