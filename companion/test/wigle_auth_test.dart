// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/export/wigle_csv.dart';
import 'package:oui_spy/core/export/wigle_csv_import.dart';

void main() {
  test('every auth code the board sends has its own Android capability string', () {
    final tags = [for (var c = 0; c <= 9; c++) WigleCsv.authTag(c)];
    expect(tags.toSet().length, 10);
    expect(tags.every((t) => t.endsWith('[ESS]')), isTrue);
    expect(WigleCsv.authTag(7), '[WPA2-PSK][RSN-PSK+SAE][ESS]');
  });

  test('an unknown or missing code is left blank, never WPA2 and never open', () {
    // Regression: these used to be exported as [WPA2_PSK].
    expect(WigleCsv.authTag(null), '');
    expect(WigleCsv.authTag(42), '');
    expect(WigleCsv.authTag(kAuthUnknown), '');
  });

  test('an exported string reads back as the same code', () {
    for (var c = 0; c <= 9; c++) {
      expect(WigleCsvImport.parseAuthMode(WigleCsv.authTag(c)), c, reason: WigleCsv.authTag(c));
    }
    expect(WigleCsvImport.parseAuthMode(''), kAuthUnknown);
  });

  test('WiGLE\'s own and other wardrivers\' strings map sensibly', () {
    expect(WigleCsvImport.parseAuthMode('[WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]'), 3);
    expect(WigleCsvImport.parseAuthMode('[RSN-SAE-CCMP][ESS]'), 6);
    expect(WigleCsvImport.parseAuthMode('[WPA2-PSK-CCMP][RSN-PSK+SAE-CCMP][ESS]'), 7);
    expect(WigleCsvImport.parseAuthMode('[WPA2-EAP/SHA1-CCMP][RSN-EAP/SHA1-CCMP][ESS]'), 5);
    expect(WigleCsvImport.parseAuthMode('[ESS]'), 0);
    expect(WigleCsvImport.parseAuthMode('[WPA2_WPA3_PSK]'), 7);
    expect(WigleCsvImport.parseAuthMode('[WPA3_PSK]'), 6);
    expect(WigleCsvImport.parseAuthMode('[WPA2_PSK]'), 3);
    expect(WigleCsvImport.parseAuthMode('[WPA_WPA2_PSK]'), 4);
    expect(WigleCsvImport.parseAuthMode('[UNDEFINED]'), kAuthUnknown);
  });
}
