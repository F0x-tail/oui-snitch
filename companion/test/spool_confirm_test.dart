// SPDX-License-Identifier: MIT
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/db/app_database.dart' hide Detection;
import 'package:oui_spy/core/geofence/geofence_filter.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/ignore_list_state.dart';
import 'package:oui_spy/core/notifications/live_activity_service.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Ble extends Mock implements BleManager {}
class _Gps extends Mock implements GpsProvider {}
class _Ignore extends Mock implements IgnoreListState {}
class _Geo extends Mock implements GeofenceFilter {}
class _Notif extends Mock implements NotificationService {}
class _Live extends Mock implements LiveActivityService {}

Detection _det(int i) => Detection(
      id: '$i',
      sessionId: '',
      nodeId: '',
      macAddress: 'de:ad:be:ef:00:${(i % 256).toRadixString(16).padLeft(2, '0')}',
      engine: Engine.detector,
      method: 'tracker',
      rssi: -60,
      channel: 0,
      deviceTimestampMs: 1000 + i,
      appTimestamp: DateTime(2026),
    );

typedef _Rig = ({
  _Ble ble,
  StreamController<Detection> imported,
  StreamController<SpoolImportProgress> progress,
  WardriveController ctl,
  AppDatabase db,
});

_Rig _rig() {
  SharedPreferences.setMockInitialValues({});
  final conn = StreamController<NodeConnectionState>.broadcast();
  final live = StreamController<Detection>.broadcast();
  final imported = StreamController<Detection>.broadcast();
  final away = StreamController<Detection>.broadcast();
  final progress = StreamController<SpoolImportProgress>.broadcast();
  final wdLog = StreamController<WdLogEvent>.broadcast();
  final ble = _Ble();
  when(() => ble.wdLogImport).thenAnswer((_) => wdLog.stream);
  when(() => ble.connectionState).thenAnswer((_) => conn.stream);
  when(() => ble.detections).thenAnswer((_) => live.stream);
  when(() => ble.importedDetections).thenAnswer((_) => imported.stream);
  when(() => ble.awayLiveDetections).thenAnswer((_) => away.stream);
  when(() => ble.spoolImport).thenAnswer((_) => progress.stream);
  when(() => ble.importDeviceNowMs).thenReturn(5000);
  when(() => ble.offlineScanEnabled).thenReturn(true);
  final gps = _Gps();
  when(() => gps.lastPosition).thenReturn(null);
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final ctl = WardriveController(ble, gps, db, _Ignore(), _Geo(), _Notif(), _Live());
  return (ble: ble, imported: imported, progress: progress, ctl: ctl, db: db);
}

void _batch(_Rig r, int n) {
  r.progress.add(SpoolImportProgress(seen: 0, total: n, dropped: 0, done: false, aborted: false));
  for (var i = 0; i < n; i++) {
    r.imported.add(_det(i));
  }
  r.progress.add(SpoolImportProgress(seen: n, total: n, dropped: 0, done: true, aborted: false));
}

void main() {
  test('a fully imported batch is confirmed so the board clears it', () async {
    final r = _rig();
    when(() => r.ble.confirmSpoolImported()).thenAnswer((_) async {});
    _batch(r, 287);
    await Future<void>.delayed(const Duration(seconds: 2));
    verify(() => r.ble.confirmSpoolImported()).called(1);
    r.ctl.dispose();
    await r.db.close();
  });

  test('a clear that fails to send is retried', () async {
    final r = _rig();
    var calls = 0;
    when(() => r.ble.confirmSpoolImported()).thenAnswer((_) async {
      if (++calls < 3) throw StateError('GATT busy');
    });
    _batch(r, 20);
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(calls, 3);
    r.ctl.dispose();
    await r.db.close();
  });

  test('a batch whose clear never got through does not block the next', () async {
    final r = _rig();
    var calls = 0;
    when(() => r.ble.confirmSpoolImported()).thenAnswer((_) async {
      calls++;
      if (calls <= 3) throw StateError('no link to the board');
    });
    _batch(r, 10);
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(calls, 3, reason: 'first batch: all three attempts fail');
    _batch(r, 10);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(calls, 4, reason: 'second batch must still be confirmed');
    r.ctl.dispose();
    await r.db.close();
  });
}
