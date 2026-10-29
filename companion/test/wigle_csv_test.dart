// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/app_version.dart';
import 'package:oui_spy/core/export/wigle_csv.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';

Detection _d({
  Engine engine = Engine.wardrive,
  String method = 'wifi_ap',
  String mac = 'aa:bb:cc:dd:ee:01',
  double? accuracy = 4.5,
  double? altitude = 45.6,
  int channel = 6,
  String ssid = 'Cafe, Upstairs',
  String name = '',
}) =>
    Detection(
      id: 'x',
      sessionId: 's',
      nodeId: 'n',
      macAddress: mac,
      engine: engine,
      method: method,
      rssi: -61,
      channel: channel,
      deviceTimestampMs: 0,
      appTimestamp: DateTime.utc(2026, 10, 28, 9, 48, 10),
      latitude: -42.88,
      longitude: 147.32,
      altitude: altitude,
      accuracy: accuracy,
      ssid: ssid,
      deviceName: name,
      wardrive: const WardriveExtension(authMode: 3),
    );

void main() {
  List<String> rows(String csv) => csv.split('\r\n').where((l) => l.isNotEmpty).toList();

  test('pre-header carries the real versions, brand and no display', () {
    final h = rows(WigleCsv.generate([], board: 'xiao_esp32s3', firmwareVersion: '0.6.1')).first;
    expect(h, startsWith('WigleWifi-1.6,appRelease=$kAppVersion,model=OUI-SNITCH,release=0.6.1,'));
    expect(h, contains('display=none'));
    expect(h, contains('brand=Seeed Studio'));
    expect(h, endsWith('star=Sol,body=3,subBody=0'));
  });

  test('only wardrive observations become rows', () {
    final csv = WigleCsv.generate([
      _d(),
      _d(engine: Engine.detector, method: 'tracker', mac: 'aa:bb:cc:dd:ee:02'),
      _d(engine: Engine.detector, method: 'deauth_storm', mac: 'aa:bb:cc:dd:ee:03'),
      _d(engine: Engine.skySpy, method: 'odid_ble', mac: 'aa:bb:cc:dd:ee:04'),
    ]);
    final data = rows(csv).skip(2).toList();
    expect(data, hasLength(1));
    expect(data.single, startsWith('aa:bb:cc:dd:ee:01,'));
  });

  test('a Wi-Fi row follows the field rules', () {
    final r = rows(WigleCsv.generate([_d()]))[2];
    expect(r, 'aa:bb:cc:dd:ee:01,"Cafe, Upstairs",[WPA2-PSK][RSN-PSK][ESS],'
        '2026-10-28 09:48:10,6,2437,-61,-42.88,147.32,46,4.5,,,WIFI');
  });

  test('a Bluetooth row has channel 0 and no frequency', () {
    final r = rows(WigleCsv.generate([_d(method: 'ble_adv', ssid: '', name: 'Buds', channel: 37)]))[2];
    expect(r, 'aa:bb:cc:dd:ee:01,Buds,[LE],2026-10-28 09:48:10,0,,-61,-42.88,147.32,46,4.5,,,BLE');
  });

  test('unknown accuracy is left blank, never written as a perfect 0', () {
    final r = rows(WigleCsv.generate([_d(accuracy: null)]))[2];
    expect(r.split(',')[11], '');
  });
}
