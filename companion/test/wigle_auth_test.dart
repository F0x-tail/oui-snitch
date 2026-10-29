// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/export/wigle_csv.dart';
import 'package:oui_spy/core/export/wigle_csv_import.dart';

void main() {
  test('every auth code the board sends has its own WiGLE tag', () {
    final tags = [for (var c = 0; c <= 9; c++) WigleCsv.authTag(c)];
    expect(tags.toSet().length, 10);
    expect(tags, isNot(contains('[UNKNOWN]')));
  });

  test('an unknown or missing code is written as unknown, never as WPA2', () {
    // Regression: these used to be exported as [WPA2_PSK].
    expect(WigleCsv.authTag(null), '[UNKNOWN]');
    expect(WigleCsv.authTag(42), '[UNKNOWN]');
    expect(WigleCsv.authTag(kAuthUnknown), '[UNKNOWN]');
  });

  test('an exported tag reads back as the same code', () {
    for (var c = 0; c <= 9; c++) {
      expect(WigleCsvImport.parseAuthMode(WigleCsv.authTag(c)), c, reason: WigleCsv.authTag(c));
    }
    expect(WigleCsvImport.parseAuthMode('[UNKNOWN]'), kAuthUnknown);
  });

  test('other wardrivers\' security strings map sensibly', () {
    expect(WigleCsvImport.parseAuthMode('[WPA2_WPA3_PSK]'), 7);
    expect(WigleCsvImport.parseAuthMode('[WPA3_PSK]'), 6);
    expect(WigleCsvImport.parseAuthMode('[UNDEFINED]'), kAuthUnknown);
  });
}
