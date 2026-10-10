import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/core/classify/adv_decoder.dart';
import 'package:oui_spy/core/classify/device_explain.dart';
import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/classify/flood.dart';
import 'package:oui_spy/core/classify/fleet_decode.dart';
import 'package:oui_spy/core/classify/observation.dart';
import 'package:oui_spy/core/classify/presence_class.dart';
import 'package:oui_spy/core/db/app_database.dart' show databaseProvider;
import 'package:oui_spy/core/classify/signature_engine.dart';
import 'package:oui_spy/core/oui/oui_lookup_service.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/command_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DeviceSort { recent, rssi, confidence }

Color confidenceColor(Confidence c) => switch (c) {
  Confidence.high => AppTheme.success,
  Confidence.medium => AppTheme.warning,
  Confidence.low => AppTheme.gpsNone,
};

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  SignatureClass? _class;
  bool _unclassifiedOnly = false;
  RadioKind? _radio;
  String? _source;
  DeviceSort _sort = DeviceSort.recent;
  bool _sortAscending = false;

  bool _matches(ClassifiedDevice d) {
    if (_radio != null && d.obs.kind != _radio) return false;
    if (_source != null && !d.sources.contains(_source)) return false;
    if (_unclassifiedOnly) return d.signatures.isEmpty;
    if (_class != null) return d.signatures.any((s) => s.kind == _class);
    return true;
  }

  int get _filterCount =>
      (_radio != null ? 1 : 0) +
      (_source != null ? 1 : 0) +
      (_class != null || _unclassifiedOnly ? 1 : 0);

  static String _sourceLabel(String? s) => switch (s) {
    'esp32' => 'NODE',
    'phone' => 'PHONE',
    _ => 'ALL',
  };

  Future<bool> _ensurePhoneScan(BuildContext ctx) async {
    final src = ref.read(phoneBleSourceProvider);
    if (src.active) return true;
    final yes = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: const Text('Scan with this phone?'),
        content: const Text(
          "Use this phone's Bluetooth to listen for nearby devices too, in addition to the connected node. "
          'This uses more battery.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('NOT NOW'),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('SCAN'),
          ),
        ],
      ),
    );
    if (yes != true) return false;
    src.setActive(true);
    final p = await SharedPreferences.getInstance();
    await p.setBool(DeviceRegistry.phoneScanPref, true);
    return true;
  }

  Future<void> _openFilterSheet(
    Map<SignatureClass, int> counts,
    int unclassified,
  ) {
    return showCommandSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void apply(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
          }

          final t = AppTheme.of(ctx);
          final gap = barGap(ctx);
          return CommandSheet(
            title: 'FILTER',
            trailing: _filterCount == 0
                ? null
                : TextButton(
                    onPressed: () => apply(() {
                      _radio = null;
                      _source = null;
                      _class = null;
                      _unclassifiedOnly = false;
                    }),
                    child: Text(
                      'RESET',
                      style: barLabelStyle(ctx, AppTheme.accent),
                    ),
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CommandSheetGroup(
                  label: 'HEARD BY',
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final s in <String?>[null, 'esp32', 'phone'])
                        CommandChip(
                          label: _sourceLabel(s),
                          selected: _source == s,
                          color: switch (s) {
                            'esp32' => AppTheme.warning,
                            'phone' => AppTheme.skySpy,
                            _ => kPillAll,
                          },
                          onTap: () async {
                            if (s == 'phone' && !await _ensurePhoneScan(ctx)) {
                              return;
                            }
                            apply(() => _source = s);
                          },
                        ),
                    ],
                  ),
                ),
                CommandSheetGroup(
                  label: 'RADIO',
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final r in <RadioKind?>[
                        null,
                        RadioKind.ble,
                        RadioKind.wifi,
                      ])
                        CommandChip(
                          label: r == null
                              ? 'ALL'
                              : (r == RadioKind.ble ? 'BLE' : 'WIFI'),
                          selected: _radio == r,
                          color: r == null
                              ? kPillAll
                              : (r == RadioKind.ble ? kPillBle : kPillWifi),
                          onTap: () => apply(() => _radio = r),
                        ),
                    ],
                  ),
                ),
                CommandSheetGroup(
                  label: 'CLASS',
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      CommandChip(
                        label: 'ALL',
                        selected: _class == null && !_unclassifiedOnly,
                        color: AppTheme.accent,
                        onTap: () => apply(() {
                          _class = null;
                          _unclassifiedOnly = false;
                        }),
                      ),
                      for (final k in SignatureClass.values)
                        if ((counts[k] ?? 0) > 0)
                          CommandChip(
                            label: k.label.toUpperCase(),
                            count: counts[k],
                            selected: _class == k,
                            color: pillColor(k.index + 1),
                            onTap: () => apply(() {
                              _unclassifiedOnly = false;
                              _class = k;
                            }),
                          ),
                      if (unclassified > 0)
                        CommandChip(
                          label: 'UNCLASSIFIED',
                          count: unclassified,
                          selected: _unclassifiedOnly,
                          color: t.textDim,
                          onTap: () => apply(() {
                            _class = null;
                            _unclassifiedOnly = true;
                          }),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _sortLabel(DeviceSort s) => switch (s) {
    DeviceSort.recent => 'TIME',
    DeviceSort.rssi => 'RSSI',
    DeviceSort.confidence => 'CONF',
  };

  Future<void> _openSortSheet() => showSortSheet<DeviceSort>(
        context: context,
        options: DeviceSort.values,
        label: _sortLabel,
        current: () => _sort,
        ascending: () => _sortAscending,
        onPick: (s) => setState(() {
          if (_sort == s) {
            _sortAscending = !_sortAscending;
          } else {
            _sort = s;
            _sortAscending = false;
          }
        }),
        onToggleDirection: () => setState(() => _sortAscending = !_sortAscending),
      );

  Future<void> _openActionSheet() {
    return showCommandSheet<void>(
      context: context,
      builder: (ctx) => CommandSheet(
        title: 'ACTIONS',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CommandSheetTile(
              icon: Icons.phone_iphone,
              label: ref.read(phoneBleSourceProvider).active
                  ? 'STOP SCANNING WITH PHONE'
                  : 'SCAN WITH THIS PHONE',
              subtitle: ref.read(phoneBleSourceProvider).active
                  ? "This phone's Bluetooth is listening too"
                  : "Also listen with this phone's Bluetooth",
              color: ref.read(phoneBleSourceProvider).active
                  ? AppTheme.accent
                  : null,
              onTap: () async {
                Navigator.pop(ctx);
                final src = ref.read(phoneBleSourceProvider);
                if (src.active) {
                  src.setActive(false);
                  final p = await SharedPreferences.getInstance();
                  await p.setBool(DeviceRegistry.phoneScanPref, false);
                  if (_source == 'phone') _source = null;
                } else {
                  await _ensurePhoneScan(context);
                }
                if (mounted) setState(() {});
              },
            ),
            CommandSheetTile(
              icon: Icons.delete_sweep,
              label: 'CLEAR LIST',
              subtitle: 'Forget every device on this tab',
              color: AppTheme.error,
              onTap: () {
                Navigator.pop(ctx);
                ref.read(deviceRegistryProvider).clear();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(deviceRegistryProvider);
    final t = AppTheme.of(context);
    final all = reg.devices.toList();
    final counts = <SignatureClass, int>{};
    var unclassified = 0;
    for (final d in all) {
      if (d.signatures.isEmpty) unclassified++;
      for (final k in {for (final s in d.signatures) s.kind}) {
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final shown = all.where(_matches).toList();
    final guesses = {for (final d in shown) d.obs.key: d.guess};
    shown.sort(switch (_sort) {
      DeviceSort.recent => (a, b) => b.obs.lastSeenMs.compareTo(
        a.obs.lastSeenMs,
      ),
      DeviceSort.rssi => (a, b) => b.obs.rssi.compareTo(a.obs.rssi),
      DeviceSort.confidence =>
        (a, b) => guesses[a.obs.key]!.confidence.index.compareTo(
          guesses[b.obs.key]!.confidence.index,
        ),
    });
    final ordered = _sortAscending ? shown.reversed.toList() : shown;
    final flood = reg.pairingFlood.notice;
    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            CommandHeader(
              title: 'DEVICES',
              count: _filterCount > 0 ? '${shown.length}/${all.length}' : '${all.length}',
              chips: [
                          if (_radio != null)
                            CommandActiveChip(
                              label: _radio == RadioKind.ble ? 'BLE' : 'WIFI',
                              color: AppTheme.accent,
                              onClear: () => setState(() => _radio = null),
                            ),
                          if (_source != null)
                            CommandActiveChip(
                              label: _sourceLabel(_source),
                              color: AppTheme.accent,
                              onClear: () => setState(() => _source = null),
                            ),
                          if (_class != null || _unclassifiedOnly)
                            CommandActiveChip(
                              label: _unclassifiedOnly
                                  ? 'UNCLASSIFIED'
                                  : _class!.label.toUpperCase(),
                              color: AppTheme.accent,
                              onClear: () => setState(() {
                                _class = null;
                                _unclassifiedOnly = false;
                              }),
                            ),
              ],
            ),
            if (flood != null)
              _FloodBanner(notice: flood, onDismiss: reg.pairingFlood.dismiss),
            const Divider(height: 1),
            Expanded(
              child: shown.isEmpty
                  ? CommandEmptyState(
                      icon: Icons.devices_other,
                      title: 'NO DEVICES',
                      message: reg.ready
                          ? 'Devices heard by the connected node or this phone appear here, grouped by signature class.'
                          : 'Loading signature catalog.',
                    )
                  : ListView.builder(
                      itemCount: ordered.length,
                      itemBuilder: (context, i) => _DeviceRow(
                        device: ordered[i],
                        guess: guesses[ordered[i].obs.key]!,
                      ),
                    ),
            ),
            CommandBar(
              actions: [
                CommandBarAction(
                  icon: Icons.filter_alt,
                  label: 'FILTER',
                  active: _filterCount > 0,
                  onTap: () => _openFilterSheet(counts, unclassified),
                ),
                CommandBarAction(
                  icon: _sortAscending
                      ? Icons.arrow_upward
                      : Icons.arrow_downward,
                  label: _sortLabel(_sort),
                  active: true,
                  onTap: _openSortSheet,
                ),
                CommandBarAction(
                  icon: Icons.more_horiz,
                  label: 'MORE',
                  onTap: _openActionSheet,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FloodBanner extends StatelessWidget {
  const _FloodBanner({required this.notice, required this.onDismiss});

  final FloodNotice notice;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final gap = barGap(context);
    return Material(
      color: AppTheme.error.withValues(alpha: 0.14),
      child: InkWell(
        onTap: onDismiss,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: gap * 2, vertical: gap),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber,
                size: barIconSize(context),
                color: AppTheme.error,
              ),
              SizedBox(width: gap),
              Expanded(
                child: Text(
                  notice.families.isEmpty
                      ? notice.line()
                      : '${notice.line()} · ${notice.families.join(', ')}',
                  style: barLabelStyle(context, AppTheme.error),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.device, required this.guess});

  final ClassifiedDevice device;
  final Guess guess;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    final o = device.obs;
    final vendor = o.mac.isEmpty
        ? null
        : ref.read(ouiLookupProvider).lookup(o.mac);
    final title =
        DeviceExplain.listLabel(
          o,
          signatureNames: device.signatureNames,
          vendor: vendor,
        ) ??
        (o.name.isNotEmpty ? o.name : (o.mac.isNotEmpty ? o.mac : o.key));
    final withYou = ref.read(deviceRegistryProvider).withYou(device);
    final live = [
      for (final s in device.signatures)
        if (s.decode case final d?) ...FleetDecode.decode(d, o).where((f) => f.live),
    ];
    final alert = live.any((f) => f.emphasis);
    final sub = [
      for (final f in live) f.display.toUpperCase(),
      if (o.name.isNotEmpty && o.name != title) o.name,
      if (device.signatures.isNotEmpty) device.signatureNames.join(', '),
      o.kind == RadioKind.ble ? 'BLE' : 'WIFI ch${o.channel}',
    ].join(' · ');
    return InkWell(
      onTap: () => showCommandSheet<void>(
        context: context,
        builder: (_) => DeviceDetailSheet(device: device, vendor: vendor),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gap * 2, vertical: gap),
        child: Row(
          children: [
            Container(
              width: gap * 0.6,
              height: kMinInteractiveDimension * 0.7,
              decoration: BoxDecoration(
                color: confidenceColor(guess.confidence),
                borderRadius: BorderRadius.circular(gap),
              ),
            ),
            SizedBox(width: gap * 1.5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: t.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: alert ? AppTheme.error : t.textDim),
                  ),
                ],
              ),
            ),
            if (withYou) ...[
              Icon(
                Icons.directions_walk,
                size: barIconSize(context),
                color: AppTheme.error,
              ),
              SizedBox(width: gap),
            ],
            Text(
              '${o.rssi}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: t.textSecondary,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DeviceDetailSheet extends ConsumerWidget {
  const DeviceDetailSheet({super.key, required this.device, this.vendor});

  final ClassifiedDevice device;
  final String? vendor;

  void _foxhunt(BuildContext context, WidgetRef ref) {
    final o = device.obs;
    final method = o.kind == RadioKind.ble ? 'ble_adv' : 'wifi_ap';
    Navigator.of(context).maybePop();
    if (OuiLookupService.isFoxhuntBlocked(o.mac, method)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Foxhunt blocked — law enforcement device'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }
    ref.read(appStateProvider).setFoxhunterTarget(o.mac, channel: o.channel);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Foxhunting ${o.mac.substring(0, 8)}...'),
        backgroundColor: AppTheme.foxhunter,
      ),
    );
  }

  void _showOnMap(BuildContext context, WidgetRef ref) {
    final fix = device.obs.gpsTrail.last;
    Navigator.of(context).maybePop();
    ref.read(wardriveProvider).requestZoom(fix.lat, fix.lon);
    context.go('/wardrive');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    final o = device.obs;
    final g = device.guess;
    final connected = ref.read(appStateProvider).isConnected;
    final canFoxhunt =
        o.mac.isNotEmpty &&
        !OuiLookupService.isFoxhuntBlocked(
          o.mac,
          o.kind == RadioKind.ble ? 'ble_adv' : 'wifi_ap',
        );
    final body = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: t.textSecondary);
    final fields = [
      for (final m in o.mfgRecords) ...AdvPayloadDecoder.decodeManufacturer(m),
      for (final s in o.serviceData) ...AdvPayloadDecoder.decodeService(s),
    ];
    final decoded = [
      for (final s in device.signatures)
        if (s.decode case final d?) ...FleetDecode.decode(d, o),
    ];
    Widget kv(String k, String v) => Padding(
      padding: EdgeInsets.only(bottom: gap * 0.75),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: MediaQuery.sizeOf(context).width * 0.32,
            child: Text(
              k,
              style: barLabelStyle(context, t.textDim, bold: false),
            ),
          ),
          Expanded(child: SelectableText(v, style: body)),
        ],
      ),
    );
    return CommandSheet(
      title: 'DEVICE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            g.headline,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: confidenceColor(g.confidence),
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: gap * 0.5),
          Text(g.because, style: body),
          SizedBox(height: gap),
          CommandSheetTile(
            icon: Icons.map,
            label: 'SHOW ON MAP',
            subtitle: o.gpsTrail.isEmpty
                ? 'No GPS fix for this device yet'
                : null,
            color: AppTheme.gpsGood,
            onTap: o.gpsTrail.isEmpty ? null : () => _showOnMap(context, ref),
          ),
          if (canFoxhunt)
            CommandSheetTile(
              icon: Icons.gps_fixed,
              label: 'FOXHUNT',
              subtitle: connected ? null : 'Node disconnected',
              color: AppTheme.foxhunter,
              onTap: connected ? () => _foxhunt(context, ref) : null,
            ),
          SizedBox(height: gap),
          CommandSheetGroup(
            label: 'IDENTITY',
            child: Column(
              children: [
                if (o.mac.isNotEmpty) kv('Address', o.mac),
                if (o.mac.isEmpty) kv('Phone ID', o.key.substring(4)),
                if (vendor != null) kv('Vendor', vendor!),
                if (o.name.isNotEmpty) kv('Name', o.name),
                kv('Address type', DeviceExplain.addressExplain(o)),
                kv(
                  'Signal',
                  '${DeviceExplain.rssiExplain(o.rssi)} (${o.rssiMin} to ${o.rssiMax})',
                ),
                kv('Heard by', device.sources.join(', ')),
                if (o.mac.isNotEmpty && !o.randomized)
                  FutureBuilder<List<int>>(
                    future: ref
                        .read(databaseProvider)
                        .sightingTimesForMac(o.mac),
                    builder: (context, snap) {
                      final ts = snap.data;
                      if (ts == null) return const SizedBox.shrink();
                      final now = DateTime.now().millisecondsSinceEpoch;
                      const p = PresenceParams();
                      final s = PresenceStats.fromSightings(ts, now, p);
                      if (s == null) {
                        return kv('Presence', 'Not in saved history yet');
                      }
                      return kv(
                        'Presence',
                        '${classifyPresence(s, now, p).label} · ${s.visitsInWindow} visit'
                            '${s.visitsInWindow == 1 ? '' : 's'} in 7 days · ${ts.length} sightings saved',
                      );
                    },
                  ),
              ],
            ),
          ),
          if (device.signatures.isNotEmpty)
            CommandSheetGroup(
              label: 'SIGNATURES',
              child: Column(
                children: [
                  for (final s in device.signatures)
                    kv(
                      s.kind.label,
                      [
                        s.name,
                        if (s.attentionNote.isNotEmpty) s.attentionNote,
                      ].join('\n'),
                    ),
                ],
              ),
            ),
          if (decoded.isNotEmpty)
            CommandSheetGroup(
              label: 'DECODED',
              child: Column(
                children: [
                  for (final f in decoded) kv(f.label, f.note.isEmpty ? f.display : '${f.display}\n${f.note}'),
                ],
              ),
            ),
          if (fields.isNotEmpty)
            CommandSheetGroup(
              label: 'ADVERTISEMENT',
              child: Column(
                children: [for (final f in fields) kv(f.label, f.value)],
              ),
            ),
          if (o.serviceUuids.isNotEmpty)
            CommandSheetGroup(
              label: 'SERVICES',
              child: Column(
                children: [
                  for (final u in o.serviceUuids)
                    kv(u, DeviceExplain.uuidGloss(u) ?? ''),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
