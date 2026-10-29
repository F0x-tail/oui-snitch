// SPDX-License-Identifier: MIT
import 'dart:convert';
import 'dart:typed_data';

/// One wardrive row the board recorded while the phone was away, with the
/// board's own GPS position and GPS time. Mirrors WdLogRecord in
/// src/wd_log.h, 59 bytes little-endian.
class WdLogRow {
  const WdLogRow({
    required this.mac,
    required this.name,
    required this.auth,
    required this.channel,
    required this.rssi,
    required this.isBle,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
    required this.time,
  });

  static const size = 59;

  final String mac;
  final String name;
  final int auth;
  final int channel;
  final int rssi;
  final bool isBle;
  final double latitude;
  final double longitude;
  final double altitude;
  final double accuracy;
  final DateTime time;

  static WdLogRow decode(Uint8List b, int o) {
    final v = ByteData.sublistView(b, o, o + size);
    final mac = [for (var i = 0; i < 6; i++) b[o + i].toRadixString(16).padLeft(2, '0')].join(':');
    var end = o + 6;
    while (end < o + 6 + 33 && b[end] != 0) {
      end++;
    }
    final name = utf8.decode(b.sublist(o + 6, end), allowMalformed: true);
    return WdLogRow(
      mac: mac,
      name: name,
      auth: v.getUint8(39),
      channel: v.getUint8(40),
      rssi: v.getInt8(41),
      isBle: v.getUint8(42) & 0x01 != 0,
      latitude: v.getInt32(43, Endian.little) / 1e7,
      longitude: v.getInt32(47, Endian.little) / 1e7,
      altitude: v.getInt16(51, Endian.little).toDouble(),
      accuracy: v.getUint16(53, Endian.little) / 10.0,
      time: DateTime.fromMillisecondsSinceEpoch(v.getUint32(55, Endian.little) * 1000, isUtc: true),
    );
  }
}

/// The offline wardrive transfer: FD count[4] full[1], FC n[1] rows[n*59]
/// (any number of these), FB. None of FB..FD can start a detection packet,
/// whose first byte is an engine id below 0x88, or the spool's FE/FF.
class WdLogPackets {
  const WdLogPackets._();

  static bool isHeader(List<int> d) => d.length == 6 && d[0] == 0xFD;
  static bool isRows(List<int> d) =>
      d.length >= 2 && d[0] == 0xFC && d.length == 2 + d[1] * WdLogRow.size;
  static bool isDone(List<int> d) => d.length == 1 && d[0] == 0xFB;

  static ({int count, bool full}) header(List<int> d) => (
        count: d[1] | (d[2] << 8) | (d[3] << 16) | (d[4] << 24),
        full: d[5] != 0,
      );

  static List<WdLogRow> rows(List<int> d) {
    final b = Uint8List.fromList(d);
    return [for (var i = 0; i < d[1]; i++) WdLogRow.decode(b, 2 + i * WdLogRow.size)];
  }

  static Uint8List get sendCmd => Uint8List.fromList([0x0F]);
  static Uint8List get clearCmd => Uint8List.fromList([0x10]);
}
