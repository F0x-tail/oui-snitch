// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/detection_icon.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';

Detection _d(Engine e, String method) => Detection(
      id: 'x',
      sessionId: 's',
      nodeId: 'n',
      macAddress: 'de:ad:be:ef:00:01',
      engine: e,
      method: method,
      rssi: -60,
      channel: 6,
      deviceTimestampMs: 0,
      appTimestamp: DateTime(2026),
    );

void main() {
  test('detector hits get an icon per kind, not one generic radar', () {
    // Regression: every detector detection used to render Icons.radar, so a
    // doorbell, a tracker following you and a body camera were identical pins.
    final icons = {
      for (final m in [
        'tracker', 'camera', 'glasses', 'axon', 'mesh',
        'deauth_storm', 'probe_ssid', 'evil_twin',
      ])
        m: detectionMapIcon(_d(Engine.detector, m)),
    };
    expect(icons.values.toSet().length, icons.length,
        reason: 'each detector kind must be visually distinct: $icons');
    expect(icons['tracker'], Icons.track_changes);
    expect(icons['axon'], Icons.local_police);
    expect(icons['glasses'], Icons.visibility);
  });

  test('Axon duty equipment does not wear the Flock camera symbol', () {
    // Slot 1 used to be the Flock BLE engine, so the two shared the videocam.
    // It is the Axon engine now: a body camera on an officer and a municipal
    // ALPR pole are different findings and must not look alike on the map.
    expect(detectionMapIcon(_d(Engine.axon, 'axon')), Icons.local_police);
    expect(detectionMapIcon(_d(Engine.axon, 'axon')),
        isNot(detectionMapIcon(_d(Engine.flockWifi, 'wildcard_probe_ie_sig'))));
  });

  test('Flock is visually distinct from a consumer camera', () {
    // Municipal ALPR vs a Ring doorbell must not look the same on the map.
    expect(detectionMapIcon(_d(Engine.flockWifi, 'oui_addr2')),
        isNot(detectionMapIcon(_d(Engine.detector, 'camera'))));
  });

  test('audit hardware folds together, matching the signature bitmask', () {
    final flipper = detectionMapIcon(_d(Engine.detector, 'flipper'));
    expect(detectionMapIcon(_d(Engine.detector, 'pwnagotchi')), flipper);
    expect(detectionMapIcon(_d(Engine.detector, 'pineapple')), flipper);
  });

  test('Wi-Fi attacks share the deauth symbol, tracker spam has its own', () {
    // Same signature bit as deauth floods, so the same symbol.
    expect(detectionMapIcon(_d(Engine.detector, 'wifi_attack')),
        detectionMapIcon(_d(Engine.detector, 'deauth_storm')));
    // A burst of fakes is not a tracker and must not look like one.
    expect(detectionMapIcon(_d(Engine.detector, 'ble_spam')),
        isNot(detectionMapIcon(_d(Engine.detector, 'tracker'))));
  });

  test('an unknown method falls back rather than guessing', () {
    expect(detectionMapIcon(_d(Engine.detector, 'something_new')), Icons.radar);
  });

  test('every engine resolves to an icon', () {
    for (final e in Engine.values) {
      expect(() => detectionMapIcon(_d(e, 'x')), returnsNormally, reason: '$e');
    }
  });
}
