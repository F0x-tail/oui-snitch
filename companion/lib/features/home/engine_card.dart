import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/engine_control.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/features/pcap/pcap_stats.dart';
import 'package:oui_spy/features/wardrive/session_launch.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

String engineRoute(Engine e) => switch (e) {
  Engine.detector => '/engine/detector',
  Engine.foxhunter => '/engine/foxhunter',
  Engine.skySpy => '/engine/skyspy',
  Engine.uniPwn => '/engine/unipwn',
  Engine.wardrive => '/wardrive',
  Engine.pcap => '/engine/pcap',
  _ => '',
};

String agoLabel(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 5) return 'just now';
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  return '${diff.inHours}h ago';
}

class EngineRow extends ConsumerStatefulWidget {
  const EngineRow({super.key, required this.engine});

  final Engine engine;

  @override
  ConsumerState<EngineRow> createState() => _EngineRowState();
}

class _EngineRowState extends ConsumerState<EngineRow> {
  bool? _optimistic;

  Engine get e => widget.engine;

  bool _isOn(AppState s, WardriveController wd) {
    if (wd.isActive && (e == Engine.wardrive || wd.ownsEngine(e))) return true;
    return s.isEngineActive(e);
  }

  void _open() {
    final r = engineRoute(e);
    if (r.isNotEmpty) context.push(r);
  }

  void _toggle(bool value) {
    if (e == Engine.wardrive) {
      if (value) {
        unawaited(startWardriveSession(context, ref, requireLocation: false));
      } else {
        ref.read(wardriveProvider).stopSession();
      }
      return;
    }
    final s = ref.read(appStateProvider);
    if (e == Engine.foxhunter && value && (s.foxhunterTarget == null || (s.isManagerConnected && s.foxhunterTargetNodeId == null))) {
      _open();
      return;
    }
    if ((e == Engine.uniPwn || e == Engine.pcap) && value && s.isManagerConnected) {
      _open();
      return;
    }
    setState(() => _optimistic = value);
    setEngineEnabled(ref, e, value, targetNodeId: e == Engine.foxhunter ? s.foxhunterTargetNodeId : null).catchError((Object err) {
      DebugLog.log('ENGINE: toggle ${e.name} -> $value FAILED: $err');
      if (!mounted) return;
      setState(() => _optimistic = null);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('${e.label} ${value ? 'enable' : 'disable'} failed: $err')));
    });
    DebugLog.log('ENGINE: toggle ${e.name} -> $value');
  }

  Future<void> _pickRadio(int current) async {
    final picked = await showCupertinoModalPopup<int>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('${e.label} radio'),
        actions: [
          for (final (v, l) in const [(0x03, 'Wi-Fi and Bluetooth'), (0x01, 'Wi-Fi only'), (0x02, 'Bluetooth only')])
            CupertinoActionSheetAction(
              isDefaultAction: v == current,
              onPressed: () => Navigator.pop(ctx, v),
              child: Text(l),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
    if (picked == null || picked == current) return;
    if (e == Engine.wardrive) {
      setWardriveRadio(ref, picked);
    } else {
      ref.read(appStateProvider).setEngineRadio(e, picked);
    }
  }

  String _state(EngineState s) => switch (s) {
    EngineState.disabled => 'Off',
    EngineState.idle => 'Idle',
    EngineState.scanning => 'Scanning',
    EngineState.active => 'Active',
    EngineState.alerting => 'Alerting',
    EngineState.targetSelected => 'Target set',
    EngineState.connecting => 'Connecting',
    EngineState.exploiting => 'Exploiting',
    EngineState.complete => 'Done',
  };

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final s = ref.watch(appStateProvider);
    final wd = ref.watch(wardriveProvider);
    final live = _isOn(s, wd);
    if (_optimistic != null && _optimistic == live) _optimistic = null;
    final on = _optimistic ?? live;
    final pending = _optimistic != null;
    final count = s.countForEngine(e);
    final rate = s.detectionRate(e);
    final last = s.lastDetectionTime[e];
    final radio = (e == Engine.wardrive && wd.isActive) ? wd.radioBitmask : (s.engineRadio[e] ?? 0x03);
    final radioLocked = on || (e == Engine.wardrive && wd.isActive);

    String what() {
      if (e == Engine.wardrive && wd.isActive) return '${wd.activeLabel} · ${wd.radio.label}';
      if (wd.ownsEngine(e)) return 'Running in the wardrive session';
      if (e == Engine.foxhunter) {
        final target = s.foxhunterTarget;
        if (target == null) return 'Set a target to start';
        final ch = s.foxhunterChannel;
        return 'Target ${target.toUpperCase()}${ch > 0 ? ' · ch $ch' : ''}';
      }
      return e.description;
    }

    final status = [
      pending ? (_optimistic! ? 'Starting…' : 'Stopping…') : _state(s.getEngineState(e)),
      '$count found',
      if (rate > 0) '$rate/min',
      if (last != null) agoLabel(last),
    ].join(' · ');

    return IosRow(
      leading: IosIcon(e.icon, on ? e.color : t.textDim),
      title: e.label,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(what(), maxLines: 2, overflow: TextOverflow.ellipsis),
          Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: on ? e.color : t.textDim, fontWeight: FontWeight.w500)),
          if (e == Engine.pcap) const _AutoPcapLine(),
        ],
      ),
      onTap: _open,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.isDualRadio)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(44, 44),
              onPressed: radioLocked ? null : () => _pickRadio(radio),
              child: Icon(
                switch (radio) {
                  0x01 => CupertinoIcons.wifi,
                  0x02 => CupertinoIcons.bluetooth,
                  _ => CupertinoIcons.antenna_radiowaves_left_right,
                },
                size: 22,
                color: radioLocked ? t.textDim : AppTheme.accent,
                semanticLabel: switch (radio) {
                  0x01 => 'Wi-Fi only',
                  0x02 => 'Bluetooth only',
                  _ => 'Wi-Fi and Bluetooth',
                },
              ),
            ),
          CupertinoSwitch(value: on, activeTrackColor: e.color, onChanged: _toggle),
        ],
      ),
    );
  }
}

class _AutoPcapLine extends ConsumerWidget {
  const _AutoPcapLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ble = ref.read(bleManagerProvider);
    return StreamBuilder<PcapStats>(
      stream: ble.pcapStats,
      initialData: ble.latestPcapStats,
      builder: (context, snap) {
        final s = snap.data ?? PcapStats.empty;
        if (!s.autoEnabled) return const SizedBox.shrink();
        final live = s.autoRemainingMs > 0;
        return Text(
          live ? 'Auto-capture running · ${(s.autoRemainingMs / 1000).ceil()}s left' : 'Auto-capture on detect · ${s.autoDurationSec}s',
          style: TextStyle(color: live ? AppTheme.success : AppTheme.accent, fontWeight: FontWeight.w500),
        );
      },
    );
  }
}
