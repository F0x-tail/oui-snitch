import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';
import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/classify/observation.dart';
import 'package:oui_spy/core/classify/signature_engine.dart';
import 'package:oui_spy/core/models/engine.dart';

List<int> _apRecord(List<int> ieOuis, {String ssid = ''}) {
  final b = List<int>.filled(19, 0);
  b[0] = Engine.wardrive.index;
  b.setRange(1, 7, [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]);
  b[7] = 0xC4;
  b[8] = 6;
  b[13] = 0;
  final ext = List<int>.filled(55, 0);
  ext.setRange(0, ssid.length, ssid.codeUnits);
  return [...b, ...ext, if (ieOuis.isNotEmpty) ...[ieOuis.length, ...ieOuis]];
}

void main() {
  final engine = SignatureEngine([
    Signature.fromJson({
      'id': 'fleet-ie',
      'name': 'IE fleet',
      'kind': 'CAMERA',
      'rules': [
        {'kind': 'VENDOR_IE_OUI', 'text': '50:6F:9A'},
      ],
    }),
  ]);

  Observation obs(List<int> rec) => observationFromDetection(BleProtocol.decodeDetection(rec,
      sessionId: 's', nodeId: 'n', appTimestamp: DateTime.fromMillisecondsSinceEpoch(1000)));

  test('fw wifi_ap record with vendor IEs reaches VENDOR_IE_OUI rule', () {
    final o = obs(_apRecord([0x00, 0x50, 0xF2, 0x50, 0x6F, 0x9A], ssid: 'cam'));
    expect(o.vendorIeOuis, ['0050F2', '506F9A']);
    expect(o.hiddenSsid, isFalse);
    expect(engine.match(o).map((s) => s.id), ['fleet-ie']);
  });

  test('S3 capture (v3_app_controlled_ie_e2e, real beacons) decodes IEs and SSIDs exactly', () {
    final lines = File('test/fixtures/ie_e2e_capture.txt').readAsLinesSync().where((l) => l.isNotEmpty).toList();
    final want = [
      ('CenturyLink3463', ['00904C', '0050F2', '506F9A', '000986'], false),
      ('pHoneypot', ['0050F2', '00904C', '001018', '506F9A'], false),
      ('VictronSetup', ['0050F2', '00037F'], false),
      ('imwe', ['0050F2', '00037F', '8CFDF0', '00156D'], false),
      ('', ['001018', '0050F2', '506F9A'], true),
      ('Tacos', ['0050F2'], false),
    ];
    final full = SignatureEngine(Signature.parseCatalog(File('assets/fieldwatch-signatures-v2.json').readAsStringSync()));
    for (var i = 0; i < lines.length; i++) {
      final bytes = [for (var j = 0; j < lines[i].length; j += 2) int.parse(lines[i].substring(j, j + 2), radix: 16)];
      final o = obs(bytes);
      expect(o.kind, RadioKind.wifi);
      expect(o.name, want[i].$1);
      expect(o.vendorIeOuis, want[i].$2);
      expect(o.hiddenSsid, want[i].$3);
      full.match(o);
    }
  });

  test('old 74-byte record: no IEs, empty ssid flags hidden', () {
    final o = obs(_apRecord(const []));
    expect(o.vendorIeOuis, isEmpty);
    expect(o.hiddenSsid, isTrue);
    expect(engine.match(o), isEmpty);
  });
}
