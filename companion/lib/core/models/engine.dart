// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';

/// All scan engines available in the OUI-SNITCH firmware.
enum Engine {
  // Mid-tone hues: vivid on the dark background, still legible on white.
  detector('Detector', 'WiFi + BLE watchlist alerting', Color(0xFF3286E6), 0x01),
  /// Slot 1. Previously the Flock BLE engine, removed when the community BLE
  /// method stopped working (the Wi-Fi IE fingerprint is the reliable path).
  /// The slot was held reserved because `Engine.index` IS the wire-protocol
  /// engine ID and indexes the firmware's state array — deleting it would
  /// shift every later engine's ID and silently mis-target enable/disable
  /// commands, including on mesh nodes running other builds — and is now
  /// reused for duty-equipment detection. Historical rows stored as 'flockBle'
  /// are mapped on read; see detectionFromDbRow.
  axon('Axon', 'Axon / TASER duty equipment', Color(0xFF9A35E6), 0x02),
  flockWifi(
      'Flock WiFi', 'Flock Safety WiFi promiscuous', Color(0xFFE63577), 0x04),
  foxhunter('Foxhunter', 'WiFi + BLE proximity tracker', Color(0xFF1FA866), 0x08),
  skySpy('Sky Spy', 'FAA Remote ID / ODID detection', Color(0xFF15A89B), 0x10),
  uniPwn(
      'UniPwn', 'Unitree robot exploitation', Color(0xFFE63535), 0x20),
  wardrive(
      'Wardrive', 'WiGLE-style WiFi + BLE capture', Color(0xFFE67435), 0x40),
  pcap(
      'PCAP', 'WiFi/BLE PCAP capture & audit', Color(0xFF13A884), 0x80);

  const Engine(this.label, this.description, this.color, this.bitmask);

  final String label;
  final String description;
  final Color color;
  final int bitmask;

  bool get isBle =>
      this == detector ||
      this == axon ||
      this == foxhunter ||
      this == uniPwn;

  bool get isWifi =>
      this == flockWifi ||
      this == skySpy ||
      this == wardrive ||
      this == pcap;

  /// Engines that scan both WiFi and BLE radios.
  bool get isDualRadio =>
      this == detector ||
      this == axon ||
      this == foxhunter ||
      this == wardrive ||
      this == skySpy;

  IconData get icon {
    return switch (this) {
      Engine.detector => Icons.radar,
      Engine.axon => Icons.local_police,
      Engine.flockWifi => Icons.wifi,
      Engine.foxhunter => Icons.gps_fixed,
      Engine.skySpy => Icons.flight,
      Engine.uniPwn => Icons.smart_toy,
      Engine.wardrive => Icons.drive_eta,
      Engine.pcap => Icons.fiber_manual_record,
    };
  }
}

/// Runtime state of a single engine on the device.
enum EngineState {
  disabled,
  idle,
  scanning,
  active,
  alerting,
  // UniPwn-specific
  targetSelected,
  connecting,
  exploiting,
  complete,
}

int commandedEngineMask(List<EngineState> states) {
  int mask = 0;
  for (final e in Engine.values) {
    if (e.index < states.length && states[e.index] != EngineState.disabled) {
      mask |= e.bitmask;
    }
  }
  return mask;
}

/// Which engines can run simultaneously.
class EngineCompatibility {
  const EngineCompatibility._();

  static const _wifiEngines = {Engine.flockWifi, Engine.skySpy, Engine.wardrive, Engine.pcap};

  static bool _wifiCompatible(Engine a, Engine b) {
    return (a == Engine.wardrive && b == Engine.flockWifi) ||
           (a == Engine.flockWifi && b == Engine.wardrive);
  }

  /// Check if [engine] can be enabled given [activeEngines].
  static bool canEnable(Engine engine, Set<Engine> activeEngines) {
    if (activeEngines.contains(engine)) return true;

    // WiFi engines: only one at a time (wardrive+flockWifi excepted)
    if (engine.isWifi) {
      final conflicts = activeEngines
          .intersection(_wifiEngines)
          .where((e) => !_wifiCompatible(engine, e));
      return conflicts.isEmpty;
    }


    return true;
  }

  /// Returns engines that must be disabled to enable [engine].
  static Set<Engine> conflicts(Engine engine, Set<Engine> activeEngines) {
    final result = <Engine>{};

    if (engine.isWifi) {
      result.addAll(activeEngines
          .intersection(_wifiEngines)
          .where((e) => !_wifiCompatible(engine, e)));
    }

    result.remove(engine);
    return result;
  }
}
