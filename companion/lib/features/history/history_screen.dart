import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:oui_spy/core/db/app_database.dart' hide Detection;
import 'package:oui_spy/core/db/detection_mapper.dart';
import 'package:oui_spy/core/export/detections_csv.dart';
import 'package:oui_spy/core/export/wigle_csv_import.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/radio_classifier.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/core/watchlist_state.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/feed/detection_row.dart';
import 'package:oui_spy/features/feed/feed_screen.dart' show LiveHistorySwitch;
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/command_bar.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:oui_spy/widgets/map_tiles.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum _Sort {
  time('Time'),
  rssi('Signal'),
  mac('MAC address');

  const _Sort(this.label);
  final String label;
}

enum _Radio { all, ble, wifi }

int _radioRank(Map<String, dynamic> d) {
  final method = (d['detectionMethod'] as String?) ?? '';
  if (isBleMethod(method)) return 0;
  if (isWifiMethod(method)) return 1;
  final engine = (d['engine'] as String?) ?? '';
  if (engine == 'flockBle' || engine == 'detector') return 0;
  if (engine == 'flockWifi') return 1;
  final ch = (d['channel'] as int?) ?? 0;
  return (ch >= 1 && ch <= 14) ? 1 : 0;
}

FlockConfidence? _flockConfidence(Map<String, dynamic> d) {
  final e = d['engine'] as String?;
  if (e != 'flockBle' && e != 'flockWifi') return null;
  return FlockExtension(signals: d['flockSignals'] as int? ?? 0).confidence(d['detectionMethod'] as String? ?? '');
}

Color _engineColor(String engine) => switch (engine) {
  'flockBle' => AppTheme.flockBle,
  'flockWifi' => AppTheme.flockWifi,
  'detector' => AppTheme.detector,
  'skySpy' => AppTheme.skySpy,
  _ => AppTheme.accent,
};

class DetectionHistoryView extends ConsumerStatefulWidget {
  const DetectionHistoryView({super.key, this.onShowLive});

  final VoidCallback? onShowLive;

  @override
  ConsumerState<DetectionHistoryView> createState() => _DetectionHistoryViewState();
}

