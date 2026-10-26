// SPDX-License-Identifier: MIT
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';

/// A real S3 detector capture (the one used by detector_notification_e2e_test).
/// Header is 19 bytes (14 + a 5-byte source node id) and filter_desc is the
/// first field of the detector extension, so it starts at absolute offset 19.
const _capture =
    '0040486e8bd31aa9064a1a0000010000000000004e6f6b696120726f75746572000000'
    '0000000000000000000000000000000000';
const _descOffset = 19;
const _descLen = 32;

Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

/// The capture with its description field replaced by [raw].
Uint8List _withDesc(List<int> raw) {
  final b = _hex(_capture);
  for (var i = 0; i < _descLen; i++) {
    b[_descOffset + i] = i < raw.length ? raw[i] : 0;
  }
  return b;
}

/// The decoded description as the notification shows it, with the category
/// lead-in removed. These tests are about decoding the description bytes, not
/// about how the title is framed around them.
String _title(List<int> raw) {
  final det = BleProtocol.decodeDetection(_withDesc(raw),
      sessionId: 's', nodeId: 'n', appTimestamp: DateTime(2026));
  final title = NotificationService.detectionNotificationText(det)!.$1;
  const prefix = 'Watchlist: ';
  return title.startsWith(prefix) ? title.substring(prefix.length) : title;
}

void main() {
  test('the unmodified capture still decodes as before', () {
    expect(_title(utf8.encode('Nokia router')), 'Nokia router');
  });

  test('UTF-8 names survive the BLE round trip', () {
    // Previously String.fromCharCodes() decoded these as Latin-1 and the
    // 0x7f-0x9f byte filter cut multi-byte sequences in half.
    for (final name in ['Café', 'Gästehaus', 'Привет', '日本語', 'Ü-Bahn']) {
      expect(_title(utf8.encode(name)), name, reason: 'round trip for "$name"');
    }
  });

  test('control characters are stripped without eating the text', () {
    expect(_title(utf8.encode('a\u0007b')), 'ab');
    expect(_title(utf8.encode('Ring\u0001cam')), 'Ringcam');
  });

  test('malformed UTF-8 degrades instead of throwing', () {
    // SSIDs are attacker-controlled; a bad byte must not crash the decoder.
    expect(() => _title([0xff, 0xfe, 0x41, 0x42]), returnsNormally);
    expect(_title([0xff, 0xfe, 0x41, 0x42]), contains('AB'));
  });
}
