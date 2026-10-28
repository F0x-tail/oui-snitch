// SPDX-License-Identifier: MIT
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/gps/gps_types.dart';

import 'package:oui_spy/theme/app_theme.dart';

class StatusBar extends ConsumerStatefulWidget {
  const StatusBar({super.key});

  @override
  ConsumerState<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends ConsumerState<StatusBar> {
  GpsPosition? _gpsPosition;
  StreamSubscription<GpsPosition>? _gpsSub;
  HwGpsState _hwGps = const HwGpsState(
      active: false, satellites: 0, source: GpsSource.phone, inUse: false);
  StreamSubscription<HwGpsState>? _hwGpsSub;
  Timer? _uptimeTimer;

  @override
  void initState() {
    super.initState();
    final gps = ref.read(gpsProvider);
    _gpsPosition = gps.lastPosition;
    _hwGps = gps.hwGps;
    _gpsSub = gps.positionStream.listen((pos) {
      if (mounted) setState(() => _gpsPosition = pos);
    });
    _hwGpsSub = gps.hwGpsStream.listen((s) {
      if (mounted) setState(() => _hwGps = s);
    });
    _uptimeTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _hwGpsSub?.cancel();
    _uptimeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final state = ref.watch(appStateProvider);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          bottom: BorderSide(color: t.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Connection chip
          _ConnectionChip(state: state.connectionState),
          const SizedBox(width: 10),
          // Uptime
          if (state.isConnected && state.sessionStartTime != null) ...[
            _InfoChip(
              icon: Icons.timer_outlined,
              label: _formatUptime(state.sessionUptime),
              color: t.textSecondary,
            ),
            const SizedBox(width: 10),
          ],
          // GPS — crosshair; a plain crosshair when there is a usable fix,
          // a broken crosshair when it is stale/searching or absent.
          _InfoChip(
            icon: (_gpsPosition == null && !_hwGps.inUse)
                ? Icons.gps_off
                : (_gpsColor == AppTheme.warning
                    ? Icons.gps_not_fixed
                    : Icons.gps_fixed),
            label: _gpsLabel,
            color: _gpsColor,
          ),
          const Spacer(),
          // Sync — force a re-read of the board's engine state. Lives here (not
          // in a second row) so the top bar is the single status line; shown
          // only when connected, since there is nothing to sync otherwise.
          if (state.isConnected)
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
              tooltip: 'Sync board state',
              icon: state.isSyncing
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.sync, size: 16, color: AppTheme.accent),
              onPressed: state.isSyncing
                  ? null
                  : () => ref.read(appStateProvider).syncEngineState(),
            ),
          // Device name + node count — tap to switch device
          Flexible(
            child: InkWell(
            onTap: state.isConnected
                ? () async {
                    await ref.read(bleManagerProvider).disconnect();
                    if (context.mounted) context.push('/onboarding');
                  }
                : () => context.push('/onboarding'),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                    state.nodeId.isNotEmpty ? state.nodeId : 'OUI-SNITCH',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: state.isConnected
                          ? AppTheme.accent
                          : t.textDim,
                    ),
                  ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    state.isConnected ? Icons.swap_horiz : Icons.devices,
                    size: 12,
                    color: state.isConnected
                        ? AppTheme.accent
                        : t.textDim,
                  ),
                ],
              ),
            ),
          ),
          ),
        ],
      ),
    );
  }

  String _formatUptime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h${m.toString().padLeft(2, '0')}min';
    final s = d.inSeconds.remainder(60);
    return '${m}min${s.toString().padLeft(2, '0')}s';
  }

  Color get _gpsColor {
    if (_hwGps.inUse) return AppTheme.gpsGood;
    if (_hwGps.fallback) return AppTheme.warning;
    final quality = _gpsPosition?.quality ?? GpsQuality.none;
    return switch (quality) {
      GpsQuality.good => AppTheme.gpsGood,
      GpsQuality.fair => AppTheme.gpsFair,
      GpsQuality.poor => AppTheme.gpsPoor,
      GpsQuality.none => AppTheme.gpsNone,
    };
  }

  String get _gpsLabel {
    if (_hwGps.inUse) return 'HW ${_hwGps.satellites}sv';
    final pos = _gpsPosition;
    if (pos == null) return _hwGps.fallback ? 'PH --' : '--';
    final acc = '${pos.accuracy.toStringAsFixed(0)}m';
    return _hwGps.fallback ? 'PH $acc' : acc;
  }
}


class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.state});
  final NodeConnectionState state;

  @override
  Widget build(BuildContext context) {
    final color = _color;
    final isConnecting = state == NodeConnectionState.connecting ||
        state == NodeConnectionState.negotiating ||
        state == NodeConnectionState.syncing;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isConnecting)
            SizedBox(
              width: 6,
              height: 6,
              child: CircularProgressIndicator(
                color: color,
                strokeWidth: 1.5,
              ),
            )
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          const SizedBox(width: 6),
          Text(
            _label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Color get _color {
    return switch (state) {
      NodeConnectionState.ready => AppTheme.success,
      NodeConnectionState.connecting ||
      NodeConnectionState.negotiating ||
      NodeConnectionState.syncing =>
        AppTheme.warning,
      NodeConnectionState.reconnecting => AppTheme.error,
      _ => AppTheme.textDim,
    };
  }

  String get _label {
    return switch (state) {
      NodeConnectionState.ready => 'Connected',
      NodeConnectionState.connecting => 'Connecting',
      NodeConnectionState.negotiating => 'Setting up',
      NodeConnectionState.syncing => 'Syncing',
      NodeConnectionState.reconnecting => 'Reconnecting',
      NodeConnectionState.scanning => 'Searching',
      _ => 'Not connected',
    };
  }
}


class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
