// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';

void main() {
  test('hardware config carries offline-scan byte[5]', () {
    final on = BleProtocol.encodeHardwareConfig(
      buzzer: true, led: true, neopixelBrightness: 10, buzzerVolume: 20,
      extendedOui: false, offlineScan: true);
    expect(on.length, 8);
    expect(on[5], 1);
    final off = BleProtocol.encodeHardwareConfig(
      buzzer: true, led: true, neopixelBrightness: 10, buzzerVolume: 20,
      extendedOui: false, offlineScan: false);
    expect(off[5], 0);
  });

  test('hardware config carries passive-scan byte[7], active by default', () {
    final active = BleProtocol.encodeHardwareConfig(
      buzzer: true, led: true, neopixelBrightness: 10, buzzerVolume: 20);
    expect(active[7], 0);
    final passive = BleProtocol.encodeHardwareConfig(
      buzzer: true, led: true, neopixelBrightness: 10, buzzerVolume: 20,
      passiveBleScan: true);
    expect(passive[7], 1);
    // Every byte before it is unchanged, so older firmware that reads seven
    // bytes sees exactly what it saw before.
    expect(passive.sublist(0, 7), active.sublist(0, 7));
  });

  test('decodes spool header frame', () {
    final frame = [0xFF, 0x05, 0x00, 0x02, 0x00, 0x10, 0x27, 0x00, 0x00];
    expect(BleProtocol.isSpoolHeader(frame), true);
    final h = BleProtocol.decodeSpoolHeader(frame);
    expect(h.count, 5);
    expect(h.dropped, 2);
    expect(h.deviceNowMs, 0x2710);
  });

  test('detects done + non-header frames', () {
    expect(BleProtocol.isSpoolDone([0xFE]), true);
    expect(BleProtocol.isSpoolHeader([0x01, 1, 2, 3]), false);
  });
}