class _DetectionHistoryViewState extends ConsumerState<DetectionHistoryView> {
  List<Map<String, dynamic>> _detections = [];
  bool _loading = true;
  bool _rescanning = false;
  _Sort _sort = _Sort.time;
  bool _ascending = false;
  String? _engineFilter;
  bool _noGpsOnly = false;
  _Radio _radio = _Radio.all;
  String? _methodFilter;
  FlockConfidence? _confFilter;
  bool _showMap = false;
  final _searchCtrl = TextEditingController();
  String _search = '';
  final _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _engineFilter = ref.read(historyFilterRequestProvider) ?? _engineFilter;
    if (ref.read(historyFilterRequestProvider) != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(historyFilterRequestProvider.notifier).state = null);
    }
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await ref.read(databaseProvider).getFlockDetectorDetections();
    if (mounted) {
      setState(() {
        _detections = rows;
        _loading = false;
      });
    }
  }

  Future<void> _rescan() async {
    final db = ref.read(databaseProvider);
    final watchlist = List<WatchlistEntry>.from(ref.read(watchlistProvider).entries);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _rescanning = true);
    try {
      final res = await WigleCsvRescan.rescanAll(db, watchlist: watchlist);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Rescanned ${res.sessionsScanned} sessions and ${res.rowsScanned} rows · ${res.rowsUpdated} reclassified '
            '(${res.newDetectorMacs} detector, ${res.newFlockMacs} Flock)'),
      ));
      await _load();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Rescan failed: $e')));
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }

  Future<void> _clearAll() async {
    final db = ref.read(databaseProvider);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete all saved detections?'),
        content: Text('Permanently deletes ${_detections.length} detections from the database. This cannot be undone.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (ok != true) return;
    final n = await db.clearFlockDetectorDetections();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('Deleted $n detections')));
    await _load();
  }

  List<Map<String, dynamic>> get _filtered {
    var list = _detections;
    if (_engineFilter == 'flock') {
      list = list.where((d) => d['engine'] == 'flockBle' || d['engine'] == 'flockWifi').toList();
    } else if (_engineFilter == 'detector') {
      list = list.where((d) => d['engine'] == 'detector').toList();
    } else if (_engineFilter == 'drone') {
      list = list.where((d) => d['engine'] == 'skySpy').toList();
    }
    if (_noGpsOnly) list = list.where((d) => d['latitude'] == null || d['longitude'] == null).toList();
    if (_radio != _Radio.all) {
      final want = _radio == _Radio.ble ? 0 : 1;
      list = list.where((d) => _radioRank(d) == want).toList();
    }
    if (_methodFilter != null) list = list.where((d) => d['detectionMethod'] == _methodFilter).toList();
    if (_confFilter != null) list = list.where((d) => _flockConfidence(d) == _confFilter).toList();
    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((d) {
        bool has(String k) => ((d[k] as String?) ?? '').toLowerCase().contains(q);
        return has('macAddress') || has('deviceName') || has('ssid') || has('detectionMethod') || has('engine');
      }).toList();
    }
    final cmp = switch (_sort) {
      _Sort.time => (Map<String, dynamic> a, Map<String, dynamic> b) => (a['appTimestamp'] as int).compareTo(b['appTimestamp'] as int),
      _Sort.rssi => (Map<String, dynamic> a, Map<String, dynamic> b) => (a['rssi'] as int).compareTo(b['rssi'] as int),
      _Sort.mac => (Map<String, dynamic> a, Map<String, dynamic> b) => (a['macAddress'] as String).compareTo(b['macAddress'] as String),
    };
    return List.of(list)..sort((a, b) => _ascending ? cmp(a, b) : cmp(b, a));
  }

  int get _activeFilterCount =>
      (_engineFilter != null ? 1 : 0) + (_noGpsOnly ? 1 : 0) + (_radio != _Radio.all ? 1 : 0) + (_methodFilter != null ? 1 : 0) + (_confFilter != null ? 1 : 0);

  void _clearFilters() => setState(() {
        _engineFilter = null;
        _noGpsOnly = false;
        _radio = _Radio.all;
        _methodFilter = null;
        _confFilter = null;
      });

  int _engineCount(String? key) => switch (key) {
        'flock' => _detections.where((d) => d['engine'] == 'flockBle' || d['engine'] == 'flockWifi').length,
        'detector' => _detections.where((d) => d['engine'] == 'detector').length,
        'drone' => _detections.where((d) => d['engine'] == 'skySpy').length,
        _ => _detections.length,
      };

  String get _sortDirection => switch ((_sort, _ascending)) {
        (_Sort.time, true) => 'oldest first',
        (_Sort.time, false) => 'newest first',
        (_Sort.rssi, true) => 'weakest first',
        (_Sort.rssi, false) => 'strongest first',
        (_Sort.mac, true) => 'A to Z',
        (_Sort.mac, false) => 'Z to A',
      };

  Future<void> _exportCsv(List<Map<String, dynamic>> items) async {
    final messenger = ScaffoldMessenger.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 100, 100);
    try {
      final csv = DetectionsCsv.generate(items.map(detectionFromDbRow));
      final dir = await getTemporaryDirectory();
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/oui_spy_detections_$ts.csv');
      await file.writeAsString(csv);
      await Share.shareXFiles([XFile(file.path)], subject: 'OUI-SPY Detections Export (${items.length} detections)', sharePositionOrigin: origin);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  void _showOnMap(Map<String, dynamic> det) {
    final lat = det['latitude'] as double?;
    final lon = det['longitude'] as double?;
    final wd = ref.read(wardriveProvider);
    if (wd.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stop the active wardrive first')));
      return;
    }
    wd.loadSession(det['sessionId'] as String).then((_) {
      if (lat != null && lon != null) wd.requestZoom(lat, lon, detection: detectionFromDbRow(det));
      if (mounted) context.go('/wardrive');
    });
  }

  void _open(Map<String, dynamic> row) {
    showDetectionDetails(
      context,
      ref,
      detectionFromDbRow(row),
      onShowMap: () => _showOnMap(row),
      onDelete: () {
        final messenger = ScaffoldMessenger.of(context);
        ref.read(databaseProvider).deleteDetectionById(row['id'] as int).then((_) {
          _load();
          messenger.showSnackBar(const SnackBar(content: Text('Detection deleted'), duration: Duration(seconds: 1)));
        });
      },
    );
  }

  Future<void> _openFilterSheet() {
    final methods = _detections.map((d) => (d['detectionMethod'] as String?) ?? '').where((m) => m.isNotEmpty).toSet().toList()
      ..sort((a, b) => methodLabel(a).compareTo(methodLabel(b)));
    final noGps = _detections.where((d) => d['latitude'] == null || d['longitude'] == null).length;
    return showCommandSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void apply(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
          }

          return CommandSheet(
            title: 'Filter',
            trailing: _activeFilterCount == 0
                ? null
                : CupertinoButton(padding: const EdgeInsets.symmetric(horizontal: 8), onPressed: () => apply(_clearFilters), child: const Text('Reset')),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CommandSheetGroup(
                label: 'Engine',
                child: CommandOptionList(children: [
                  for (final (key, label, color) in <(String?, String, Color)>[
                    (null, 'All', AppTheme.accent),
                    ('flock', 'Flock cameras', AppTheme.flockBle),
                    ('detector', 'Detector', AppTheme.detector),
                    ('drone', 'Drones', AppTheme.skySpy),
                  ])
                    CommandOption(label: label, count: _engineCount(key), selected: _engineFilter == key, color: color, onTap: () => apply(() => _engineFilter = key)),
                ]),
              ),
              CommandSheetGroup(
                label: 'Radio',
                child: CommandOptionList(children: [
                  for (final (r, label, color) in const [(_Radio.all, 'All', kPillAll), (_Radio.ble, 'Bluetooth', kPillBle), (_Radio.wifi, 'Wi-Fi', kPillWifi)])
                    CommandOption(label: label, selected: _radio == r, color: color, onTap: () => apply(() => _radio = r)),
                ]),
              ),
              CommandSheetGroup(
                label: 'Flock confidence',
                child: CommandOptionList(children: [
                  CommandOption(label: 'All', selected: _confFilter == null, color: AppTheme.accent, onTap: () => apply(() => _confFilter = null)),
                  for (final c in FlockConfidence.values)
                    CommandOption(
                      label: switch (c) {
                        FlockConfidence.verified => 'Verified',
                        FlockConfidence.high => 'High',
                        FlockConfidence.suspected => 'Suspected',
                      },
                      count: _detections.where((d) => _flockConfidence(d) == c).length,
                      selected: _confFilter == c,
                      color: c == FlockConfidence.suspected ? AppTheme.warning : AppTheme.success,
                      onTap: () => apply(() => _confFilter = c),
                    ),
                ]),
              ),
              CommandSheetGroup(
                label: 'Location',
                child: CommandOptionList(children: [
                  CommandOption(label: 'Any', selected: !_noGpsOnly, color: AppTheme.accent, onTap: () => apply(() => _noGpsOnly = false)),
                  CommandOption(label: 'Missing GPS only', count: noGps, selected: _noGpsOnly, color: AppTheme.gpsNone, onTap: () => apply(() => _noGpsOnly = true)),
                ]),
              ),
              if (methods.isNotEmpty)
                CommandSheetGroup(
                  label: 'Matched by',
                  child: CommandOptionList(children: [
                    CommandOption(label: 'Any method', selected: _methodFilter == null, color: AppTheme.accent, onTap: () => apply(() => _methodFilter = null)),
                    for (final m in methods)
                      CommandOption(
                        label: methodLabel(m),
                        count: _detections.where((d) => d['detectionMethod'] == m).length,
                        selected: _methodFilter == m,
                        color: AppTheme.accent,
                        onTap: () => apply(() => _methodFilter = m),
                      ),
                  ]),
                ),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _openMore(List<Map<String, dynamic>> items) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('${items.length} shown · sorted by ${_sort.label.toLowerCase()}, $_sortDirection'),
        actions: [
          for (final s in _Sort.values)
            CupertinoActionSheetAction(
              isDefaultAction: s == _sort,
              onPressed: () {
                Navigator.pop(ctx);
                setState(() {
                  if (_sort == s) {
                    _ascending = !_ascending;
                  } else {
                    _sort = s;
                    _ascending = false;
                  }
                });
              },
              child: Text(s == _sort ? 'Reverse ${s.label.toLowerCase()} order' : 'Sort by ${s.label.toLowerCase()}'),
            ),
          if (items.isNotEmpty)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _exportCsv(items);
              },
              child: const Text('Export CSV'),
            ),
          CupertinoActionSheetAction(
            onPressed: _rescanning
                ? () => Navigator.pop(ctx)
                : () {
                    Navigator.pop(ctx);
                    _rescan();
                  },
            child: Text(_rescanning ? 'Reclassifying…' : 'Reclassify saved sessions'),
          ),
          if (_detections.isNotEmpty)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                _clearAll();
              },
              child: Text('Delete all (${_detections.length})'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(historyFilterRequestProvider, (_, req) {
      if (req == null) return;
      setState(() => _engineFilter = req);
      ref.read(historyFilterRequestProvider.notifier).state = null;
      _load();
    });
    final items = _loading ? const <Map<String, dynamic>>[] : _filtered;
    final filtered = _activeFilterCount > 0 || _search.trim().isNotEmpty;

    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(children: [
          LiveHistorySwitch(live: false, onChanged: (live) => live ? widget.onShowLive?.call() : null),
          const SizedBox(height: 10),
          IosSearch(controller: _searchCtrl, placeholder: 'MAC, name, SSID, method', onChanged: (v) => setState(() => _search = v)),
          const SizedBox(height: 10),
          IosSegments<bool>(value: _showMap, segments: const {false: 'List', true: 'Map'}, onChanged: (v) => setState(() => _showMap = v)),
        ]),
      ),
    );

    final page = IosPage(
      title: 'History',
      actions: [
        IosNavButton(
          icon: _activeFilterCount > 0 ? CupertinoIcons.line_horizontal_3_decrease_circle_fill : CupertinoIcons.line_horizontal_3_decrease_circle,
          tooltip: 'Filter',
          onPressed: _detections.isEmpty ? null : _openFilterSheet,
        ),
        IosNavButton(icon: CupertinoIcons.ellipsis_circle, tooltip: 'More', onPressed: () => _openMore(items)),
      ],
      slivers: [
        header,
        if (filtered && _detections.isNotEmpty)
          SliverToBoxAdapter(
            child: IosSection(children: [
              IosRow(
                leading: const Icon(CupertinoIcons.line_horizontal_3_decrease, color: AppTheme.accent),
                title: '${items.length} of ${_detections.length} shown',
                trailing: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    _clearFilters();
                    _searchCtrl.clear();
                    setState(() => _search = '');
                  },
                  child: const Text('Clear'),
                ),
              ),
            ]),
          ),
        if (_loading)
          const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(48), child: CupertinoActivityIndicator()))
        else if (_detections.isEmpty)
          SliverToBoxAdapter(
            child: IosEmpty(
              icon: CupertinoIcons.clock,
              title: 'No saved detections',
              message: 'Run a wardrive with the Flock, Detector, or Sky Spy engines. Their detections are saved here.',
              action: CupertinoButton(onPressed: () => context.go('/wardrive'), child: const Text('Go to Wardrive')),
            ),
          )
        else if (items.isEmpty)
          SliverToBoxAdapter(
            child: IosEmpty(
              icon: CupertinoIcons.line_horizontal_3_decrease,
              title: 'No matches',
              message: '${_detections.length} detections are saved; none match the current search or filter.',
              action: CupertinoButton(
                onPressed: () {
                  _clearFilters();
                  _searchCtrl.clear();
                  setState(() => _search = '');
                },
                child: const Text('Clear search and filters'),
              ),
            ),
          )
        else if (!_showMap)
          IosSliverSection(
            header: '${_sort.label} · $_sortDirection',
            itemCount: items.length,
            itemBuilder: (context, i) => DetectionRow(detection: detectionFromDbRow(items[i]), onTap: () => _open(items[i])),
          )
        else
          SliverToBoxAdapter(child: _map(items)),
      ],
    );
    return page;
  }

  Widget _map(List<Map<String, dynamic>> items) {
    final t = AppTheme.of(context);
    final geo = items.where((d) => d['latitude'] != null && d['longitude'] != null).toList();
    if (geo.isEmpty) {
      return const IosEmpty(icon: CupertinoIcons.location_slash, title: 'No locations', message: 'None of the shown detections have GPS data.');
    }
    final style = ref.watch(mapStyleProvider);
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final d in geo) {
      final lat = d['latitude'] as double;
      final lon = d['longitude'] as double;
      minLat = min(minLat, lat);
      maxLat = max(maxLat, lat);
      minLon = min(minLon, lon);
      maxLon = max(maxLon, lon);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && geo.length > 1) {
        _mapController.fitCamera(CameraFit.bounds(bounds: LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon)), padding: const EdgeInsets.all(40)));
      }
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2),
              initialZoom: geo.length == 1 ? 16 : 13,
              backgroundColor: style.isDark ? const Color(0xFF0A0A0A) : t.surfaceLight,
            ),
            children: [
              mapTileLayer(style),
              MarkerLayer(markers: [
                for (final d in geo)
                  Marker(
                    point: LatLng(d['latitude'] as double, d['longitude'] as double),
                    width: 44,
                    height: 44,
                    child: GestureDetector(
                      onTap: () => _open(d),
                      child: Center(
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _engineColor(d['engine'] as String).withValues(alpha: 0.85),
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
              mapAttribution(style),
            ],
          ),
        ),
      ),
    );
  }
}
