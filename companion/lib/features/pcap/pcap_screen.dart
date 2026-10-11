import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/features/pcap/pcap_stats.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:oui_spy/features/config/widgets/config_widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

class PcapScreen extends ConsumerStatefulWidget {
  const PcapScreen({super.key});

  @override
  ConsumerState<PcapScreen> createState() => _PcapScreenState();
}

class _PcapScreenState extends ConsumerState<PcapScreen> {
  PcapMode _mode = PcapMode.wifi;
  int _chanStart = 1;
  int _chanEnd = 11;
  int _mode5g = 1;
  bool _toggling = false;
  String? _targetNode;
  PcapStats? _heldStats;
  bool? _autoPcapOverride;
  int? _autoDurationOverride;
  int _autoDurationSec = 10;
  int? _autoCooldownOverride;

  File? _lastSaved;
  int _bytesWritten = 0;
  StreamSubscription<int>? _bytesSub;
  StreamSubscription<File>? _savedSub;
  Timer? _bytesTimer;
  Timer? _toggleTimeout;
  bool _pendingStart = false;
  bool _pendingStop = false;
  int _pendingBytes = 0;

  @override
  void initState() {
    super.initState();
    final ble = ref.read(bleManagerProvider);
    _bytesWritten = ble.pcapBytesWrittenLatest;
    _pendingBytes = _bytesWritten;
    _bytesSub = ble.pcapBytesWritten.listen((v) {
      _pendingBytes = v;
    });
    _bytesTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (_pendingBytes != _bytesWritten) {
        setState(() => _bytesWritten = _pendingBytes);
      }
    });
    _savedSub = ble.pcapCaptureSaved.listen((f) {
      if (mounted) setState(() => _lastSaved = f);
    });
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _chanStart = (p.getInt('pcap_chanStart') ?? 1).clamp(1, 14);
      _chanEnd = (p.getInt('pcap_chanEnd') ?? 11).clamp(_chanStart, 14);
      _mode5g = (p.getInt('pcap_mode5g') ?? 1).clamp(0, 2);
      final modeIdx = p.getInt('pcap_mode') ?? 0;
      _mode = modeIdx == 1 ? PcapMode.ble : PcapMode.wifi;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('pcap_chanStart', _chanStart);
    await p.setInt('pcap_chanEnd', _chanEnd);
    await p.setInt('pcap_mode', _mode == PcapMode.ble ? 1 : 0);
    await p.setInt('pcap_mode5g', _mode5g);
  }

  @override
  void dispose() {
    _bytesSub?.cancel();
    _savedSub?.cancel();
    _bytesTimer?.cancel();
    _toggleTimeout?.cancel();
    super.dispose();
  }

  Future<Directory> _pcapDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/pcaps');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<File>> _listSavedPcaps() async {
    final d = await _pcapDir();
    final files = await d
        .list()
        .where((e) => e is File && e.path.endsWith('.pcap'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> _start() async {
    if (_toggling) return;
    final appState = ref.read(appStateProvider);
    final mgr = appState.isManagerConnected;
    String? target = _targetNode;
    if (mgr && (target == null || target.isEmpty)) {
      final nodes = appState.liveKnownNodes
          .where((id) => id != appState.nodeId)
          .toList();
      if (nodes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No live node to capture on')));
        return;
      }
      target = nodes.first;
      setState(() => _targetNode = target);
    }
    setState(() {
      _toggling = true;
      _heldStats = null;
    });
    try {
      await ref.read(bleManagerProvider).startPcap(
            mode: _mode == PcapMode.ble ? 1 : 0,
            channelStart: _chanStart,
            channelEnd: _chanEnd,
            mode5g: _mode5g,
            targetNodeId: mgr ? target : null,
          );
      if (mounted) setState(() { _pendingStart = true; });
      _armToggleTimeout();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Start failed: $e')));
        setState(() { _toggling = false; _pendingStart = false; });
      }
    }
  }

  Future<void> _stop() async {
    if (_toggling) return;
    setState(() => _toggling = true);
    try {
      final mgr = ref.read(appStateProvider).isManagerConnected;
      await ref.read(bleManagerProvider).stopPcap(
            targetNodeId: mgr ? _targetNode : null,
          );
      if (mounted) setState(() { _pendingStop = true; });
      _armToggleTimeout();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Stop failed: $e')));
        setState(() { _toggling = false; _pendingStop = false; });
      }
    }
  }

  void _armToggleTimeout() {
    _toggleTimeout?.cancel();
    _toggleTimeout = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() { _toggling = false; _pendingStart = false; _pendingStop = false; });
      }
    });
  }

  Future<void> _shareFile(File f) async {
    if (!await f.exists()) return;
    final size = await f.length();
    if (!mounted) return;
    final size2 = MediaQuery.of(context).size;
    final origin = Rect.fromLTWH(size2.width / 2 - 1, size2.height / 2 - 1, 2, 2);
    await Share.shareXFiles(
      [XFile(f.path, mimeType: 'application/vnd.tcpdump.pcap')],
      subject: 'OUI-SPY PCAP ($size bytes)',
      sharePositionOrigin: origin,
    );
  }

  void _pickChannel({required bool isStart}) async {
    final current = isStart ? _chanStart : _chanEnd;
    final min = isStart ? 1 : _chanStart;
    final items = <int>[for (int i = min; i <= 14; i++) i];
    final v = await showCupertinoModalPopup<int>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(isStart ? 'Start channel' : 'End channel'),
        actions: [
          for (final ch in items)
            CupertinoActionSheetAction(
              isDefaultAction: ch == current,
              onPressed: () => Navigator.pop(ctx, ch),
              child: Text('Channel $ch'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (v == null) return;
    setState(() {
      if (isStart) {
        _chanStart = v;
        if (v > _chanEnd) _chanEnd = v;
      } else {
        _chanEnd = v;
      }
    });
    _savePrefs();
  }

  void _pick5gMode() async {
    final v = await showCupertinoModalPopup<int>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('5 GHz mode'),
        actions: [
          CupertinoActionSheetAction(isDefaultAction: _mode5g == 0, onPressed: () => Navigator.pop(ctx, 0), child: const Text('Off')),
          CupertinoActionSheetAction(isDefaultAction: _mode5g == 1, onPressed: () => Navigator.pop(ctx, 1), child: const Text('Regular (non-DFS)')),
          CupertinoActionSheetAction(isDefaultAction: _mode5g == 2, onPressed: () => Navigator.pop(ctx, 2), child: const Text('+ DFS')),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
    if (v == null) return;
    setState(() => _mode5g = v);
    _savePrefs();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final ble = ref.watch(bleManagerProvider);

    return Scaffold(
      backgroundColor: t.background,
      body: StreamBuilder<PcapStats>(
        stream: ble.pcapStats,
        initialData: ble.latestPcapStats,
        builder: (context, snap) {
          final s = snap.data ?? PcapStats.empty;
          final isPaused = s.state == 4;
          final isCapturing = s.state == 1;
          final isActive = isCapturing || isPaused;
          if ((_pendingStart && isCapturing) || (_pendingStop && !isActive)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _toggleTimeout?.cancel();
                setState(() { _toggling = false; _pendingStart = false; _pendingStop = false; });
              }
            });
          }
          if (isActive) _heldStats = s;
          final gridStats = isActive ? s : (_heldStats ?? s);
          final activeMode = isActive ? s.modeEnum : _mode;
          final hasFile = _lastSaved != null && !isCapturing;
          if (_autoPcapOverride != null && _autoPcapOverride == s.autoEnabled) {
            _autoPcapOverride = null;
          }
          if (_autoDurationOverride != null && _autoDurationOverride == s.autoDurationSec) {
            _autoDurationOverride = null;
          }
          if (_autoCooldownOverride != null && _autoCooldownOverride == s.autoCooldownSec) {
            _autoCooldownOverride = null;
          }
          final autoEnabled = _autoPcapOverride ?? s.autoEnabled;
          final autoDuration = _autoDurationOverride
              ?? (s.autoDurationSec > 0 ? s.autoDurationSec : _autoDurationSec);
          final autoCooldown = _autoCooldownOverride ?? s.autoCooldownSec;

          final uptimeS = s.uptimeMs ~/ 1000;
          Color stateColor;
          switch (s.state) {
            case 1: stateColor = AppTheme.success;
            case 2: stateColor = AppTheme.warning;
            case 3: stateColor = AppTheme.error;
            case 4: stateColor = AppTheme.warning;
            default: stateColor = t.textDim;
          }

          return IosPage(
            title: 'Packet capture',
            leading: CupertinoNavigationBarBackButton(
              color: AppTheme.accent,
              onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
            ),
            actions: [
              IosNavButton(
                icon: CupertinoIcons.collections,
                tooltip: 'Capture library',
                onPressed: () => context.push('/pcap/library'),
              ),
            ],
            slivers: [
              SliverToBoxAdapter(
                child: IosSection(
                  header: 'Status',
                  children: [
                    IosRow(
                      leading: _StatDot(color: stateColor),
                      title: s.stateLabel,
                      detail: Text(s.modeLabel, style: TextStyle(color: t.textDim, fontSize: 15)),
                    ),
                    IosRow(
                      title: 'Uptime',
                      detail: Text('${uptimeS}s', style: TextStyle(color: t.textSecondary, fontSize: 15, fontFamily: 'monospace')),
                    ),
                    IosRow(
                      title: 'Sent',
                      detail: Text(_humanBytes(s.bytesWritten), style: TextStyle(color: t.textSecondary, fontSize: 15, fontFamily: 'monospace')),
                    ),
                    IosRow(
                      title: 'Received',
                      detail: Text(_humanBytes(_bytesWritten), style: TextStyle(color: t.textSecondary, fontSize: 15, fontFamily: 'monospace')),
                    ),
                    if (s.modeEnum == PcapMode.wifi)
                      IosRow(
                        title: 'Channel',
                        detail: Text('${s.currentChannel}', style: TextStyle(color: t.textSecondary, fontSize: 15, fontFamily: 'monospace')),
                      ),
                    IosRow(
                      title: 'Dropped',
                      detail: Text('${s.droppedFrames}', style: TextStyle(color: s.droppedFrames > 0 ? AppTheme.error : t.textSecondary, fontSize: 15, fontFamily: 'monospace')),
                    ),
                    if (s.isAutoTriggered)
                      IosRow(
                        leading: const IosIcon(Icons.bolt, AppTheme.warning),
                        title: 'Auto-triggered',
                        subtitle: Text('${s.autoTriggerEngineName} ${s.autoTriggerMacStr}${s.autoRemainingMs > 0 ? ' · ${(s.autoRemainingMs / 1000).ceil()}s' : ''}'),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: IosSection(
                  header: 'Auto-PCAP',
                  footer: autoEnabled
                      ? 'Any detection starts a capture automatically.'
                      : 'Off. Detections are not auto-captured.',
                  children: [
                    ConfigToggleRow(
                      icon: Icons.bolt,
                      label: 'Auto-PCAP on detect',
                      color: AppTheme.accent,
                      value: autoEnabled,
                      onChanged: (v) async {
                        setState(() => _autoPcapOverride = v);
                        try {
                          await ble.setAutoPcap(v);
                        } on Exception catch (e) {
                          if (context.mounted) {
                            setState(() => _autoPcapOverride = null);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Auto-PCAP set failed: $e')),
                            );
                          }
                        }
                      },
                    ),
                    if (autoEnabled) ...[
                      ConfigSliderRow(
                        icon: Icons.timer,
                        label: 'Window',
                        valueLabel: '${autoDuration}s',
                        min: 3, max: 120, divisions: 39,
                        value: autoDuration.toDouble().clamp(3, 120),
                        onChanged: (v) async {
                          final val = v.round();
                          setState(() {
                            _autoDurationOverride = val;
                            _autoDurationSec = val;
                          });
                          try {
                            await ble.setAutoPcapDuration(val);
                          } on Exception catch (e) {
                            if (context.mounted) {
                              setState(() => _autoDurationOverride = null);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Duration set failed: $e')),
                              );
                            }
                          }
                        },
                      ),
                      ConfigSliderRow(
                        icon: Icons.hourglass_bottom,
                        label: 'Cooldown',
                        valueLabel: autoCooldown == 0 ? 'Off' : '${autoCooldown}s',
                        min: 0, max: 600, divisions: 60,
                        value: autoCooldown.toDouble().clamp(0, 600),
                        onChanged: (v) async {
                          final val = v.round();
                          setState(() => _autoCooldownOverride = val);
                          try {
                            await ble.setAutoPcapCooldown(val);
                          } on Exception catch (e) {
                            if (context.mounted) {
                              setState(() => _autoCooldownOverride = null);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Cooldown set failed: $e')),
                              );
                            }
                          }
                        },
                      ),
                      if (s.autoCooldownRemainingMs > 0)
                        IosRow(
                          leading: const IosIcon(Icons.hourglass_bottom, AppTheme.warning),
                          title: 'Cooldown active',
                          detail: Text('${(s.autoCooldownRemainingMs / 1000).ceil()}s', style: TextStyle(color: AppTheme.warning, fontSize: 15, fontFamily: 'monospace')),
                        ),
                    ],
                  ],
                ),
              ),
              SliverToBoxAdapter(child: _NodePicker(
                selected: _targetNode,
                enabled: !isCapturing,
                onChanged: (id) => setState(() => _targetNode = id),
              )),
              SliverToBoxAdapter(
                child: IosSection(
                  header: 'Mode',
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: IosSegments<PcapMode>(
                        value: _mode,
                        segments: const {PcapMode.wifi: 'Wi-Fi 802.11', PcapMode.ble: 'BLE LL PHDR'},
                        onChanged: isCapturing ? (_) {} : (m) {
                          setState(() => _mode = m);
                          _savePrefs();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              if (_mode == PcapMode.wifi) ...[
                SliverToBoxAdapter(
                  child: IosSection(
                    header: 'Channels',
                    children: [
                      IosRow(
                        title: 'Start',
                        detail: Text('$_chanStart', style: TextStyle(color: t.textSecondary, fontSize: 17)),
                        chevron: !isCapturing,
                        disabled: isCapturing,
                        onTap: isCapturing ? null : () => _pickChannel(isStart: true),
                      ),
                      IosRow(
                        title: 'End',
                        detail: Text('$_chanEnd', style: TextStyle(color: t.textSecondary, fontSize: 17)),
                        chevron: !isCapturing,
                        disabled: isCapturing,
                        onTap: isCapturing ? null : () => _pickChannel(isStart: false),
                      ),
                      if (ref.read(bleManagerProvider).board.toLowerCase().contains('c5'))
                        IosRow(
                          title: '5 GHz',
                          detail: Text(
                            switch (_mode5g) { 0 => 'Off', 1 => 'Regular', 2 => '+ DFS', _ => '?' },
                            style: TextStyle(color: t.textSecondary, fontSize: 17),
                          ),
                          chevron: !isCapturing,
                          disabled: isCapturing,
                          onTap: isCapturing ? null : _pick5gMode,
                        ),
                    ],
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: activeMode == PcapMode.wifi
                    ? _WifiStatsSection(stats: gridStats)
                    : _BleStatsSection(stats: gridStats),
              ),
              SliverToBoxAdapter(
                child: IosSection(
                  children: [
                    IosRow(
                      leading: IosIcon(
                        isActive ? CupertinoIcons.stop_fill : CupertinoIcons.circle_fill,
                        isActive ? AppTheme.error : AppTheme.success,
                      ),
                      title: _toggling
                          ? (isActive ? 'Writing file' : 'Starting')
                          : (isActive ? 'Stop' : 'Start'),
                      disabled: _toggling,
                      onTap: _toggling ? null : (isActive ? _stop : _start),
                    ),
                    if (isActive)
                      IosRow(
                        leading: IosIcon(
                          isPaused ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
                          AppTheme.warning,
                        ),
                        title: isPaused ? 'Resume' : 'Pause',
                        disabled: _toggling,
                        onTap: _toggling
                            ? null
                            : (isPaused
                                ? () => ref.read(bleManagerProvider).resumePcap()
                                : () => ref.read(bleManagerProvider).pausePcap()),
                      ),
                    if (hasFile)
                      IosRow(
                        leading: const IosIcon(CupertinoIcons.share, AppTheme.accent),
                        title: 'Share last capture',
                        onTap: () => _shareFile(_lastSaved!),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: _SavedPcapsSection(
                  loader: _listSavedPcaps,
                  refreshTick: _lastSaved?.path.hashCode ?? 0,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          );
        },
      ),
    );
  }
}

class _StatDot extends StatelessWidget {
  const _StatDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30, height: 30,
      child: Center(
        child: Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _WifiStatsSection extends StatelessWidget {
  const _WifiStatsSection({required this.stats});
  final PcapStats stats;

  @override
  Widget build(BuildContext context) {
    return IosSection(
      header: 'Frame counts',
      children: [
        _statRow('Beacons', stats.beaconCount, AppTheme.accent),
        _statRow('Probe requests', stats.probeReqCount, AppTheme.warning),
        _statRow('Probe responses', stats.probeRespCount, AppTheme.warning),
        _statRow('Deauth', stats.deauthCount, AppTheme.error),
        _statRow('Disassociation', stats.disassocCount, AppTheme.error),
        _statRow('Data', stats.dataCount, AppTheme.success),
        _statRow('Control', stats.ctrlCount, null),
        _statRow('Management other', stats.mgmtOtherCount, null),
      ],
    );
  }
}

class _BleStatsSection extends StatelessWidget {
  const _BleStatsSection({required this.stats});
  final PcapStats stats;

  @override
  Widget build(BuildContext context) {
    return IosSection(
      header: 'Frame counts',
      children: [
        _statRow('Advertisements', stats.bleAdvCount, AppTheme.accent),
        _statRow('Scan responses', stats.bleScanCount, AppTheme.warning),
      ],
    );
  }
}

Widget _statRow(String label, int value, Color? color) {
  return Builder(builder: (context) {
    final t = AppTheme.of(context);
    return IosRow(
      title: label,
      detail: Text(
        _fmt(value),
        style: TextStyle(color: color ?? t.textDim, fontSize: 17, fontFamily: 'monospace', fontWeight: FontWeight.w600),
      ),
    );
  });
}

String _fmt(int v) {
  if (v < 1000) return v.toString();
  if (v < 1000000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '${(v / 1000000).toStringAsFixed(2)}M';
}

String _humanBytes(int n) {
  if (n < 1024) return '${n}B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
  return '${(n / 1024 / 1024).toStringAsFixed(2)}MB';
}

class _NodePicker extends ConsumerWidget {
  const _NodePicker({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });
  final String? selected;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    final t = AppTheme.of(context);
    final mgr = appState.isManagerConnected;

    if (!mgr) {
      return IosSection(
        header: 'Capture node',
        children: [
          IosRow(
            leading: IosIcon(Icons.memory, t.textDim),
            title: 'Local capture',
            subtitle: const Text('Captures on this device'),
          ),
        ],
      );
    }

    final nodes = appState.liveKnownNodes
        .where((id) => id != appState.nodeId)
        .toList();
    String name(String id) {
      final label = appState.labelForNode(id);
      return label == id ? id : '$label ($id)';
    }
    if (nodes.isEmpty) {
      return IosSection(
        header: 'Capture node',
        children: [
          IosRow(
            leading: IosIcon(CupertinoIcons.device_laptop, t.textDim),
            title: 'Capture from',
            detail: Text('No nodes seen yet', style: TextStyle(color: t.textDim, fontSize: 17)),
          ),
        ],
      );
    }
    final current = nodes.contains(selected) ? selected : null;
    return IosSection(
      header: 'Capture node',
      children: [
        IosRow(
          leading: const IosIcon(CupertinoIcons.device_laptop, AppTheme.accent),
          title: 'Capture from',
          detail: Text(
            current == null ? 'Choose' : name(current),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.textSecondary, fontSize: 17),
          ),
          chevron: enabled,
          disabled: !enabled,
          onTap: !enabled
              ? null
              : () async {
                  final v = await showCupertinoModalPopup<String>(
                    context: context,
                    builder: (ctx) => CupertinoActionSheet(
                      title: const Text('Capture from which node?'),
                      actions: [
                        for (final id in nodes)
                          CupertinoActionSheetAction(
                            isDefaultAction: id == current,
                            onPressed: () => Navigator.pop(ctx, id),
                            child: Text(name(id)),
                          ),
                      ],
                      cancelButton: CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                    ),
                  );
                  if (v != null) onChanged(v);
                },
        ),
      ],
    );
  }
}

class _SavedPcapsSection extends StatefulWidget {
  const _SavedPcapsSection({required this.loader, required this.refreshTick});
  final Future<List<File>> Function() loader;
  final int refreshTick;

  @override
  State<_SavedPcapsSection> createState() => _SavedPcapsSectionState();
}

class _SavedPcapsSectionState extends State<_SavedPcapsSection> {
  late Future<List<File>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  @override
  void didUpdateWidget(covariant _SavedPcapsSection old) {
    super.didUpdateWidget(old);
    if (old.refreshTick != widget.refreshTick) {
      _future = widget.loader();
    }
  }

  void _reload() => setState(() => _future = widget.loader());

  Future<void> _clearAll() async {
    final files = await widget.loader();
    if (files.isEmpty) return;
    if (!mounted) return;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete all captures?'),
        content: Text('${files.length} pcap file(s) will be deleted.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (ok != true) return;
    for (final f in files) {
      if (await f.exists()) await f.delete();
    }
    _reload();
  }

  Future<void> _shareFile(File f) async {
    final size = await f.length();
    if (!mounted) return;
    final size2 = MediaQuery.of(context).size;
    final origin = Rect.fromLTWH(size2.width / 2 - 1, size2.height / 2 - 1, 2, 2);
    await Share.shareXFiles(
      [XFile(f.path, mimeType: 'application/vnd.tcpdump.pcap')],
      subject: 'OUI-SPY PCAP ($size bytes)',
      sharePositionOrigin: origin,
    );
  }

  Future<void> _deleteFile(File f) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete capture?'),
        content: Text(f.uri.pathSegments.last),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (await f.exists()) await f.delete();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<File>>(
      future: _future,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final files = snap.data!;
        if (files.isEmpty) {
          return IosSection(
            header: 'Saved captures',
            children: [
              IosRow(
                leading: const IosIcon(CupertinoIcons.tray, AppTheme.accent),
                title: 'No captures yet',
              ),
            ],
          );
        }
        return IosSection(
          header: 'Saved captures',
          footer: '${files.length} file${files.length == 1 ? '' : 's'}',
          children: [
            for (final f in files)
              _PcapRow(
                file: f,
                onShare: () => _shareFile(f),
                onDelete: () => _deleteFile(f),
              ),
            IosRow(
              leading: const IosIcon(CupertinoIcons.trash, AppTheme.error),
              title: 'Delete all captures',
              onTap: _clearAll,
            ),
          ],
        );
      },
    );
  }
}

class _PcapRow extends StatelessWidget {
  const _PcapRow({required this.file, required this.onShare, required this.onDelete});
  final File file;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final name = file.uri.pathSegments.last;
    final isBle = name.contains('_ble_');
    return IosRow(
      leading: IosIcon(
        isBle ? Icons.bluetooth : Icons.wifi,
        isBle ? AppTheme.flockBle : AppTheme.accent,
      ),
      title: name,
      subtitle: FutureBuilder<int>(
        future: file.length(),
        builder: (ctx, snap) => Text(_humanBytes(snap.data ?? 0)),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(padding: EdgeInsets.zero, minimumSize: const Size.square(32), onPressed: onShare, child: Icon(CupertinoIcons.share, size: 20, color: t.textPrimary)),
          CupertinoButton(padding: EdgeInsets.zero, minimumSize: const Size.square(32), onPressed: onDelete, child: const Icon(CupertinoIcons.delete, size: 20, color: AppTheme.error)),
        ],
      ),
    );
  }
}
