import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/notifications/class_alerts.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';
import 'package:oui_spy/features/config/widgets/config_widgets.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

class NotificationSettingsBody extends ConsumerWidget {
  const NotificationSettingsBody({super.key, this.shrinkWrap = false, this.physics});

  final bool shrinkWrap;
  final ScrollPhysics? physics;

  static IconData _classIcon(ClassAlert a) => switch (a) {
        ClassAlert.cameras => Icons.videocam_outlined,
        ClassAlert.lawEnforcement => Icons.local_police_outlined,
        ClassAlert.drones => Icons.flight,
        ClassAlert.glasses => Icons.visibility_outlined,
        ClassAlert.trackers => Icons.sell_outlined,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notif = ref.watch(notificationServiceProvider);
    final catalog = ref.watch(deviceRegistryProvider.select((r) => r.catalog));
    final t = AppTheme.of(context);

    return ListView(
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding: const EdgeInsets.only(top: 8),
      children: [
        if (!notif.permissionGranted)
          IosSection(
            footer: 'Allow notifications for OUI-SPY in iOS Settings.',
            children: [
              IosRow(
                leading: const IosIcon(CupertinoIcons.bell_slash_fill, AppTheme.warning),
                title: 'Notifications are off',
                trailing: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(44, 44),
                  onPressed: () => notif.init(),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        IosSection(header: 'Detection alerts', children: [
          ConfigToggleRow(
            icon: Icons.videocam,
            label: 'Flock Safety',
            subtitle: 'New camera detected',
            color: AppTheme.flockWifi,
            value: notif.flockEnabled,
            onChanged: notif.setFlockEnabled,
          ),
          ConfigToggleRow(
            icon: Icons.radar,
            label: 'Watchlist',
            subtitle: 'A watched address is seen',
            color: AppTheme.detector,
            value: notif.detectorEnabled,
            onChanged: notif.setDetectorEnabled,
          ),
          ConfigToggleRow(
            icon: Icons.flight,
            label: 'Drones',
            subtitle: 'Remote ID broadcast received',
            color: AppTheme.skySpy,
            value: notif.droneEnabled,
            onChanged: notif.setDroneEnabled,
          ),
          ConfigToggleRow(
            icon: Icons.gps_fixed,
            label: 'Foxhunt proximity',
            subtitle: 'Target signal crosses a threshold',
            color: AppTheme.success,
            value: notif.foxhuntEnabled,
            onChanged: notif.setFoxhuntEnabled,
          ),
        ]),
        IosSection(
          header: 'Alert on device type',
          footer: 'Alerts when any nearby device is classified as one of these. No watchlist entry needed.',
          children: [
            for (final a in ClassAlert.values) ...[
              ConfigToggleRow(
                icon: _classIcon(a),
                label: a.label,
                color: AppTheme.accent,
                value: notif.classAlerts.contains(a),
                onChanged: (v) => notif.setClassAlert(a, v),
              ),
              if (notif.classAlerts.contains(a))
                Builder(builder: (context) {
                  final sigs = [for (final s in catalog) if (a.kinds.contains(s.kind)) s];
                  if (sigs.isEmpty) return const SizedBox.shrink();
                  final on = sigs.where((s) => !notif.mutedSignatures.contains(s.id)).length;
                  return IosRow(
                    leading: const SizedBox(width: 30),
                    title: 'Choose types',
                    detail: Text('$on of ${sigs.length}', style: TextStyle(color: t.textSecondary, fontSize: 17)),
                    chevron: true,
                    onTap: () => Navigator.of(context).push(CupertinoPageRoute(builder: (_) => _SignatureAlertsPage(alert: a))),
                  );
                }),
            ],
          ],
        ),
        IosSection(header: 'Wardrive', children: [
          ConfigToggleRow(
            icon: Icons.emoji_events,
            label: 'Milestones',
            subtitle: 'Every 1,000 new networks',
            color: AppTheme.warning,
            value: notif.milestoneAlertsEnabled,
            onChanged: notif.setMilestoneAlertsEnabled,
          ),
        ]),
        IosSection(header: 'Limits', children: [
          ConfigSliderRow(
            icon: Icons.timer,
            label: 'Repeat a device after',
            valueLabel: _formatCooldown(notif.cooldownSeconds),
            min: 30,
            max: 1800,
            divisions: 59,
            value: notif.cooldownSeconds.toDouble(),
            onChanged: (v) => notif.setCooldownSeconds(v.round()),
          ),
          ConfigSliderRow(
            icon: Icons.speed,
            label: 'Most alerts per minute',
            valueLabel: '${notif.maxPerMinute}',
            min: 1,
            max: 30,
            divisions: 29,
            value: notif.maxPerMinute.toDouble(),
            onChanged: (v) => notif.setMaxPerMinute(v.round()),
          ),
        ]),
        IosSection(header: 'Delivery', children: [
          ConfigToggleRow(
            icon: Icons.volume_up,
            label: 'Sound',
            color: AppTheme.error,
            value: notif.soundEnabled,
            onChanged: notif.setSoundEnabled,
          ),
          ConfigToggleRow(
            icon: Icons.vibration,
            label: 'Vibration',
            color: AppTheme.detector,
            value: notif.vibrationEnabled,
            onChanged: notif.setVibrationEnabled,
          ),
        ]),
      ],
    );
  }

  static String _formatCooldown(int seconds) {
    if (seconds < 60) return '$seconds s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '$m min $s s' : '$m min';
  }
}

class _SignatureAlertsPage extends ConsumerWidget {
  const _SignatureAlertsPage({required this.alert});

  final ClassAlert alert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final notif = ref.watch(notificationServiceProvider);
    final catalog = ref.watch(deviceRegistryProvider.select((r) => r.catalog));
    final sigs = [for (final s in catalog) if (alert.kinds.contains(s.kind)) s]
      ..sort((x, y) => x.name.toLowerCase().compareTo(y.name.toLowerCase()));
    return CupertinoPageScaffold(
      backgroundColor: t.background,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: t.background.withValues(alpha: 0.92),
        middle: Text(alert.label, style: TextStyle(color: t.textPrimary)),
        previousPageTitle: 'Alerts',
      ),
      child: Material(
        color: t.background,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [
              IosSection(
                footer: 'Turn off a device type to stop its alerts. It is still detected and logged.',
                children: [
                  for (final s in sigs)
                    IosRow(
                      title: s.name,
                      trailing: CupertinoSwitch(
                        value: !notif.mutedSignatures.contains(s.id),
                        activeTrackColor: AppTheme.accent,
                        onChanged: (v) => notif.setSignatureAlert(s.id, v),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
