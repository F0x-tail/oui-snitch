import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/classify/adv_decoder.dart';
import 'package:oui_spy/core/classify/device_explain.dart';
import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/classify/fleet_decode.dart';
import 'package:oui_spy/core/classify/observation.dart';
import 'package:oui_spy/core/classify/presence_class.dart';
import 'package:oui_spy/core/classify/signature_engine.dart';
import 'package:oui_spy/core/db/app_database.dart' show databaseProvider;
import 'package:oui_spy/core/export/devices_csv.dart';
import 'package:oui_spy/core/oui/oui_lookup_service.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/command_bar.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DeviceSort { recent, rssi, confidence }

Color confidenceColor(Confidence c) => switch (c) {
  Confidence.high => AppTheme.success,
  Confidence.medium => AppTheme.warning,
  Confidence.low => AppTheme.gpsNone,
};

Color classColor(SignatureClass k) => pillColor(k.index + 1);

Color rssiColor(int rssi) => rssi >= -60
    ? AppTheme.success
    : rssi >= -75
        ? AppTheme.warning
        : AppTheme.gpsNone;

String _ago(int ms) {
  final s = (DateTime.now().millisecondsSinceEpoch - ms) ~/ 1000;
  if (s < 60) return '${s < 0 ? 0 : s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}

const _flockSigs = {'fleet-flock-cameras', 'fleet-fs-ext-battery', 'fleet-penguin'};

class DeviceFacts {
  DeviceFacts(this.device, this.vendor);

  final ClassifiedDevice device;
  final String? vendor;

  Observation get o => device.obs;
  bool get ble => o.kind == RadioKind.ble;
  bool get flock => (vendor?.startsWith('Flock Safety') ?? false) || device.signatures.any((s) => _flockSigs.contains(s.id));
  SignatureClass? get kind => device.signatures.isEmpty ? null : device.signatures.first.kind;
  String get group => flock ? 'Flock' : (kind?.label ?? 'Unclassified');
  Color get color => kind == null ? AppTheme.gpsNone : classColor(kind!);
  String get title =>
      device.signatureNames.firstOrNull ??
      (o.name.isNotEmpty ? o.name : null) ??
      DeviceExplain.listLabel(o, vendor: vendor) ??
      'Unknown ${ble ? 'Bluetooth' : 'Wi-Fi'} device';
  String get address => o.mac.isNotEmpty ? o.mac : 'iOS ID ${o.key.substring(4)}';
  String get heardBy => (device.sources.toList()..sort()).map((s) => s == 'esp32' ? 'Node' : 'Phone').join(' + ');
}

int _groupRank(DeviceFacts f) => f.flock
    ? 0
    : switch (f.kind) {
        SignatureClass.lawEnforcement => 1,
        SignatureClass.surveillance => 2,
        SignatureClass.camera => 3,
        SignatureClass.drone => 4,
        SignatureClass.finder => 5,
        SignatureClass.glasses => 6,
        SignatureClass.hacking => 7,
        null => 99,
        _ => 50,
      };

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final _search = TextEditingController();
  String _query = '';
  SignatureClass? _class;
  bool _unclassifiedOnly = false;
  RadioKind? _radio;
  String? _source;
  DeviceSort _sort = DeviceSort.recent;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(DeviceFacts f) {
    final d = f.device;
    if (_radio != null && d.obs.kind != _radio) return false;
    if (_source != null && !d.sources.contains(_source)) return false;
    if (_unclassifiedOnly && d.signatures.isNotEmpty) return false;
    if (_class != null && !d.signatures.any((s) => s.kind == _class)) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [f.title, d.obs.name, d.obs.mac, f.vendor ?? '', ...d.signatureNames].any((s) => s.toLowerCase().contains(q));
  }

  bool get _filtered => _source != null || _class != null || _unclassifiedOnly;

  Future<bool> _ensurePhoneScan(BuildContext ctx) async {
    final src = ref.read(phoneBleSourceProvider);
    if (src.active) return true;
    final yes = await showCupertinoDialog<bool>(
      context: ctx,
      builder: (d) => CupertinoAlertDialog(
        title: const Text('Scan with this phone?'),
        content: const Text("This phone's Bluetooth also listens for nearby devices, alongside the connected node. Uses more battery."),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.of(d).pop(false), child: const Text('Not now')),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.of(d).pop(true), child: const Text('Scan')),
        ],
      ),
    );
    if (yes != true) return false;
    src.setActive(true);
    final p = await SharedPreferences.getInstance();
    await p.setBool(DeviceRegistry.phoneScanPref, true);
    return true;
  }

  Future<void> _openFilterSheet(Map<SignatureClass, int> counts, int unclassified) {
    return showCommandSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void apply(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
          }

          final t = AppTheme.of(ctx);
          return CommandSheet(
            title: 'Filter',
            trailing: !_filtered
                ? null
                : CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: () => apply(() {
                      _source = null;
                      _class = null;
                      _unclassifiedOnly = false;
                    }),
                    child: const Text('Reset'),
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CommandSheetGroup(
                  label: 'Heard by',
                  child: CommandOptionList(
                    children: [
                      for (final s in <String?>[null, 'esp32', 'phone'])
                        CommandOption(
                          label: switch (s) {
                            'esp32' => 'Node',
                            'phone' => 'This phone',
                            _ => 'All',
                          },
                          selected: _source == s,
                          color: switch (s) {
                            'esp32' => AppTheme.warning,
                            'phone' => AppTheme.skySpy,
                            _ => AppTheme.accent,
                          },
                          onTap: () async {
                            if (s == 'phone' && !await _ensurePhoneScan(ctx)) return;
                            apply(() => _source = s);
                          },
                        ),
                    ],
                  ),
                ),
                CommandSheetGroup(
                  label: 'Class',
                  child: CommandOptionList(
                    children: [
                      CommandOption(
                        label: 'All',
                        selected: _class == null && !_unclassifiedOnly,
                        color: AppTheme.accent,
                        onTap: () => apply(() {
                          _class = null;
                          _unclassifiedOnly = false;
                        }),
                      ),
                      for (final k in SignatureClass.values)
                        if ((counts[k] ?? 0) > 0)
                          CommandOption(
                            label: k.label,
                            count: counts[k],
                            selected: _class == k,
                            color: classColor(k),
                            onTap: () => apply(() {
                              _unclassifiedOnly = false;
                              _class = k;
                            }),
                          ),
                      if (unclassified > 0)
                        CommandOption(
                          label: 'Unclassified',
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

  Future<void> _exportCsv(List<ClassifiedDevice> items) async {
    final messenger = ScaffoldMessenger.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 100, 100);
    try {
      final oui = ref.read(ouiLookupProvider);
      final csv = DevicesCsv.generate(items, vendorOf: oui.lookup);
      final dir = await getTemporaryDirectory();
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/oui_spy_devices_$ts.csv');
      await file.writeAsString(csv);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: 'OUI-SPY Devices Export (${items.length} devices)',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _openMore(List<ClassifiedDevice> shown) {
    final phone = ref.read(phoneBleSourceProvider).active;
    String sortName(DeviceSort s) => switch (s) {
      DeviceSort.recent => 'Last heard',
      DeviceSort.rssi => 'Signal strength',
      DeviceSort.confidence => 'Confidence',
    };
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('${shown.length} devices shown · sorted by ${sortName(_sort).toLowerCase()}'),
        actions: [
          for (final s in DeviceSort.values)
            if (s != _sort)
              CupertinoActionSheetAction(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() => _sort = s);
                },
                child: Text('Sort by ${sortName(s).toLowerCase()}'),
              ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              if (shown.isNotEmpty) _exportCsv(shown);
            },
            child: const Text('Export CSV'),
          ),
          CupertinoActionSheetAction(
            onPressed: () async {
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
            child: Text(phone ? 'Stop scanning with this phone' : 'Also scan with this phone'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(deviceRegistryProvider).clear();
            },
            child: const Text('Clear list'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(deviceRegistryProvider);
    final oui = ref.read(ouiLookupProvider);
    final all = [
      for (final d in reg.devices) DeviceFacts(d, d.obs.mac.isEmpty ? null : oui.lookup(d.obs.mac)),
    ];
    final counts = <SignatureClass, int>{};
    var unclassified = 0;
    for (final f in all) {
      if (f.device.signatures.isEmpty) unclassified++;
      for (final k in {for (final s in f.device.signatures) s.kind}) {
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final bleCount = all.where((f) => f.ble).length;
    final shown = all.where(_matches).toList()
      ..sort(switch (_sort) {
        DeviceSort.recent => (a, b) => b.o.lastSeenMs.compareTo(a.o.lastSeenMs),
        DeviceSort.rssi => (a, b) => b.o.rssi.compareTo(a.o.rssi),
        DeviceSort.confidence => (a, b) => a.device.guess.confidence.index.compareTo(b.device.guess.confidence.index),
      });
    final groups = <String, List<DeviceFacts>>{};
    for (final f in shown) {
      groups.putIfAbsent(f.group, () => []).add(f);
    }
    final order = groups.keys.toList()..sort((a, b) => _groupRank(groups[a]!.first).compareTo(_groupRank(groups[b]!.first)));
    final flood = reg.pairingFlood.notice;

    return IosPage(
      title: 'Devices',
      actions: [
        IosNavButton(
          icon: _filtered ? CupertinoIcons.line_horizontal_3_decrease_circle_fill : CupertinoIcons.line_horizontal_3_decrease_circle,
          tooltip: 'Filter',
          onPressed: () => _openFilterSheet(counts, unclassified),
        ),
        IosNavButton(icon: CupertinoIcons.ellipsis_circle, tooltip: 'More', onPressed: () => _openMore([for (final f in shown) f.device])),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(children: [
              IosSearch(
                controller: _search,
                placeholder: 'Name, MAC, vendor',
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 10),
              IosSegments<int>(
                value: _radio == null ? 0 : (_radio == RadioKind.ble ? 1 : 2),
                segments: {0: 'All ${all.length}', 1: 'BLE $bleCount', 2: 'Wi-Fi ${all.length - bleCount}'},
                onChanged: (v) => setState(() => _radio = v == 0 ? null : (v == 1 ? RadioKind.ble : RadioKind.wifi)),
              ),
            ]),
          ),
        ),
        if (flood != null)
          SliverToBoxAdapter(
            child: IosSection(children: [
              IosRow(
                leading: const IosIcon(CupertinoIcons.exclamationmark_triangle_fill, AppTheme.error),
                title: 'Pairing flood',
                subtitle: Text(flood.families.isEmpty ? flood.line() : '${flood.line()} · ${flood.families.join(', ')}'),
                trailing: const Icon(CupertinoIcons.xmark_circle_fill, size: 20),
                onTap: reg.pairingFlood.dismiss,
              ),
            ]),
          ),
        if (shown.isEmpty)
          SliverToBoxAdapter(
            child: IosEmpty(
              icon: CupertinoIcons.dot_radiowaves_left_right,
              title: all.isEmpty ? 'No devices yet' : 'No matches',
              message: all.isEmpty
                  ? (reg.ready
                      ? 'Devices heard by the connected node or this phone appear here, grouped by what they are.'
                      : 'Loading the signature catalog.')
                  : 'Nothing matches the current search or filter.',
              action: all.isEmpty
                  ? CupertinoButton.filled(
                      onPressed: () => _ensurePhoneScan(context).then((_) {
                        if (mounted) setState(() {});
                      }),
                      child: const Text('Scan with this phone'),
                    )
                  : CupertinoButton(
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                        _radio = null;
                        _source = null;
                        _class = null;
                        _unclassifiedOnly = false;
                      }),
                      child: const Text('Clear search and filters'),
                    ),
            ),
          ),
        for (final g in order)
          SliverToBoxAdapter(
            child: IosSection(
              header: '$g · ${groups[g]!.length}',
              children: [for (final f in groups[g]!) _DeviceRow(facts: f)],
            ),
          ),
      ],
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.facts});

  final DeviceFacts facts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final f = facts;
    final o = f.o;
    final withYou = ref.read(deviceRegistryProvider).withYou(f.device);
    final live = [
      for (final s in f.device.signatures)
        if (s.decode case final d?) ...FleetDecode.decode(d, o).where((x) => x.live),
    ];
    final meta = [
      if (f.vendor != null && !f.title.toLowerCase().contains(f.vendor!.toLowerCase())) f.vendor!,
      if (o.name.isNotEmpty && o.name != f.title) o.name,
      if (f.heardBy.isNotEmpty) f.heardBy,
    ].join(' · ');
    final flags = [
      if (withYou) 'With you',
      for (final x in live) x.display,
      if (o.hiddenSsid) 'Hidden SSID',
    ];
    return IosRow(
      leading: Icon(f.ble ? CupertinoIcons.bluetooth : CupertinoIcons.wifi, color: f.color, size: 24),
      title: f.title,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(f.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textSecondary)),
          if (meta.isNotEmpty) Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (flags.isNotEmpty)
            Text(flags.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600)),
        ],
      ),
      detail: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${o.rssi} dBm', style: TextStyle(color: rssiColor(o.rssi), fontSize: 15, fontWeight: FontWeight.w600)),
          Text('${_ago(o.lastSeenMs)} ago', style: TextStyle(color: t.textDim, fontSize: 13)),
        ],
      ),
      chevron: true,
      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => DeviceDetailPage(facts: f))),
    );
  }
}

