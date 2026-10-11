import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

class FoxhunterScreen extends ConsumerStatefulWidget {
  const FoxhunterScreen({super.key});

  @override
  ConsumerState<FoxhunterScreen> createState() => _FoxhunterScreenState();
}

class _FoxhunterScreenState extends ConsumerState<FoxhunterScreen> {
  final _macController = TextEditingController();
  String? _lastSyncedTarget;

  @override
  void dispose() {
    _macController.dispose();
    super.dispose();
  }

  int _channelForMac(String mac) {
    final state = ref.read(appStateProvider);
    final macLower = mac.toLowerCase();
    for (final d in state.recentDetections) {
      if (d.macAddress.toLowerCase() == macLower && d.channel > 0) {
        return d.channel;
      }
    }
    return 0;
  }

  void _setTarget() {
    final mac = _macController.text.trim();
    if (mac.length != 17) return;
    final channel = _channelForMac(mac);
    final st = ref.read(appStateProvider);
    final node = st.isManagerConnected ? st.foxhunterTargetNodeId : null;
    st.setFoxhunterTarget(mac, channel: channel, nodeId: node);
  }

  void _clearTarget() {
    ref.read(appStateProvider).clearFoxhunterTarget();
    _macController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final state = ref.watch(appStateProvider);
    final isActive = state.isEngineActive(Engine.foxhunter);
    final target = state.foxhunterTarget;
    final rssi = state.foxhunterRssi;
    final intervalMs = state.foxhunterIntervalMs;
    final channel = state.foxhunterChannel;
    final targetLost = isActive && intervalMs == 0;
    final normalized = ((rssi + 100) / 70).clamp(0.0, 1.0);
    final color = targetLost
        ? t.textDim
        : Color.lerp(AppTheme.error, AppTheme.success, normalized)!;

    if (target != null && target != _lastSyncedTarget) {
      _macController.text = target;
    }
    _lastSyncedTarget = target;

    final canStart = !(state.isManagerConnected && state.foxhunterTargetNodeId == null);
    final status = !isActive ? 'Off' : (channel > 0 ? 'Channel $channel' : 'Scanning');

    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: 'Foxhunt',
        leading: CupertinoNavigationBarBackButton(color: AppTheme.accent, onPressed: () => context.canPop() ? context.pop() : context.go('/home')),
        slivers: [
          SliverToBoxAdapter(
            child: IosSection(
              header: 'Target',
              footer: target == null ? 'Enter the full address of the device to track.' : 'Tracking ${target.toUpperCase()}. $status.',
              children: [
                if (state.isManagerConnected)
                  _NodeTargetPicker(
                    selected: state.foxhunterTargetNodeId,
                    enabled: !isActive,
                    onChanged: (v) => ref.read(appStateProvider).setFoxhunterTargetNode(v),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: CupertinoTextField(
                    controller: _macController,
                    placeholder: 'AA:BB:CC:DD:EE:FF',
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: null,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 17),
                    placeholderStyle: TextStyle(color: t.textDim, fontFamily: 'monospace', fontSize: 17),
                  ),
                ),
                if (target != null)
                  IosRow(
                    leading: const IosIcon(CupertinoIcons.stop_fill, AppTheme.error),
                    title: 'Stop hunt',
                    onTap: _clearTarget,
                  )
                else
                  IosRow(
                    leading: const IosIcon(CupertinoIcons.scope, AppTheme.foxhunter),
                    title: 'Start hunt',
                    subtitle: canStart ? null : const Text('Pick a node to hunt from first'),
                    disabled: !canStart,
                    onTap: canStart ? _setTarget : null,
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: IosSection(
              header: 'Signal',
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 200, height: 200,
                        child: CustomPaint(
                          painter: _RssiGaugePainter(rssi: rssi, normalized: normalized, color: color, track: t.border),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('$rssi', style: TextStyle(color: color, fontSize: 48, fontWeight: FontWeight.w300)),
                                Text(targetLost ? 'Lost' : 'dBm', style: TextStyle(color: t.textSecondary, fontSize: 15)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        targetLost ? 'Target lost, still scanning' : (isActive ? 'Beeps every $intervalMs ms' : 'Start a hunt to see signal strength'),
                        style: TextStyle(color: targetLost ? AppTheme.error : t.textSecondary, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeTargetPicker extends ConsumerWidget {
  const _NodeTargetPicker({
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
    final nodes = appState.liveKnownNodes.toList()..sort();
    String name(String id) {
      final label = appState.labelForNode(id);
      return label == id ? id : '$label ($id)';
    }
    if (nodes.isEmpty) {
      return IosRow(
        leading: IosIcon(CupertinoIcons.device_laptop, t.textDim),
        title: 'Hunt from',
        detail: Text('No nodes seen yet', style: TextStyle(color: t.textDim, fontSize: 17)),
      );
    }
    final current = nodes.contains(selected) ? selected : null;
    return IosRow(
      leading: const IosIcon(CupertinoIcons.device_laptop, AppTheme.accent),
      title: 'Hunt from',
      detail: Text(current == null ? 'Choose' : name(current), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textSecondary, fontSize: 17)),
      chevron: enabled,
      disabled: !enabled,
      onTap: !enabled
          ? null
          : () async {
              final v = await showCupertinoModalPopup<String>(
                context: context,
                builder: (ctx) => CupertinoActionSheet(
                  title: const Text('Hunt from which node?'),
                  actions: [
                    for (final id in nodes)
                      CupertinoActionSheetAction(isDefaultAction: id == current, onPressed: () => Navigator.pop(ctx, id), child: Text(name(id))),
                  ],
                  cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                ),
              );
              if (v != null) onChanged(v);
            },
    );
  }
}

class _RssiGaugePainter extends CustomPainter {
  _RssiGaugePainter({required this.rssi, required this.normalized, required this.color, required this.track});
  final int rssi;
  final double normalized;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;

    final bgPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
        math.pi * 0.75, math.pi * 1.5, false, bgPaint);

    final valuePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
        math.pi * 0.75, math.pi * 1.5 * normalized, false, valuePaint);
  }

  @override
  bool shouldRepaint(covariant _RssiGaugePainter old) =>
      old.rssi != rssi || old.normalized != normalized || old.color != color || old.track != track;
}
