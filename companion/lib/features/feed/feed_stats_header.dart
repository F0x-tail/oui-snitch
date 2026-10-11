import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/oui/oui_lookup_service.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

class FeedStatsHeader extends ConsumerWidget {
  const FeedStatsHeader({super.key, required this.detections});
  final List<Detection> detections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final oui = ref.read(ouiLookupProvider);
    final topVendors = _topVendors(detections, oui, 4);
    final topFlock = _topFlock(detections, 3);
    if (topVendors.isEmpty && topFlock.isEmpty) return const SizedBox.shrink();
    String line(List<_ChipEntry> e) => e.map((x) => '${x.label} ${x.count}').join(' · ');
    return IosSection(header: 'Summary', children: [
      if (topVendors.isNotEmpty)
        IosRow(
          leading: const IosIcon(CupertinoIcons.building_2_fill, AppTheme.accent),
          title: 'Top vendors',
          subtitle: Text(line(topVendors)),
        ),
      if (topFlock.isNotEmpty)
        IosRow(
          leading: IosIcon(CupertinoIcons.video_camera_solid, Engine.flockWifi.color),
          title: 'Most-seen Flock devices',
          subtitle: Text(line(topFlock)),
        ),
    ]);
  }

  static List<_ChipEntry> _topVendors(
    List<Detection> dets,
    OuiLookupService oui,
    int n,
  ) {
    final vendorCounts = <String, int>{};
    for (final d in dets) {
      final vendor = oui.lookup(d.macAddress) ?? 'Unknown';
      final name = vendor.startsWith('Flock') ? 'Flock' : _shortenVendor(vendor);
      vendorCounts[name] = (vendorCounts[name] ?? 0) + d.count;
    }
    vendorCounts.remove('Unknown');
    final sorted = vendorCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .take(n)
        .map((e) => _ChipEntry(label: e.key, count: e.value))
        .toList();
  }

  static List<_ChipEntry> _topFlock(List<Detection> dets, int n) {
    final flockDets = dets.where((d) =>
        d.engine == Engine.flockBle ||
        d.engine == Engine.flockWifi ||
        (d.engine == Engine.wardrive && d.method == 'flock_oui'));
    final macCounts = <String, _FlockAgg>{};
    for (final d in flockDets) {
      final mac = d.macAddress.toUpperCase();
      final existing = macCounts[mac];
      if (existing != null) {
        macCounts[mac] = _FlockAgg(
          count: existing.count + d.count,
          method: d.method,
          isRaven: existing.isRaven || (d.flock?.isRaven ?? false),
          bestRssi: d.rssi > existing.bestRssi ? d.rssi : existing.bestRssi,
        );
      } else {
        macCounts[mac] = _FlockAgg(
          count: d.count,
          method: d.method,
          isRaven: d.flock?.isRaven ?? false,
          bestRssi: d.rssi,
        );
      }
    }
    final sorted = macCounts.entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));
    return sorted.take(n).map((e) {
      final agg = e.value;
      return _ChipEntry(label: agg.isRaven ? '${e.key} (Raven)' : e.key, count: agg.count);
    }).toList();
  }

  static String _shortenVendor(String v) {
    var s = v
        .replaceAll(RegExp(r',?\s+(Inc|Inc\.|LLC|Ltd|Ltd\.|Corp|Corp\.|Corporation|Co\.|Co|GmbH|S\.A\.|S\.r\.l\.|AG|KG|Limited|Solutions|Networks|Communications|Technology|Technologies|Systems|International|Electronics|Industries)\.?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*&\s*Co\.?\s*KG', caseSensitive: false), '')
        .trim();
    if (s.length > 18) s = '${s.substring(0, 17)}…';
    return s.isEmpty ? v : s;
  }
}

class _FlockAgg {
  const _FlockAgg({
    required this.count,
    required this.method,
    required this.isRaven,
    required this.bestRssi,
  });
  final int count;
  final String method;
  final bool isRaven;
  final int bestRssi;
}

class _ChipEntry {
  const _ChipEntry({required this.label, required this.count});
  final String label;
  final int count;
}
