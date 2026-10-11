import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart' show bleManagerProvider;
import 'package:oui_spy/core/db/app_database.dart' show AppDatabase, databaseProvider;
import 'package:oui_spy/core/ignore_list_state.dart';
import 'package:oui_spy/core/export/wigle_csv.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ExportScreen extends StatelessWidget {
  const ExportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Scaffold(
      backgroundColor: t.background,
      body: const IosPage(title: 'Export', slivers: [SliverToBoxAdapter(child: ExportSections())]),
    );
  }
}

class ExportSections extends ConsumerWidget {
  const ExportSections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    final dets = state.recentDetections;
    final withGps = dets.where((d) => d.latitude != null).length;
    final has = dets.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSection(
          header: 'Current session',
          footer: has ? '$withGps of ${dets.length} detections have GPS. KML only includes those.' : 'Nothing to export yet. Detections from this session appear here.',
          children: [
            IosRow(
              leading: const IosIcon(CupertinoIcons.table_fill, AppTheme.wigle),
              title: 'WiGLE CSV',
              subtitle: const Text('Format 1.6, ready to upload to wigle.net'),
              disabled: !has,
              onTap: has ? () => _shareFile(context, WigleCsv.generate(dets, ignoreList: ref.read(ignoreListProvider), board: ref.read(bleManagerProvider).board), 'oui_spy_wigle.csv') : null,
            ),
            IosRow(
              leading: const IosIcon(CupertinoIcons.chevron_left_slash_chevron_right, AppTheme.accent),
              title: 'JSON',
              subtitle: const Text('Every detection with all fields'),
              disabled: !has,
              onTap: has ? () => _shareFile(context, _json(dets), 'oui_spy_detections.json') : null,
            ),
            IosRow(
              leading: const IosIcon(CupertinoIcons.map_fill, AppTheme.gpsGood),
              title: 'KML',
              subtitle: const Text('Google Earth or Maps overlay'),
              disabled: withGps == 0,
              onTap: withGps > 0 ? () => _shareFile(context, _kml(dets), 'oui_spy_detections.kml') : null,
            ),
          ],
        ),
        IosSection(
          header: 'Database',
          footer: 'A backup holds every saved session and detection. Restoring replaces everything on this phone.',
          children: [
            IosRow(
              leading: const IosIcon(CupertinoIcons.cloud_upload_fill, AppTheme.accent),
              title: 'Back up database',
              subtitle: const Text('Save the .db file to Files or iCloud'),
              onTap: () => _backup(context, ref),
            ),
            IosRow(
              leading: const IosIcon(CupertinoIcons.arrow_counterclockwise_circle_fill, AppTheme.warning),
              title: 'Restore from backup',
              subtitle: const Text('Replaces all data on this phone'),
              onTap: () => _restore(context, ref),
            ),
          ],
        ),
      ],
    );
  }

  static String _json(List<Detection> detections) {
    final buf = StringBuffer()..writeln('[');
    for (var i = 0; i < detections.length; i++) {
      final d = detections[i];
      buf.write('  {"mac":"${d.macAddress}","engine":"${d.engine.name}","method":"${d.method}",'
          '"rssi":${d.rssi},"channel":${d.channel},'
          '"timestamp":"${d.appTimestamp.toIso8601String()}"');
      if (d.latitude != null) buf.write(',"lat":${d.latitude},"lon":${d.longitude}');
      if (d.deviceName.isNotEmpty) buf.write(',"name":"${d.deviceName}"');
      if (d.odid?.uavId != null) buf.write(',"uav_id":"${d.odid!.uavId}"');
      buf.write('}');
      if (i < detections.length - 1) buf.writeln(',');
    }
    buf.writeln('\n]');
    return buf.toString();
  }

  static String _kml(List<Detection> detections) {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
      ..writeln('<Document><name>OUI-SPY Detections</name>');
    for (final d in detections.where((d) => d.latitude != null)) {
      buf
        ..writeln('<Placemark>')
        ..writeln('  <name>${d.macAddress}</name>')
        ..writeln('  <description>${d.engine.name} | ${d.method} | ${d.rssi}dBm</description>')
        ..writeln('  <Point><coordinates>${d.longitude},${d.latitude},0</coordinates></Point>')
        ..writeln('</Placemark>');
    }
    buf.writeln('</Document></kml>');
    return buf.toString();
  }

  static Rect _origin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 100, 100);
  }

  static Future<void> _shareFile(BuildContext context, String content, String filename) async {
    final origin = _origin(context);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(content);
    await Share.shareXFiles([XFile(file.path)], subject: 'OUI-SPY Export', sharePositionOrigin: origin);
  }

  static Future<void> _backup(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final origin = _origin(context);
    try {
      final file = await ref.read(databaseProvider).createBackup();
      await Share.shareXFiles([XFile(file.path, mimeType: 'application/x-sqlite3')], subject: 'OUI-SPY Database Backup', sharePositionOrigin: origin);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  static Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    const typeGroup = XTypeGroup(label: 'SQLite DB', extensions: ['db', 'sqlite', 'sqlite3']);
    final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null || file.path.isEmpty) return;
    if (!await AppDatabase.validateBackup(file.path)) {
      messenger.showSnackBar(const SnackBar(content: Text('Not a valid OUI-SPY database backup')));
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Restore this backup?'),
        content: const Text('This replaces every capture, session and setting on this phone with the backup. It cannot be undone.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(databaseProvider).restoreFromFile(file.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      return;
    }
    if (!context.mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Restore complete'),
        content: const Text('Close the app fully and reopen it to load the restored database.'),
        actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }
}
