// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';
import 'package:oui_spy/features/config/widgets/config_widgets.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/core/detection_icon.dart';

class NotificationSettingsBody extends ConsumerWidget {
  const NotificationSettingsBody({super.key, this.shrinkWrap = false, this.physics});

  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notif = ref.watch(notificationServiceProvider);
    final t = AppTheme.of(context);

    return ListView(
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (!notif.permissionGranted)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.warning.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: AppTheme.warning, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Notification permission not granted. Enable in system settings.',
                    style: TextStyle(color: AppTheme.warning, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => notif.init(),
                  child: Text('Retry', style: TextStyle(
                    color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w700,
                  )),
                ),
              ],
            ),
          ),

        const ConfigSectionHeader(label: 'Foxhunt'),
        ConfigToggleRow(
          icon: Icons.gps_fixed,
          label: 'Foxhunt Proximity',
          subtitle: 'Alert when target signal crosses thresholds',
          color: AppTheme.success,
          value: notif.foxhuntEnabled,
          onChanged: notif.setFoxhuntEnabled,
        ),

        const SizedBox(height: 16),
        const ConfigSectionHeader(label: 'Wardrive'),
        ConfigToggleRow(
          icon: Icons.emoji_events,
          label: 'Milestone Alerts',
          subtitle: 'Notify every 1000 unique networks',
          color: AppTheme.accent,
          value: notif.milestoneAlertsEnabled,
          onChanged: notif.setMilestoneAlertsEnabled,
        ),

        const SizedBox(height: 16),
        const ConfigSectionHeader(label: 'Silence these'),
        // Per-method muting. The firmware groups probe requests and evil-twin
        // beacons under one signature bit, so switching the signature off to
        // stop probe spam would also stop rogue-AP detection. These mute the
        // notification only — detection and logging continue.
        for (final m in _mutableMethods)
          ConfigToggleRow(
            icon: detectorMethodIcon(m.$1),
            label: m.$2,
            subtitle: notif.isMethodMuted(m.$1)
                ? 'Logged, never alerts'
                : 'Alerts normally',
            color: AppTheme.detector,
            value: notif.isMethodMuted(m.$1),
            onChanged: (v) => notif.setMethodMuted(m.$1, v),
          ),

        const SizedBox(height: 16),
        const ConfigSectionHeader(label: 'Behavior'),
        ConfigSliderRow(
          icon: Icons.filter_alt,
          label: 'Alert filter',
          valueLabel: _confidenceLabel(notif.minConfidence),
          min: 0,
          max: 3,
          divisions: 3,
          value: notif.minConfidence.toDouble(),
          onChanged: (v) => notif.setMinConfidence(v.round()),
        ),
        ConfigSliderRow(
          icon: Icons.timer,
          label: 'Cooldown per device',
          valueLabel: _formatCooldown(notif.cooldownSeconds),
          min: 30,
          max: 1800,
          divisions: 59,
          value: notif.cooldownSeconds.toDouble(),
          onChanged: (v) => notif.setCooldownSeconds(v.round()),
        ),
        ConfigSliderRow(
          icon: Icons.speed,
          label: 'Max alerts per minute',
          valueLabel: '${notif.maxPerMinute}',
          min: 1,
          max: 30,
          divisions: 29,
          value: notif.maxPerMinute.toDouble(),
          onChanged: (v) => notif.setMaxPerMinute(v.round()),
        ),

        const SizedBox(height: 16),
        const ConfigSectionHeader(label: 'Output'),
        ConfigToggleRow(
          icon: Icons.volume_up,
          label: 'Sound',
          subtitle: 'Play alert sound',
          color: t.textSecondary,
          value: notif.soundEnabled,
          onChanged: notif.setSoundEnabled,
        ),
        ConfigToggleRow(
          icon: Icons.vibration,
          label: 'Vibration',
          subtitle: 'Haptic feedback on alert',
          color: t.textSecondary,
          value: notif.vibrationEnabled,
          onChanged: notif.setVibrationEnabled,
        ),
      ],
    );
  }

  static /// Detector methods a user may reasonably want logged but silent.
///
/// `probe_ssid` is the noisy one and is muted by default. `evil_twin` sits on
/// the SAME firmware signature bit, which is why muting has to happen here
/// rather than by switching the signature off.
const _mutableMethods = <(String, String)>[
  ('probe_ssid', 'Probe requests'),
  ('evil_twin', 'Rogue AP / evil twin'),
  ('deauth_storm', 'Deauth floods'),
  ('mesh', 'Mesh nodes'),
  ('camera', 'Cameras'),
  ('stream', 'Streaming devices'),
  ('tracker', 'Trackers'),
];

String _confidenceLabel(int c) {
    switch (c) {
      case 0:
        return 'Everything';
      case 1:
        return 'Suspected +';
      case 2:
        return 'High +';
      default:
        return 'Verified only';
    }
  }

  static String _formatCooldown(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }
}
