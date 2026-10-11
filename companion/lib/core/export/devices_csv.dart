import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/classify/observation.dart';
import 'package:oui_spy/core/export/detections_csv.dart';

class DevicesCsv {
  static const columns = <String>[
    'mac',
    'name',
    'radio',
    'classes',
    'signatures',
    'vendor',
    'guess',
    'confidence',
    'rssi',
    'rssi_min',
    'rssi_max',
    'channel',
    'first_seen',
    'last_seen',
    'sources',
    'lat',
    'lon',
  ];

  static String _iso(int ms) =>
      ms <= 0 ? '' : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

  static List<String> cells(ClassifiedDevice d, {String? vendor}) {
    final o = d.obs;
    final g = d.guess;
    final fix = o.gpsTrail.isEmpty ? null : o.gpsTrail.last;
    return [
      o.mac,
      o.name,
      o.kind == RadioKind.ble ? 'BLE' : 'WIFI',
      {for (final s in d.signatures) s.kind.label}.join('; '),
      d.signatureNames.join('; '),
      vendor ?? d.vendor ?? '',
      g.headline,
      g.confidence.name,
      '${o.rssi}',
      '${o.rssiMin}',
      '${o.rssiMax}',
      o.channel > 0 ? '${o.channel}' : '',
      _iso(o.firstSeenMs),
      _iso(o.lastSeenMs),
      (d.sources.toList()..sort()).join('; '),
      fix == null ? '' : fix.lat.toStringAsFixed(6),
      fix == null ? '' : fix.lon.toStringAsFixed(6),
    ];
  }

  static String generate(Iterable<ClassifiedDevice> devices, {String? Function(String mac)? vendorOf}) {
    final b = StringBuffer()..writeln(columns.join(','));
    for (final d in devices) {
      final v = d.obs.mac.isEmpty ? null : vendorOf?.call(d.obs.mac);
      b.writeln(cells(d, vendor: v).map(csvCell).join(','));
    }
    return b.toString();
  }
}
