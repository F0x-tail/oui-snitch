import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/gps/gps_types.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/wigle/wigle_api.dart';
import 'package:oui_spy/core/wigle/wigle_provider.dart';
import 'package:oui_spy/core/wdgwars/wdgwars_provider.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/detections/detections_screen.dart';
import 'package:oui_spy/features/devices/devices_screen.dart' show rssiColor;
import 'package:oui_spy/features/home/engine_card.dart';
import 'package:oui_spy/features/wardrive/session_launch.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

const _engineGroups = <(String, List<Engine>)>[
  ('Flock Safety', [Engine.flockBle, Engine.flockWifi]),
  ('Tracking', [Engine.detector, Engine.foxhunter]),
  ('Specialty', [Engine.skySpy, Engine.uniPwn, Engine.pcap]),
];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    final ble = ref.read(bleManagerProvider);
    return IosPage(
      title: 'OUI-SPY',
      actions: [
        if (state.isConnected)
          IosNavButton(
            icon: CupertinoIcons.arrow_2_squarepath,
            tooltip: 'Switch node',
            onPressed: () async {
              await ble.disconnect();
              if (context.mounted) context.push('/onboarding');
            },
          ),
      ],
      slivers: [
        SliverToBoxAdapter(child: _SpoolImportBanner(stream: ble.awayImport)),
        SliverToBoxAdapter(child: _StatusSection(state: state)),
        if (state.isConnected) const SliverToBoxAdapter(child: _SessionSection()),
        for (final (name, engines) in _engineGroups)
          SliverToBoxAdapter(
            child: IosSection(
              header: name,
              footer: state.isConnected ? null : (name == _engineGroups.last.$1 ? 'Connect a node to turn engines on.' : null),
              children: [
                for (final e in engines)
                  state.isConnected
                      ? EngineRow(engine: e)
                      : IosRow(
                          leading: IosIcon(e.icon, e.color.withValues(alpha: 0.55)),
                          title: e.label,
                          subtitle: Text(e.description),
                          disabled: true,
                        ),
              ],
            ),
          ),
        if (state.isConnected && state.recentDetections.isNotEmpty) SliverToBoxAdapter(child: _RecentSection(state: state)),
        const SliverToBoxAdapter(child: _AccountsSection()),
      ],
    );
  }
}

class _StatusSection extends ConsumerStatefulWidget {
  const _StatusSection({required this.state});
  final AppState state;

  @override
  ConsumerState<_StatusSection> createState() => _StatusSectionState();
}

