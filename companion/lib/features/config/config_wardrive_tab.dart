part of 'device_config.dart';

class _WardriveConfigTab extends ConsumerStatefulWidget {
  const _WardriveConfigTab();

  @override
  ConsumerState<_WardriveConfigTab> createState() => _WardriveConfigTabState();
}

class _WardriveConfigTabState extends ConsumerState<_WardriveConfigTab> {
  late Future<CollectionStats> _statsFuture;

  @override
  void initState() {
    super.initState();
    _statsFuture = ref.read(databaseProvider).wardriveCollectionStats();
  }

  void _reload() {
    setState(() {
      _statsFuture = ref.read(databaseProvider).wardriveCollectionStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return ListView(
      children: [
        const _WigleSection(),
        const _WdgwarsSection(),
        FutureBuilder<CollectionStats>(
          future: _statsFuture,
          builder: (context, snap) {
            final s = snap.data;
            return IosSection(
              header: 'Your capture database',
              footer: 'From this app\'s own wardrive sessions only.',
              children: [
                if (s == null)
                  const IosRow(title: 'Counting…', trailing: CupertinoActivityIndicator())
                else if (s.isEmpty)
                  IosRow(
                    leading: IosIcon(CupertinoIcons.map, t.textDim),
                    title: 'No data yet',
                    subtitle: const Text('Run a wardrive session to build these stats.'),
                  )
                else ...[
                  for (final (icon, color, label, value) in [
                    (CupertinoIcons.number, AppTheme.accent, 'Unique devices', s.totalUnique),
                    (CupertinoIcons.wifi, AppTheme.wardrive, 'Wi-Fi', s.wifiUnique),
                    (CupertinoIcons.bluetooth, AppTheme.detector, 'Bluetooth', s.bleUnique),
                    (CupertinoIcons.textformat, AppTheme.skySpy, 'Network names', s.ssidCount),
                    (CupertinoIcons.map_fill, AppTheme.success, 'Sessions', s.sessionCount),
                    (CupertinoIcons.waveform_path_ecg, AppTheme.warning, 'Detections logged', s.totalDetections),
                  ])
                    IosRow(
                      leading: IosIcon(icon, color),
                      title: label,
                      detail: Text(_CollectionStatsView._fmt(value), style: TextStyle(color: t.textSecondary, fontSize: 17)),
                    ),
                ],
                IosRow(
                  leading: const IosIcon(CupertinoIcons.arrow_clockwise, AppTheme.accent),
                  title: 'Recount',
                  onTap: _reload,
                ),
              ],
            );
          },
        ),
        FutureBuilder<CollectionStats>(
          future: _statsFuture,
          builder: (context, snap) => snap.data == null || snap.data!.isEmpty ? const SizedBox.shrink() : _CollectionStatsView(stats: snap.data!),
        ),
      ],
    );
  }
}

class _CollectionStatsView extends ConsumerWidget {
  const _CollectionStatsView({required this.stats});
  final CollectionStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final oui = ref.watch(ouiLookupProvider);

    final vendorCounts = <String, int>{};
    for (final e in stats.ouiCounts) {
      final name = oui.lookup('${e.key}:00:00:00') ?? 'Unknown';
      vendorCounts[name] = (vendorCounts[name] ?? 0) + e.value;
    }
    final topVendors = vendorCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final vendors = topVendors.take(12).toList();

    final flockVendorCounts = <String, int>{};
    for (final e in stats.flockOuiCounts) {
      final name = oui.lookup('${e.key}:00:00:00') ?? 'Unknown';
      flockVendorCounts[name] = (flockVendorCounts[name] ?? 0) + e.value;
    }
    final flockVendors = (flockVendorCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(8)
        .toList();

    final auth = stats.authCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    Widget ranked(String header, List<MapEntry<String, int>> rows, Color Function(MapEntry<String, int> e, int max) color) {
      final maxV = rows.first.value;
      return IosSection(header: header, children: [
        for (final e in rows)
          IosRow(
            title: e.key,
            subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: _Bar(fraction: maxV == 0 ? 0 : e.value / maxV, color: color(e, maxV))),
            detail: Text(_fmt(e.value), style: TextStyle(color: AppTheme.of(context).textSecondary, fontSize: 17)),
          ),
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stats.channelCounts.isNotEmpty)
          IosSection(header: 'Channels', children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _ChannelChart(counts: {for (final e in stats.channelCounts.entries) if (e.key <= 14) e.key: e.value}, band: '2.4 GHz', color: AppTheme.accent),
                if (stats.channelCounts.keys.any((c) => c >= 36)) ...[
                  const SizedBox(height: 16),
                  _ChannelChart(counts: {for (final e in stats.channelCounts.entries) if (e.key >= 36) e.key: e.value}, band: '5 GHz', color: AppTheme.skySpy, angled: true),
                ],
              ]),
            ),
          ]),
        if (vendors.isNotEmpty) ranked('Top vendors', vendors, (e, m) => _heat(e.value, m)),
        if (flockVendors.isNotEmpty) ranked('Top Flock vendors', flockVendors, (_, _) => AppTheme.flockBle),
        if (auth.isNotEmpty)
          ranked(
            'Encryption',
            [for (final e in auth) MapEntry(_authLabel(e.key), e.value)],
            (e, _) => _authColor(auth.firstWhere((a) => _authLabel(a.key) == e.key).key),
          ),
      ],
    );
  }

  static String _fmt(int c) {
    if (c >= 1000000) return '${(c / 1000000).toStringAsFixed(1)}M';
    if (c >= 1000) return '${(c / 1000).toStringAsFixed(1)}K';
    return '$c';
  }

  static Color _heat(int value, int max) {
    final f = max == 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return Color.lerp(AppTheme.wdgwars, AppTheme.wardrive, 1 - f)!;
  }

  static String _authLabel(int a) => switch (a) {
        0 => 'Open',
        1 => 'WEP',
        2 => 'WPA',
        3 => 'WPA2',
        4 => 'WPA/WPA2',
        5 => 'WPA2-EAP',
        6 => 'WPA3',
        _ => 'Other',
      };

  static Color _authColor(int a) => switch (a) {
        0 => AppTheme.error,
        1 => AppTheme.error,
        2 => AppTheme.warning,
        6 => AppTheme.success,
        _ => AppTheme.accent,
      };
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(children: [
        Container(height: 6, color: t.surfaceLight),
        FractionallySizedBox(widthFactor: fraction.clamp(0.02, 1.0), child: Container(height: 6, color: color.withValues(alpha: 0.85))),
      ]),
    );
  }
}

