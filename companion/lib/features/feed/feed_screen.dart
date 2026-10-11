import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/db/app_database.dart' show databaseProvider;
import 'package:oui_spy/core/db/detection_mapper.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/drone_grouping.dart';
import 'package:oui_spy/core/export/detections_csv.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/radio_classifier.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/features/feed/detection_row.dart';
import 'package:oui_spy/features/feed/feed_stats_header.dart';
import 'package:oui_spy/features/feed/filter_bar.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/command_bar.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum FeedMetric {
  time('Time'),
  rssi('Signal'),
  count('Times seen'),
  name('Name'),
  channel('Channel');

  const FeedMetric(this.label);
  final String label;
}

class LiveHistorySwitch extends StatelessWidget {
  const LiveHistorySwitch({super.key, required this.live, required this.onChanged});

  final bool live;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => IosSegments<bool>(
        value: live,
        segments: const {true: 'Live', false: 'History'},
        onChanged: onChanged,
      );
}

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key, this.onShowHistory});

  final VoidCallback? onShowHistory;

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  Set<Engine> _activeFilters = Engine.values.toSet();
  RadioFilter? _activeRadio;
  String _searchQuery = '';
  String? _selectedNode;
  bool _showStats = true;
  FeedMetric _sortMetric = FeedMetric.time;
  bool _sortAscending = false;
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  List<Detection> _dbHits = const [];
  bool _dbSearching = false;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String q) {
    setState(() => _searchQuery = q);
    _searchDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _dbHits = const [];
        _dbSearching = false;
      });
      return;
    }
    setState(() => _dbSearching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 350), () => _runDbSearch(q));
  }

  Future<void> _runDbSearch(String q) async {
    final term = q.trim();
    if (term.isEmpty) return;
    try {
      final rows = await ref.read(databaseProvider).searchDetectionMaps(term);
      if (!mounted || _searchQuery != q) return;
      setState(() {
        _dbHits = rows.map(detectionFromDbRow).toList();
        _dbSearching = false;
      });
    } catch (e) {
      DebugLog.log('FEED: history search failed: $e');
      if (!mounted) return;
      setState(() => _dbSearching = false);
    }
  }

  List<Detection> _mergeHistory(List<Detection> live, List<Detection> history) {
    if (history.isEmpty) return live;
    final seen = <String>{for (final d in live) '${d.macAddress}|${d.engine.name}'};
    final extra = history.where((d) => seen.add('${d.macAddress}|${d.engine.name}')).toList();
    if (extra.isEmpty) return live;
    return [...live, ...extra];
  }

  bool get _allEnginesActive => _activeFilters.length == Engine.values.length && _activeRadio == null;

  int get _activeFilterCount => (_allEnginesActive ? 0 : 1) + (_selectedNode != null ? 1 : 0);

  String _engineFilterLabel() {
    for (final p in FilterPreset.values) {
      if (p == FilterPreset.all) continue;
      if (p.matches(_activeFilters, _activeRadio)) return p.label;
    }
    if (_activeFilters.isEmpty) return 'No engines';
    return '${_activeFilters.length} engines';
  }

  void _resetFilters() => setState(() {
        _activeFilters = Engine.values.toSet();
        _activeRadio = null;
        _selectedNode = null;
      });

  List<Detection> _mergeFlockFromWardrive(List<Detection> feed, WardriveController wd) {
    if (!wd.isActive || !wd.includesFlock) return feed;
    final flockDets = wd.flockDetections;
    if (flockDets.isEmpty) return feed;
    final have = <String>{
      for (final d in feed)
        if (d.engine == Engine.flockBle || d.engine == Engine.flockWifi) d.macAddress,
    };
    final missing = flockDets.where((d) => !have.contains(d.macAddress)).toList();
    if (missing.isEmpty) return feed;
    return [...missing, ...feed];
  }

  bool _radioMatches(Detection d) {
    if (_activeRadio == null) return true;
    return _activeRadio == RadioFilter.ble ? d.isBleDetection : d.isWifiDetection;
  }

  List<Detection> _filter(List<Detection> detections) {
    final q = _searchQuery.trim().toLowerCase();
    return detections.where((d) {
      if (!_activeFilters.contains(d.engine)) return false;
      if (!_radioMatches(d)) return false;
      if (_selectedNode != null) {
        if (_selectedNode == '' && d.sourceNodeId.isNotEmpty) return false;
        if (_selectedNode!.isNotEmpty && d.sourceNodeId != _selectedNode) return false;
      }
      if (q.isEmpty) return true;
      return d.macAddress.toLowerCase().contains(q) ||
          d.deviceName.toLowerCase().contains(q) ||
          d.ssid.toLowerCase().contains(q) ||
          d.method.toLowerCase().contains(q) ||
          d.sourceNodeId.toLowerCase().contains(q);
    }).toList();
  }

  List<Detection> _sorted(List<Detection> detections) {
    final sorted = List<Detection>.from(detections);
    int dir(int v) => _sortAscending ? v : -v;
    switch (_sortMetric) {
      case FeedMetric.time:
        sorted.sort((a, b) => dir(a.appTimestamp.compareTo(b.appTimestamp)));
      case FeedMetric.rssi:
        sorted.sort((a, b) => dir(a.rssi.compareTo(b.rssi)));
      case FeedMetric.count:
        sorted.sort((a, b) => dir(a.count.compareTo(b.count)));
      case FeedMetric.name:
        sorted.sort((a, b) => dir(a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase())));
      case FeedMetric.channel:
        sorted.sort((a, b) => dir(a.channel.compareTo(b.channel)));
    }
    return sorted;
  }

  String get _sortDirection => switch ((_sortMetric, _sortAscending)) {
        (FeedMetric.time, true) => 'oldest first',
        (FeedMetric.time, false) => 'newest first',
        (FeedMetric.rssi, true) => 'weakest first',
        (FeedMetric.rssi, false) => 'strongest first',
        (FeedMetric.count, true) => 'fewest first',
        (FeedMetric.count, false) => 'most first',
        (FeedMetric.name, true) => 'A to Z',
        (FeedMetric.name, false) => 'Z to A',
        (FeedMetric.channel, true) => 'lowest first',
        (FeedMetric.channel, false) => 'highest first',
      };

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appStateProvider);
    final wd = ref.watch(wardriveProvider);
    final merged = _mergeFlockFromWardrive(state.recentDetections, wd);
    final hasQuery = _searchQuery.trim().isNotEmpty;
    final scope = hasQuery ? _mergeHistory(merged, _dbHits) : merged;
    final filtered = _sorted(_filter(scope));
    final sourceNodes = state.isManagerConnected ? state.meshSourceNodes : const <String>{};

    final droneGroups = groupDronesByUavId(filtered);
    final droneIds = droneGroups.map((g) => g.uavId).toSet();
    final rows = filtered.where((d) {
      if (d.engine != Engine.skySpy) return true;
      final id = d.odid?.uavId ?? '';
      return id.isEmpty || !droneIds.contains(id);
    }).toList();
    final items = <Object>[...rows, ...droneGroups];
    final index = Map<Detection, int>.identity();
    for (var i = 0; i < rows.length; i++) {
      index[rows[i]] = i;
    }
    items.sort((a, b) {
      if (a is Detection && b is Detection) return index[a]!.compareTo(index[b]!);
      DateTime ts(Object o) => o is Detection ? o.appTimestamp : (o as DroneGroup).representative.appTimestamp;
      return _sortAscending ? ts(a).compareTo(ts(b)) : ts(b).compareTo(ts(a));
    });

    final filterSummary = [
      if (!_allEnginesActive) _engineFilterLabel(),
      if (_selectedNode != null) _selectedNode!.isEmpty ? 'This node' : state.labelForNode(_selectedNode!),
    ].join(' · ');

    return IosPage(
      title: 'Live',
      actions: [
        IosNavButton(
          icon: _activeFilterCount > 0 ? CupertinoIcons.line_horizontal_3_decrease_circle_fill : CupertinoIcons.line_horizontal_3_decrease_circle,
          tooltip: 'Filter',
          onPressed: () => _openFilterSheet(sourceNodes, state.labelForNode),
        ),
        IosNavButton(icon: CupertinoIcons.ellipsis_circle, tooltip: 'More', onPressed: () => _openMore(state)),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(children: [
              LiveHistorySwitch(live: true, onChanged: (live) => live ? null : widget.onShowHistory?.call()),
              const SizedBox(height: 10),
              IosSearch(controller: _searchCtrl, placeholder: 'MAC, name, SSID, method, node', onChanged: _onSearchChanged),
            ]),
          ),
        ),
        if (filterSummary.isNotEmpty || hasQuery)
          SliverToBoxAdapter(
            child: IosSection(children: [
              IosRow(
                leading: const Icon(CupertinoIcons.line_horizontal_3_decrease, color: AppTheme.accent),
                title: '${filtered.length} of ${scope.length} shown',
                subtitle: Text([
                  if (filterSummary.isNotEmpty) filterSummary,
                  if (hasQuery) _dbSearching ? 'Searching saved history…' : 'Includes saved history',
                ].join(' · ')),
                trailing: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    _resetFilters();
                    _searchCtrl.clear();
                    _onSearchChanged('');
                  },
                  child: const Text('Clear'),
                ),
              ),
            ]),
          ),
        if (_showStats && filtered.length >= 2) SliverToBoxAdapter(child: FeedStatsHeader(detections: filtered)),
        if (items.isEmpty)
          SliverToBoxAdapter(
            child: state.isConnected
                ? IosEmpty(
                    icon: CupertinoIcons.dot_radiowaves_left_right,
                    title: scope.isEmpty ? 'No detections yet' : 'No matches',
                    message: scope.isEmpty
                        ? 'Turn on an engine on Home. Detections from the node appear here as they arrive.'
                        : 'Nothing matches the current search or filter.',
                    action: scope.isEmpty
                        ? CupertinoButton(onPressed: () => context.go('/home'), child: const Text('Go to engines'))
                        : CupertinoButton(
                            onPressed: () {
                              _resetFilters();
                              _searchCtrl.clear();
                              _onSearchChanged('');
                            },
                            child: const Text('Clear search and filters'),
                          ),
                  )
                : IosEmpty(
                    icon: CupertinoIcons.bluetooth,
                    title: 'Not connected',
                    message: 'Connect to an OUI-SPY node to see live detections.',
                    action: CupertinoButton.filled(onPressed: () => context.push('/onboarding'), child: const Text('Connect')),
                  ),
          )
        else
          IosSliverSection(
            header: '${items.length} ${_sortMetric.label.toLowerCase()} · $_sortDirection',
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              return item is DroneGroup ? DroneDetectionRow(group: item) : DetectionRow(detection: item as Detection);
            },
          ),
      ],
    );
  }

  Future<void> _openFilterSheet(Set<String> sourceNodes, String Function(String) labelForNode) {
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
                : CupertinoButton(padding: const EdgeInsets.symmetric(horizontal: 8), onPressed: () => apply(_resetFilters), child: const Text('Reset')),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CommandSheetGroup(
                  label: 'Show',
                  child: CommandOptionList(children: [
                    for (final p in FilterPreset.values)
                      CommandOption(
                        label: p.label,
                        selected: p.matches(_activeFilters, _activeRadio),
                        color: switch (p) {
                          FilterPreset.all => kPillAll,
                          FilterPreset.ble => kPillBle,
                          FilterPreset.wifi => kPillWifi,
                          FilterPreset.flock => AppTheme.flockWifi,
                          FilterPreset.drones => AppTheme.skySpy,
                          FilterPreset.alerts => AppTheme.error,
                        },
                        onTap: () => apply(() {
                          _activeFilters = p.resolve();
                          _activeRadio = p.radio;
                        }),
                      ),
                  ]),
                ),
                if (sourceNodes.isNotEmpty)
                  CommandSheetGroup(
                    label: 'Heard by',
                    child: CommandOptionList(children: [
                      for (final (i, (id, label)) in <(String?, String)>[
                        (null, 'All nodes'),
                        ('', 'This node'),
                        ...sourceNodes.map((n) => (n, labelForNode(n))),
                      ].indexed)
                        CommandOption(label: label, selected: _selectedNode == id, color: pillColor(i), onTap: () => apply(() => _selectedNode = id)),
                    ]),
                  ),
                CommandSheetGroup(
                  label: 'Engines',
                  child: CommandOptionList(children: [
                    for (final e in Engine.values)
                      CommandOption(
                        label: e.label,
                        selected: _activeFilters.contains(e),
                        color: e.color,
                        onTap: () => apply(() {
                          final next = Set<Engine>.from(_activeFilters);
                          next.contains(e) ? next.remove(e) : next.add(e);
                          _activeFilters = next;
                          _activeRadio = null;
                        }),
                      ),
                  ]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openMore(AppState state) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Sorted by ${_sortMetric.label.toLowerCase()}, $_sortDirection'),
        actions: [
          for (final m in FeedMetric.values)
            CupertinoActionSheetAction(
              isDefaultAction: m == _sortMetric,
              onPressed: () {
                Navigator.pop(ctx);
                setState(() {
                  if (_sortMetric == m) {
                    _sortAscending = !_sortAscending;
                  } else {
                    _sortMetric = m;
                    _sortAscending = false;
                  }
                });
              },
              child: Text(m == _sortMetric ? 'Reverse ${m.label.toLowerCase()} order' : 'Sort by ${m.label.toLowerCase()}'),
            ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _showStats = !_showStats);
            },
            child: Text(_showStats ? 'Hide summary' : 'Show summary'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _exportCsv(context);
            },
            child: const Text('Export CSV'),
          ),
          if (state.recentDetections.isNotEmpty)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                _clearAll(context);
              },
              child: Text('Clear feed (${state.recentDetections.length})'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
  }

  Future<void> _clearAll(BuildContext context) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Clear the feed?'),
        content: const Text('Removes every detection from the live feed and resets the counts. Saved history is kept.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) ref.read(appStateProvider).resetCounts();
  }

  Future<void> _exportCsv(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 100, 100);
    try {
      final rows = await ref.read(databaseProvider).getAllDetectionMaps();
      final history = rows.map(detectionFromDbRow).toList();
      final live = _mergeFlockFromWardrive(ref.read(appStateProvider).recentDetections, ref.read(wardriveProvider));
      final detections = _sorted(_filter(_mergeHistory(live, history)));
      if (detections.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('Nothing to export')));
        return;
      }
      final csv = DetectionsCsv.generate(detections);
      final dir = await getTemporaryDirectory();
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/oui_spy_feed_$ts.csv');
      await file.writeAsString(csv);
      await Share.shareXFiles([XFile(file.path)], subject: 'OUI-SPY Feed Export (${detections.length} detections)', sharePositionOrigin: origin);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}