class _StatusSectionState extends ConsumerState<_StatusSection> {
  GpsPosition? _pos;
  HwGpsState _hw = const HwGpsState(active: false, satellites: 0, source: GpsSource.phone, inUse: false);
  StreamSubscription<GpsPosition>? _posSub;
  StreamSubscription<HwGpsState>? _hwSub;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final gps = ref.read(gpsProvider);
    _pos = gps.lastPosition;
    _hw = gps.hwGps;
    _posSub = gps.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _hwSub = gps.hwGpsStream.listen((h) {
      if (mounted) setState(() => _hw = h);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _hwSub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  String _uptime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${d.inSeconds.remainder(60)}s';
  }

  (String, Color) get _gps {
    if (_hw.inUse) return ('Node GPS · ${_hw.satellites} satellites', AppTheme.gpsGood);
    final p = _pos;
    if (p == null) return (_hw.fallback ? 'Phone GPS · waiting for a fix' : 'No location fix', AppTheme.gpsNone);
    final color = switch (p.quality) {
      GpsQuality.good => AppTheme.gpsGood,
      GpsQuality.fair => AppTheme.gpsFair,
      GpsQuality.poor => AppTheme.gpsPoor,
      GpsQuality.none => AppTheme.gpsNone,
    };
    return ('Phone GPS · ±${p.accuracy.toStringAsFixed(0)} m', color);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final t = AppTheme.of(context);
    final ble = ref.read(bleManagerProvider);
    final connecting = s.connectionState == NodeConnectionState.connecting ||
        s.connectionState == NodeConnectionState.negotiating ||
        s.connectionState == NodeConnectionState.syncing;
    final reconnecting = s.connectionState == NodeConnectionState.reconnecting;
    final (connColor, connText) = s.isConnected
        ? (AppTheme.success, s.sessionStartTime != null ? 'Connected · up ${_uptime(s.sessionUptime)}' : 'Connected')
        : connecting
            ? (AppTheme.warning, 'Connecting…')
            : reconnecting
                ? (AppTheme.error, 'Connection lost · searching for the node')
                : (t.textDim, 'Not connected');
    final (gpsText, gpsColor) = _gps;
    final active = Engine.values.where(s.isEngineActive).length;
    final selfId = AppState.canonicalNodeId(s.nodeId);
    final meshNodes = s.liveKnownNodes.where((id) => id != selfId && !s.isManagerNode(id)).length;

    return IosSection(children: [
      IosRow(
        leading: IosIcon(CupertinoIcons.bluetooth, connColor),
        title: s.isConnected && s.nodeId.isNotEmpty ? s.nodeId : 'OUI-SPY node',
        subtitle: Text(connText),
        trailing: s.isConnected
            ? null
            : connecting || reconnecting
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    const CupertinoActivityIndicator(),
                    CupertinoButton(
                      padding: const EdgeInsets.only(left: 12),
                      onPressed: () => ble.disconnect(),
                      child: Text(reconnecting ? 'Stop' : 'Cancel', style: const TextStyle(color: AppTheme.error)),
                    ),
                  ])
                : CupertinoButton.filled(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(44, 36),
                    onPressed: () => context.push('/onboarding'),
                    child: const Text('Connect'),
                  ),
      ),
      IosRow(
        leading: IosIcon(CupertinoIcons.location_fill, gpsColor),
        title: 'Location',
        subtitle: Text(gpsText),
      ),
      if (s.isConnected)
        IosRow(
          leading: const IosIcon(CupertinoIcons.waveform_path_ecg, AppTheme.accent),
          title: '${s.totalDetections} unique detections',
          subtitle: Text('$active of ${Engine.values.length} engines on${s.totalRate > 0 ? ' · ${s.totalRate} per minute' : ''}'),
          chevron: true,
          onTap: () {
            ref.read(detectionsViewProvider.notifier).state = DetectionsView.live;
            context.go('/detections');
          },
        ),
      if (s.isConnected && s.isManagerConnected)
        IosRow(
          leading: IosIcon(CupertinoIcons.circle_grid_hex_fill, s.meshEnabled ? (meshNodes > 0 ? AppTheme.success : AppTheme.warning) : t.textDim),
          title: 'Mesh',
          subtitle: Text(s.meshEnabled ? '$meshNodes node${meshNodes == 1 ? '' : 's'} linked' : 'Off'),
          chevron: true,
          onTap: () {
            ref.read(configSectionRequestProvider.notifier).state = 'NODE';
            context.go('/config');
          },
        ),
    ]);
  }
}

class _SessionSection extends StatelessWidget {
  const _SessionSection();

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 6),
            child: Text('WARDRIVE SESSION', style: TextStyle(color: t.textDim, fontSize: 13, fontWeight: FontWeight.w500)),
          ),
          const SessionBar(),
        ],
      ),
    );
  }
}

class _RecentSection extends ConsumerWidget {
  const _RecentSection({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    return IosSection(
      header: 'Recent',
      children: [
        for (final d in state.recentDetections.take(5))
          IosRow(
            leading: Icon(d.engine.icon, color: d.engine.color, size: 22),
            title: d.deviceName.isNotEmpty ? d.deviceName : (d.ssid.isNotEmpty ? d.ssid : d.engine.label),
            subtitle: Text('${d.macAddress.toUpperCase()} · ${d.engine.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
            detail: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${d.rssi} dBm', style: TextStyle(color: rssiColor(d.rssi), fontSize: 15, fontWeight: FontWeight.w600)),
                Text(agoLabel(d.appTimestamp), style: TextStyle(color: t.textDim, fontSize: 13)),
              ],
            ),
            chevron: true,
            onTap: () {
              ref.read(detectionsViewProvider.notifier).state = DetectionsView.live;
              context.go('/detections');
            },
          ),
      ],
    );
  }
}

