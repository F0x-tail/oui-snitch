// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/classify/antihunter_class.dart';
import 'package:oui_spy/core/classify/device_explain.dart';
import 'package:oui_spy/core/classify/observation.dart';

Observation _ble({List<MfgRecord> mfg = const [], List<String> uuids = const [],
        List<ServiceDataRecord> sd = const [], int? appearance}) =>
    Observation(
      key: 'BLE:AA',
      kind: RadioKind.ble,
      mac: 'C0:11:22:33:44:55',
      mfgRecords: mfg,
      serviceUuids: uuids,
      serviceData: sd,
      appearance: appearance,
    );

void main() {
  test('tables sorted-unique and labels well formed', () {
    for (final t in [bleUuid16Class, bleCompanyClass]) {
      expect(t.length, greaterThan(100));
      expect(t.values.every((v) => v.contains('-')), isTrue);
    }
  });

  test('company id hint', () {
    final h = AntiHunterClass.hints(_ble(mfg: [const MfgRecord(0x09C8, '0102')]));
    expect(h.single.bucket, 'camera');
    expect(h.single.label, 'a Flock camera');
  });

  test('128-bit base uuid folds to 16-bit', () {
    final h = AntiHunterClass.hints(_ble(uuids: ['0000FD5F-0000-1000-8000-00805F9B34FB']));
    expect(h.single.label, contains('Meta'));
  });

  test('samsung smarttag subtype and eddystone url', () {
    final h = AntiHunterClass.hints(_ble(
      mfg: [const MfgRecord(0x0075, '4209AA')],
      sd: [const ServiceDataRecord('FEAA', '10FF')],
    ));
    expect(h.map((e) => e.label), containsAll(['a Samsung SmartTag', 'an Eddystone-URL beacon']));
  });

  test('appearance reaches guess when nothing else matches', () {
    final g = DeviceExplain.guess(_ble(appearance: 0x00C1), const []);
    expect(g.headline, contains('a watch'));
  });

  test('empty adv yields no hints', () {
    expect(AntiHunterClass.hints(_ble()), isEmpty);
  });
}
