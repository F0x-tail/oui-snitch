// SPDX-License-Identifier: MIT
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';
import 'package:oui_spy/core/export/wigle_csv.dart';

/// A wardrive packet laid out as packDetection() in src/ble_gatt.cpp writes
/// it: 19-byte header, ssid[33], auth[1], device_name[21], adv_len[1],
/// adv[n], then for Wi-Fi: wifi_caps[1], rcoi_len[1], rcoi pairs.
List<int> _packet({required bool ble, List<int> adv = const [], List<int> tail = const []}) {
  final b = List<int>.filled(19, 0);
  b[0] = 6;                      // ENGINE_WARDRIVE
  for (var i = 0; i < 6; i++) {
    b[1 + i] = 0x10 + i;
  }
  b[7] = 0xC5;                   // rssi -59
  b[8] = ble ? 0 : 11;
  b[13] = ble ? 1 : 0;           // METHOD_BLE_ADV / METHOD_WIFI_AP
  final ssid = List<int>.filled(33, 0)..setAll(0, utf8.encode(ble ? '' : 'Airport'));
  final name = List<int>.filled(21, 0)..setAll(0, utf8.encode(ble ? 'Buds' : ''));
  return [...b, ...ssid, 3, ...name, adv.length, ...adv, ...tail];
}

void main() {
  group('AuthMode with ciphers', () {
    test('WPA2 with CCMP, as Android writes it', () {
      expect(WigleCsv.authTag(3, caps: 0x81), '[WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]');
    });
    test('mixed WPA/WPA2 keeps each protocol\'s own ciphers', () {
      expect(WigleCsv.authTag(4, caps: 0x80 | 0x01 | 0x02 | 0x08),
          '[WPA-PSK-TKIP][WPA2-PSK-CCMP+TKIP][RSN-PSK-CCMP+TKIP][ESS]');
    });
    test('an ad hoc network is IBSS', () {
      expect(WigleCsv.authTag(0, caps: 0x80 | 0x20), '[IBSS]');
    });
    test('the IBSS bit means nothing unless the firmware set the valid bit', () {
      expect(WigleCsv.authTag(0, caps: 0x20), '[ESS]');
    });
  });

  test('roaming OIs read as WiGLE writes them', () {
    expect(BleProtocol.decodeRcois([5, 0x5A, 0x03, 0xBA, 0x00, 0x00, 3, 0x00, 0x1B, 0xC5]),
        '5A03BA0000 001BC5');
    expect(BleProtocol.decodeRcois([]), '');
  });

  test('the Bluetooth company ID comes from manufacturer data', () {
    // flags AD, then manufacturer data for Apple (0x004C).
    expect(BleProtocol.bleCompanyId([0x02, 0x01, 0x06, 0x05, 0xFF, 0x4C, 0x00, 0x12, 0x19]), 0x004C);
    expect(BleProtocol.bleCompanyId([0x02, 0x01, 0x06]), isNull);
  });

  test('a Wi-Fi packet\'s tail decodes into caps and RCOIs', () {
    final d = BleProtocol.decodeDetection(
      _packet(ble: false, adv: [0x00, 0x50, 0xF2], tail: [0x81, 6, 5, 0x5A, 0x03, 0xBA, 0x00, 0x00]),
      sessionId: 's', nodeId: 'n', appTimestamp: DateTime(2026),
    );
    expect(d.wardrive!.wifiCaps, 0x81);
    expect(d.wardrive!.rcois, '5A03BA0000');
    expect(d.wardrive!.mfgrId, isNull, reason: 'Wi-Fi adv bytes are vendor OUIs, not AD structures');
  });

  test('a BLE packet yields the company ID and no Wi-Fi fields', () {
    final d = BleProtocol.decodeDetection(
      _packet(ble: true, adv: [0x05, 0xFF, 0x75, 0x00, 0x01, 0x02]),
      sessionId: 's', nodeId: 'n', appTimestamp: DateTime(2026),
    );
    expect(d.wardrive!.mfgrId, 0x0075);
    expect(d.wardrive!.wifiCaps, 0);
  });

  test('an older board\'s packet, without the tail, still decodes', () {
    final d = BleProtocol.decodeDetection(
      _packet(ble: false, adv: [0x00, 0x50, 0xF2]),
      sessionId: 's', nodeId: 'n', appTimestamp: DateTime(2026),
    );
    expect(d.wardrive!.wifiCaps, 0);
    expect(d.wardrive!.rcois, '');
    expect(d.ssid, 'Airport');
  });
}