class _ChannelChart extends StatelessWidget {
  const _ChannelChart({
    required this.counts,
    required this.band,
    required this.color,
    this.angled = false,
  });
  final Map<int, int> counts;
  final String band;
  final Color color;
  final bool angled;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    if (counts.isEmpty) return const SizedBox.shrink();
    final entries = counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final maxV = entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    final countStyle = TextStyle(color: t.textDim, fontSize: 10);
    final chStyle = TextStyle(color: t.textSecondary, fontSize: 11, fontWeight: FontWeight.w600);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(band, style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SizedBox(
          height: angled ? 92 : 64,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: entries.map((e) {
              final f = maxV == 0 ? 0.0 : (e.value / maxV).clamp(0.06, 1.0);
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: angled ? 1.0 : 1.5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (angled)
                        _diag(_CollectionStatsView._fmt(e.value), countStyle)
                      else
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                              _CollectionStatsView._fmt(e.value), style: countStyle),
                        ),
                      const SizedBox(height: 2),
                      Container(
                        height: 40 * f,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.85),
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(2)),
                        ),
                      ),
                      const SizedBox(height: 3),
                      if (angled)
                        _diag('${e.key}', chStyle)
                      else
                        Text('${e.key}', style: chStyle),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  static Widget _diag(String s, TextStyle style) => SizedBox(
        height: 20,
        child: OverflowBox(
          minWidth: 0,
          maxWidth: 70,
          alignment: Alignment.center,
          child: Transform.rotate(
            angle: -0.7,
            child: Text(s, maxLines: 1, softWrap: false, style: style),
          ),
        ),
      );
}

