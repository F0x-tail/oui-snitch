// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/ble/wd_log_packets.dart';
import 'package:oui_spy/core/db/app_database.dart' hide Detection;
import 'package:oui_spy/core/geofence/geofence_filter.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/ignore_list_state.dart';
import 'package:oui_spy/core/notifications/live_activity_service.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Ble extends Mock implements BleManager {}
class _Gps extends Mock implements GpsProvider {}
class _Ignore extends Mock implements IgnoreListState {}
class _Geo extends Mock implements GeofenceFilter {}
class _Notif extends Mock implements NotificationService {}
class _Live extends Mock implements LiveActivityService {}

/// A row laid out exactly as WdLogRecord in src/wd_log.h.
Uint8List _row({int last = 1, String name = 'CoffeeShop', bool ble = false}) {
  final b = ByteData(WdLogRow.size);
  for (var i = 0; i < 5; i++) {
    b.setUint8(i, 0xA0 + i);
  }
  b.setUint8(5, last);
  final n = utf8.encode(name);
  for (var i = 0; i < n.length; i++) {
    b.setUint8(6 + i, n[i]);
  }
  b.setUint8(39, 7);            // WPA2/WPA3
  b.setUint8(40, 6);            // channel
  b.setInt8(41, -67);
  b.setUint8(42, ble ? 1 : 0);
  b.setInt32(43, -428821000, Endian.little);   // -42.8821
  b.setInt32(47, 1473272000, Endian.little);   // 147.3272
  b.setInt16(51, 45, Endian.little);
  b.setUint16(53, 52, Endian.little);          // 5.2 m
  b.setUint32(55, 1793260800, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  test('a row decodes field for field', () {
    final r = WdLogRow.decode(_row(), 0);
    expect(r.mac, 'a0:a1:a2:a3:a4:01');
    expect(r.name, 'CoffeeShop');
    expect(r.auth, 7);
    expect(r.channel, 6);
    expect(r.rssi, -67);
    expect(r.isBle, isFalse);
    expect(r.latitude, closeTo(-42.8821, 1e-7));
    expect(r.longitude, closeTo(147.3272, 1e-7));
    expect(r.accuracy, closeTo(5.2, 1e-9));
    expect(r.time.millisecondsSinceEpoch, 1793260800 * 1000);
  });

  test('packets are told apart from detections and spool markers', () {
    final rows = [0xFC, 2, ..._row(), ..._row(last: 2)];
    expect(WdLogPackets.isRows(rows), isTrue);
    expect(WdLogPackets.rows(rows).map((r) => r.mac.substring(15)), ['01', '02']);
    expect(WdLogPackets.isHeader([0xFD, 0x10, 0x27, 0, 0, 1]), isTrue);
    expect(WdLogPackets.header([0xFD, 0x10, 0x27, 0, 0, 1]), (count: 10000, full: true));
    expect(WdLogPackets.isDone([0xFB]), isTrue);
    expect(WdLogPackets.isDone([0xFE]), isFalse, reason: 'that is the spool');
    expect(WdLogPackets.isRows([0xFC, 2, ..._row()]), isFalse, reason: 'short packet');
  });

  group('importing the board log', () {
    late StreamController<WdLogEvent> log;
    late _Ble ble;
    late AppDatabase db;
    late WardriveController ctl;
    late _Ignore ignore;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      log = StreamController<WdLogEvent>.broadcast();
      ble = _Ble();
      when(() => ble.connectionState).thenAnswer((_) => const Stream.empty());
      when(() => ble.detections).thenAnswer((_) => const Stream.empty());
      when(() => ble.importedDetections).thenAnswer((_) => const Stream.empty());
      when(() => ble.awayLiveDetections).thenAnswer((_) => const Stream.empty());
      when(() => ble.spoolImport).thenAnswer((_) => const Stream.empty());
      when(() => ble.wdLogImport).thenAnswer((_) => log.stream);
      when(() => ble.confirmWdLogImported()).thenAnswer((_) async {});
      final gps = _Gps();
      when(() => gps.lastPosition).thenReturn(null);
      ignore = _Ignore();
      when(() => ignore.shouldSuppress(
          mac: any(named: 'mac'), ssid: any(named: 'ssid'), isBle: any(named: 'isBle'))).thenReturn(false);
      final geo = _Geo();
      when(() => geo.isExcludedNullable(any(), any())).thenReturn(false);
      db = AppDatabase.forTesting(NativeDatabase.memory());
      ctl = WardriveController(ble, gps, db, ignore, geo, _Notif(), _Live());
    });

    tearDown(() async {
      ctl.dispose();
      await db.close();
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 300));

    test('rows land in a closed offline session and the board is told to clear', () async {
      log.add(const WdLogEvent.header(3, false));
      log.add(WdLogEvent.rows(WdLogPackets.rows([0xFC, 2, ..._row(), ..._row(last: 2, ble: true, name: 'Buds')])));
      log.add(WdLogEvent.rows(WdLogPackets.rows([0xFC, 1, ..._row(last: 3)])));
      log.add(const WdLogEvent.done());
      await settle();
      verify(() => ble.confirmWdLogImported()).called(1);
      final sessions = await db.getWardriveSessions();
      expect(sessions, hasLength(1));
      expect(sessions.single.name, startsWith('Offline wardrive'));
      expect(sessions.single.endedAt, isNotNull);
      final dets = await db.getDetectionsForSession(sessions.single.id);
      expect(dets, hasLength(3));
      expect(dets.where((d) => d.detectionMethod == 'ble_adv').single.deviceName, 'Buds');
    });

    test('a stalled transfer is not confirmed', () async {
      log.add(const WdLogEvent.header(3, false));
      log.add(WdLogEvent.rows(WdLogPackets.rows([0xFC, 1, ..._row()])));
      log.add(const WdLogEvent.aborted());
      log.add(const WdLogEvent.done());
      await settle();
      verifyNever(() => ble.confirmWdLogImported());
    });

    test('ignored devices are dropped but still count, so the board clears', () async {
      when(() => ignore.shouldSuppress(
          mac: 'a0:a1:a2:a3:a4:01', ssid: any(named: 'ssid'), isBle: any(named: 'isBle'))).thenReturn(true);
      log.add(const WdLogEvent.header(2, false));
      log.add(WdLogEvent.rows(WdLogPackets.rows([0xFC, 2, ..._row(), ..._row(last: 2)])));
      log.add(const WdLogEvent.done());
      await settle();
      verify(() => ble.confirmWdLogImported()).called(1);
      final s = (await db.getWardriveSessions()).single;
      expect((await db.getDetectionsForSession(s.id)).map((d) => d.macAddress), ['a0:a1:a2:a3:a4:02']);
    });
  });
}