class _AccountsSection extends ConsumerWidget {
  const _AccountsSection();

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wigle = ref.watch(wigleProvider);
    final wdg = ref.watch(wdgwarsProvider);
    if (!wigle.isLoggedIn && !wdg.isLoggedIn) return const SizedBox.shrink();
    void open() {
      ref.read(configSectionRequestProvider.notifier).state = 'DATA';
      context.go('/config');
    }

    final ws = wigle.stats;
    final ds = wdg.stats;
    return IosSection(header: 'Wardrive accounts', children: [
      if (wigle.isLoggedIn)
        IosRow(
          leading: const IosIcon(CupertinoIcons.globe, AppTheme.wigle),
          title: 'WiGLE',
          subtitle: Text(wigle.rateLimited
              ? WigleApi.rateLimitMessage
              : ws == null
                  ? 'Loading…'
                  : 'Rank #${ws.rank} · ${_fmt(ws.discoveredWiFi)} Wi-Fi · ${_fmt(ws.discoveredBt)} Bluetooth'),
          chevron: true,
          onTap: open,
        ),
      if (wdg.isLoggedIn)
        IosRow(
          leading: const IosIcon(CupertinoIcons.game_controller_solid, AppTheme.wdgwars),
          title: 'WDGWars',
          subtitle: Text(ds == null ? 'Loading…' : '${_fmt(ds.total)} devices${ds.gang.isNotEmpty ? ' · ${ds.gang}' : ''}'),
          chevron: true,
          onTap: open,
        ),
    ]);
  }
}

class _SpoolImportBanner extends StatefulWidget {
  const _SpoolImportBanner({required this.stream});
  final Stream<SpoolImportProgress> stream;

  @override
  State<_SpoolImportBanner> createState() => _SpoolImportBannerState();
}

class _SpoolImportBannerState extends State<_SpoolImportBanner> {
  SpoolImportProgress? _p;
  StreamSubscription<SpoolImportProgress>? _sub;
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(_onEvent);
  }

  void _onEvent(SpoolImportProgress p) {
    if (!p.done && !p.aborted) return;
    if (p.done && !p.aborted && p.seen == 0) return;
    _hold?.cancel();
    _hold = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _p = null);
    });
    setState(() => _p = p);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) return const SizedBox.shrink();
    final breakdown = _spoolBreakdown(p.byEngine);
    return IosSection(children: [
      IosRow(
        leading: IosIcon(p.aborted ? CupertinoIcons.exclamationmark_circle_fill : CupertinoIcons.checkmark_circle_fill,
            p.aborted ? AppTheme.error : AppTheme.accent),
        title: p.aborted ? 'Import interrupted' : 'Imported ${p.seen} detections from while you were away',
        subtitle: Text(p.aborted
            ? 'It will retry on the next connection.'
            : [if (breakdown.isNotEmpty) breakdown, if (p.dropped > 0) 'buffer was full, oldest ${p.dropped} dropped'].join(' · ')),
        chevron: !p.aborted,
        onTap: () {
          ProviderScope.containerOf(context, listen: false).read(detectionsViewProvider.notifier).state = DetectionsView.live;
          context.go('/detections');
          _hold?.cancel();
          setState(() => _p = null);
        },
      ),
    ]);
  }
}

String _spoolBreakdown(Map<String, int> byEngine) {
  if (byEngine.isEmpty) return '';
  const label = {
    'flockBle': 'Flock',
    'flockWifi': 'Flock',
    'skySpy': 'drone',
    'detector': 'detector',
    'wardrive': 'wardrive',
    'foxhunter': 'foxhunt',
  };
  final tally = <String, int>{};
  byEngine.forEach((k, v) {
    final name = label[k] ?? k;
    tally[name] = (tally[name] ?? 0) + v;
  });
  final parts = tally.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return parts.map((e) => '${e.value} ${e.key}').join(' · ');
}