class DeviceDetailPage extends ConsumerWidget {
  const DeviceDetailPage({super.key, required this.facts});

  final DeviceFacts facts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final f = facts;
    final o = f.o;
    final g = f.device.guess;
    final connected = ref.read(appStateProvider).isConnected;
    final fields = [
      for (final m in o.mfgRecords) ...AdvPayloadDecoder.decodeManufacturer(m),
      for (final s in o.serviceData) ...AdvPayloadDecoder.decodeService(s),
    ];
    final decoded = [
      for (final s in f.device.signatures)
        if (s.decode case final d?) ...FleetDecode.decode(d, o),
    ];
    Widget kv(String k, String v, {bool code = false}) => IosRow(
          title: k,
          subtitle: SelectableText(v, style: TextStyle(color: t.textSecondary, fontSize: 15, height: 1.3, fontFamily: code ? 'monospace' : null)),
        );
    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: f.title,
        slivers: [
          SliverToBoxAdapter(
            child: IosSection(
              children: [
                IosRow(
                  leading: Icon(f.ble ? CupertinoIcons.bluetooth : CupertinoIcons.wifi, color: f.color, size: 26),
                  title: g.headline,
                  subtitle: Text(g.because),
                  detail: Text('${o.rssi} dBm', style: TextStyle(color: rssiColor(o.rssi), fontSize: 17, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: IosSection(children: [
              IosRow(
                leading: const IosIcon(CupertinoIcons.map_fill, AppTheme.gpsGood),
                title: 'Show on map',
                subtitle: Text(o.gpsTrail.isEmpty ? 'No GPS fix for this device yet' : '${o.gpsTrail.length} GPS fix${o.gpsTrail.length == 1 ? '' : 'es'}'),
                chevron: o.gpsTrail.isNotEmpty,
                disabled: o.gpsTrail.isEmpty,
                onTap: o.gpsTrail.isEmpty
                    ? null
                    : () {
                        final fix = o.gpsTrail.last;
                        ref.read(wardriveProvider).requestZoom(fix.lat, fix.lon);
                        Navigator.of(context).pop();
                        context.go('/wardrive');
                      },
              ),
              if (o.mac.isNotEmpty)
                IosRow(
                  leading: const IosIcon(CupertinoIcons.scope, AppTheme.foxhunter),
                  title: 'Foxhunt',
                  subtitle: Text(connected ? 'Track this device by signal strength' : 'Connect a node first'),
                  chevron: connected,
                  disabled: !connected,
                  onTap: connected
                      ? () {
                          ref.read(appStateProvider).setFoxhunterTarget(o.mac, channel: o.channel);
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Foxhunting ${o.mac}')));
                        }
                      : null,
                ),
            ]),
          ),
          SliverToBoxAdapter(
            child: IosSection(header: 'Identity', children: [
              kv(o.mac.isNotEmpty ? 'Address' : 'iOS ID', o.mac.isNotEmpty ? o.mac : o.key.substring(4), code: true),
              kv('Address type', DeviceExplain.addressExplain(o)),
              if (f.vendor != null) kv('Vendor', f.vendor!),
              if (o.name.isNotEmpty) kv('Name', o.name),
              kv('Radio', f.ble ? 'Bluetooth LE' : 'Wi-Fi${o.channel > 0 ? ' · channel ${o.channel}' : ''}'),
              if (o.authMode != null) kv('Security', wifiAuthMeta(o.authMode!).$1),
            ]),
          ),
          SliverToBoxAdapter(
            child: IosSection(header: 'Signal and time', children: [
              kv('Signal', '${DeviceExplain.rssiExplain(o.rssi)} · range ${o.rssiMin} to ${o.rssiMax} dBm'),
              kv('Last heard', '${_ago(o.lastSeenMs)} ago'),
              kv('First heard', '${_ago(o.firstSeenMs)} ago'),
              kv('Heard by', f.heardBy),
              if (o.mac.isNotEmpty && !o.randomized)
                FutureBuilder<List<int>>(
                  future: ref.read(databaseProvider).sightingTimesForMac(o.mac),
                  builder: (context, snap) {
                    final ts = snap.data;
                    if (ts == null) return kv('Presence', 'Loading…');
                    final now = DateTime.now().millisecondsSinceEpoch;
                    const p = PresenceParams();
                    final s = PresenceStats.fromSightings(ts, now, p);
                    if (s == null) return kv('Presence', 'Not in saved history yet');
                    return kv('Presence',
                        '${classifyPresence(s, now, p).label} · ${s.visitsInWindow} visit${s.visitsInWindow == 1 ? '' : 's'} in 7 days · ${ts.length} sightings saved');
                  },
                ),
            ]),
          ),
          if (f.device.signatures.isNotEmpty)
            SliverToBoxAdapter(
              child: IosSection(header: 'Matched signatures', children: [
                for (final s in f.device.signatures)
                  IosRow(
                    leading: Icon(CupertinoIcons.checkmark_seal_fill, color: classColor(s.kind)),
                    title: s.name,
                    subtitle: Text([s.kind.label, if (s.attentionNote.isNotEmpty) s.attentionNote].join('\n')),
                  ),
              ]),
            ),
          if (decoded.isNotEmpty)
            SliverToBoxAdapter(
              child: IosSection(header: 'Decoded', children: [
                for (final d in decoded) kv(d.label, d.note.isEmpty ? d.display : '${d.display}\n${d.note}'),
              ]),
            ),
          if (fields.isNotEmpty)
            SliverToBoxAdapter(
              child: IosSection(header: 'Advertisement', children: [for (final x in fields) kv(x.label, x.value)]),
            ),
          if (o.serviceUuids.isNotEmpty)
            SliverToBoxAdapter(
              child: IosSection(header: 'Services', children: [
                for (final u in o.serviceUuids) kv(u, DeviceExplain.uuidGloss(u) ?? 'Unknown service'),
              ]),
            ),
        ],
      ),
    );
  }
}
