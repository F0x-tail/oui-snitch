import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/engine_control.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

class UnipwnScreen extends ConsumerStatefulWidget {
  const UnipwnScreen({super.key});

  @override
  ConsumerState<UnipwnScreen> createState() => _UnipwnScreenState();
}

class _UnipwnScreenState extends ConsumerState<UnipwnScreen> {
  final Map<String, Detection> _robots = {};
  String? _selectedTarget;
  String? _selectedNode;
  final _customCmdController = TextEditingController();
  StreamSubscription<Detection>? _sub;

  @override
  void initState() {
    super.initState();
    final ble = ref.read(bleManagerProvider);
    _sub = ble.detections.listen((d) {
      if (d.engine != Engine.uniPwn || !mounted) return;
      setState(() => _robots[d.macAddress] = d);
    });
  }

  void _toggleEngine(bool enable) {
    final st = ref.read(appStateProvider);
    final node = st.isManagerConnected ? _selectedNode : null;
    if (enable && st.isManagerConnected && node == null) return;
    setEngineEnabled(ref, Engine.uniPwn, enable, targetNodeId: node);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _customCmdController.dispose();
    super.dispose();
  }

  void _sendCommand(int type, {String payload = ''}) {
    if (_selectedTarget == null) return;
    final ble = ref.read(bleManagerProvider);
    ble.sendUnipwnCommand(
      targetMac: _selectedTarget!,
      commandType: type,
      payload: payload,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final state = ref.watch(appStateProvider);
    final isActive = state.isEngineActive(Engine.uniPwn);
    final robots = _robots.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: 'UniPwn',
        leading: CupertinoNavigationBarBackButton(
          color: AppTheme.accent,
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: IosSection(
              footer: 'Scans for Unitree robots over Bluetooth and sends control commands.',
              children: [
                IosRow(
                  leading: const IosIcon(Icons.smart_toy, AppTheme.uniPwn),
                  title: 'UniPwn',
                  subtitle: Text(isActive ? 'Scanning' : 'Off'),
                  trailing: CupertinoSwitch(
                    value: isActive,
                    activeTrackColor: AppTheme.uniPwn,
                    onChanged: _toggleEngine,
                  ),
                ),
                if (state.isManagerConnected)
                  _UnipwnNodePicker(
                    selected: _selectedNode,
                    enabled: !isActive,
                    onChanged: (v) => setState(() => _selectedNode = v),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: IosSection(
              header: 'Targets',
              children: [
                if (robots.isEmpty)
                  IosRow(
                    leading: IosIcon(Icons.smart_toy, t.textDim),
                    title: isActive ? 'Scanning for robots' : 'Enable to start scanning',
                  )
                else
                  for (final r in robots)
                    IosRow(
                      leading: IosIcon(
                        Icons.smart_toy,
                        _selectedTarget == r.macAddress ? AppTheme.uniPwn : t.textSecondary,
                      ),
                      title: r.unipwn?.robotType ?? 'Unknown',
                      subtitle: Text('${r.macAddress.toUpperCase()} · ${r.rssi} dBm'),
                      trailing: _selectedTarget == r.macAddress
                          ? const Icon(CupertinoIcons.check_mark, size: 20, color: AppTheme.accent)
                          : null,
                      onTap: () => setState(() => _selectedTarget = r.macAddress),
                    ),
              ],
            ),
          ),
          if (_selectedTarget != null) ...[
            SliverToBoxAdapter(
              child: IosSection(
                header: 'Commands',
                footer: 'Target: ${_selectedTarget!.toUpperCase()}',
                children: [
                  IosRow(
                    leading: const IosIcon(Icons.terminal, AppTheme.uniPwn),
                    title: 'Enable SSH',
                    onTap: () => _sendCommand(0),
                  ),
                  IosRow(
                    leading: const IosIcon(Icons.key, AppTheme.uniPwn),
                    title: 'Change root password',
                    onTap: () => _sendCommand(1),
                  ),
                  IosRow(
                    leading: const IosIcon(Icons.numbers, AppTheme.uniPwn),
                    title: 'Get serial number',
                    onTap: () => _sendCommand(2),
                  ),
                  IosRow(
                    leading: const IosIcon(Icons.info_outline, AppTheme.uniPwn),
                    title: 'Get system info',
                    onTap: () => _sendCommand(4),
                  ),
                  IosRow(
                    leading: const IosIcon(Icons.restart_alt, AppTheme.warning),
                    title: 'Reboot',
                    onTap: () => _sendCommand(3),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: IosSection(
                header: 'Custom command',
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: CupertinoTextField(
                            controller: _customCmdController,
                            placeholder: 'Shell command',
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: null,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 15),
                            placeholderStyle: TextStyle(color: t.textDim, fontFamily: 'monospace', fontSize: 15),
                          ),
                        ),
                        const SizedBox(width: 12),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          color: AppTheme.error,
                          minimumSize: Size.zero,
                          borderRadius: BorderRadius.circular(8),
                          onPressed: () => _sendCommand(5, payload: _customCmdController.text),
                          child: const Text('Run', style: TextStyle(color: CupertinoColors.white, fontSize: 15)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UnipwnNodePicker extends ConsumerWidget {
  const _UnipwnNodePicker({
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
        title: 'Run from',
        detail: Text('No nodes seen yet', style: TextStyle(color: t.textDim, fontSize: 17)),
      );
    }
    final current = nodes.contains(selected) ? selected : null;
    return IosRow(
      leading: const IosIcon(CupertinoIcons.device_laptop, AppTheme.accent),
      title: 'Run from',
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
                  title: const Text('Run from which node?'),
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
    );
  }
}
