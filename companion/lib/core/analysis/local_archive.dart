// SPDX-License-Identifier: MIT
import 'package:drift/drift.dart';
import 'package:oui_spy/core/db/app_database.dart';

/// Offline analysis over everything already captured or imported — live
/// sessions and WiGLE CSV imports alike. Nothing here touches the network.

class ArchiveOverview {
  const ArchiveOverview({
    required this.detections,
    required this.uniqueMacs,
    required this.uniqueSsids,
    required this.withGps,
    required this.sessions,
    required this.byEngine,
    this.first,
    this.last,
  });

  final int detections;
  final int uniqueMacs;
  final int uniqueSsids;
  final int withGps;
  final int sessions;
  final Map<String, int> byEngine;
  final DateTime? first;
  final DateTime? last;

  bool get isEmpty => detections == 0;

  /// Share of observations carrying a position, 0..1.
  double get gpsCoverage => detections == 0 ? 0 : withGps / detections;
}

/// One device, folded across every time it was seen.
class ArchiveSighting {
  const ArchiveSighting({
    required this.mac,
    required this.ssid,
    required this.deviceName,
    required this.engine,
    required this.observations,
    required this.firstSeen,
    required this.lastSeen,
    required this.bestRssi,
    this.latitude,
    this.longitude,
  });

  final String mac;
  final String ssid;
  final String deviceName;
  final String engine;
  final int observations;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final int bestRssi;
  final double? latitude;
  final double? longitude;

  bool get hasPosition => latitude != null && longitude != null;

  /// A device seen across a span this long is more than a passing hit.
  Duration get span => lastSeen.difference(firstSeen);
}

extension LocalArchive on AppDatabase {
  Future<ArchiveOverview> archiveOverview() async {
    final total = detections.id.count();
    final macs = detections.macAddress.count(distinct: true);
    final minTs = detections.appTimestamp.min();
    final maxTs = detections.appTimestamp.max();

    final row = await (selectOnly(detections)
          ..addColumns([total, macs, minTs, maxTs]))
        .getSingle();

    // SSIDs are stored as '' when absent, so an empty string would otherwise
    // count as a network of its own.
    final ssidCol = detections.ssid.count(distinct: true);
    final ssidRow = await (selectOnly(detections)
          ..where(detections.ssid.equals('').not())
          ..addColumns([ssidCol]))
        .getSingle();

    final gpsCol = detections.id.count();
    final gpsRow = await (selectOnly(detections)
          ..where(detections.latitude.isNotNull())
          ..addColumns([gpsCol]))
        .getSingle();

    final engineCol = detections.engine;
    final engineCount = detections.id.count();
    final engineRows = await (selectOnly(detections)
          ..addColumns([engineCol, engineCount])
          ..groupBy([engineCol]))
        .get();

    final byEngine = <String, int>{};
    for (final r in engineRows) {
      final name = r.read(engineCol);
      if (name == null) continue;
      byEngine[name] = r.read(engineCount) ?? 0;
    }

    final sessionCount = await (selectOnly(sessions)
          ..addColumns([sessions.id.count()]))
        .getSingle();

    final minMs = row.read(minTs);
    final maxMs = row.read(maxTs);

    return ArchiveOverview(
      detections: row.read(total) ?? 0,
      uniqueMacs: row.read(macs) ?? 0,
      uniqueSsids: ssidRow.read(ssidCol) ?? 0,
      withGps: gpsRow.read(gpsCol) ?? 0,
      sessions: sessionCount.read(sessions.id.count()) ?? 0,
      byEngine: byEngine,
      first: minMs == null ? null : DateTime.fromMillisecondsSinceEpoch(minMs),
      last: maxMs == null ? null : DateTime.fromMillisecondsSinceEpoch(maxMs),
    );
  }

  /// Free-text lookup over the local archive. Matches a MAC (full or partial,
  /// separators optional) or an SSID / device name substring.
  Future<List<ArchiveSighting>> archiveLookup(String term, {int limit = 100}) async {
    final q = term.trim();
    if (q.isEmpty) return const [];

    // A MAC typed as aa:bb:cc, aa-bb-cc or aabbcc should all find the same rows.
    final bare = q.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    final looksLikeMac = bare.length >= 4 && RegExp(r'^[0-9A-Fa-f]+$').hasMatch(bare);

    final pattern = '%${q.toLowerCase()}%';
    final macPattern = '%${_spaced(bare).toLowerCase()}%';

    final rows = await (select(detections)
          ..where((d) {
            final byText = d.ssid.lower().like(pattern) |
                d.deviceName.lower().like(pattern) |
                d.filterDescription.lower().like(pattern);
            if (!looksLikeMac) return byText;
            return byText | d.macAddress.lower().like(macPattern);
          })
          ..orderBy([(d) => OrderingTerm.desc(d.appTimestamp)])
          ..limit(limit * 20))
        .get();

    return _fold(rows, limit);
  }

  /// Everything known about one exact MAC.
  Future<ArchiveSighting?> archiveLookupMac(String mac) async {
    final rows = await (select(detections)
          ..where((d) => d.macAddress.lower().equals(mac.toLowerCase()))
          ..orderBy([(d) => OrderingTerm.desc(d.appTimestamp)]))
        .get();
    final folded = _fold(rows, 1);
    return folded.isEmpty ? null : folded.first;
  }

  /// Insert ':' every two hex digits so a bare query matches stored formatting.
  static String _spaced(String bare) {
    final out = StringBuffer();
    for (var i = 0; i < bare.length; i += 2) {
      if (i > 0) out.write(':');
      out.write(bare.substring(i, (i + 2).clamp(0, bare.length)));
    }
    return out.toString();
  }

  /// Collapse many observations of the same MAC into one row.
  static List<ArchiveSighting> _fold(List<Detection> rows, int limit) {
    final byMac = <String, List<Detection>>{};
    for (final r in rows) {
      byMac.putIfAbsent(r.macAddress.toUpperCase(), () => []).add(r);
    }

    final out = <ArchiveSighting>[];
    for (final entry in byMac.entries) {
      final list = entry.value;
      var first = list.first.appTimestamp;
      var last = list.first.appTimestamp;
      var best = list.first.rssi;
      String ssid = '';
      String name = '';
      double? lat;
      double? lon;
      var observations = 0;

      for (final r in list) {
        if (r.appTimestamp < first) first = r.appTimestamp;
        if (r.appTimestamp > last) last = r.appTimestamp;
        if (r.rssi > best) {
          best = r.rssi;
          // Strongest signal is the most trustworthy position for a device.
          if (r.latitude != null) {
            lat = r.latitude;
            lon = r.longitude;
          }
        }
        if (ssid.isEmpty && r.ssid.isNotEmpty) ssid = r.ssid;
        if (name.isEmpty && r.deviceName.isNotEmpty) name = r.deviceName;
        lat ??= r.latitude;
        lon ??= r.longitude;
        observations += r.count;
      }

      out.add(ArchiveSighting(
        mac: entry.key,
        ssid: ssid,
        deviceName: name,
        engine: list.first.engine,
        observations: observations,
        firstSeen: DateTime.fromMillisecondsSinceEpoch(first),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(last),
        bestRssi: best,
        latitude: lat,
        longitude: lon,
      ));
    }

    out.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return out.length > limit ? out.sublist(0, limit) : out;
  }
}
