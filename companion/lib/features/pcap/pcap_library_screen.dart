import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/app_time.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

class PcapLibraryScreen extends ConsumerStatefulWidget {
  const PcapLibraryScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  ConsumerState<PcapLibraryScreen> createState() => _PcapLibraryScreenState();
}

class _PcapLibraryScreenState extends ConsumerState<PcapLibraryScreen> {
  late Future<List<_PcapEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  Future<Directory> _pcapDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/pcaps');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<_PcapEntry>> _load() async {
    final d = await _pcapDir();
    final files = await d
        .list()
        .where((e) => e is File && e.path.endsWith('.pcap'))
        .cast<File>()
        .toList();
    final out = <_PcapEntry>[];
    for (final f in files) {
      final st = await f.stat();
      out.add(_PcapEntry(file: f, size: st.size, modified: st.modified));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  void _refresh() {
    setState(() => _entries = _load());
  }

  Future<void> _share(File f) async {
    if (!await f.exists()) return;
    final size = await f.length();
    if (!mounted) return;
    final s = MediaQuery.of(context).size;
    final origin = Rect.fromLTWH(s.width / 2 - 1, s.height / 2 - 1, 2, 2);
    await Share.shareXFiles(
      [XFile(f.path, mimeType: 'application/vnd.tcpdump.pcap')],
      subject: 'OUI-SPY PCAP ($size bytes)',
      sharePositionOrigin: origin,
    );
  }

  bool _isActiveCapture(File f) {
    final ble = ref.read(bleManagerProvider);
    final active = ble.currentPcapFile;
    if (active == null) return false;
    return active.path == f.path;
  }

  Future<bool> _tryDelete(File f) async {
    if (_isActiveCapture(f)) {
      await ref.read(bleManagerProvider).abortActivePcap();
    }
    try {
      if (await f.exists()) await f.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _confirmDelete(File f) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete capture?'),
        content: Text(f.path.split('/').last),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final success = await _tryDelete(f);
    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Delete failed')));
    }
    _refresh();
  }

  Future<void> _confirmDeleteAll() async {
    final list = await _entries;
    if (list.isEmpty) return;
    if (!mounted) return;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete all captures?'),
        content: Text('${list.length} file(s) will be deleted.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (ok != true) return;
    int failed = 0;
    for (final e in list) {
      final ok = await _tryDelete(e.file);
      if (!ok) failed++;
    }
    if (!mounted) return;
    if (failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$failed file(s) could not be deleted')),
      );
    }
    _refresh();
  }

  String _humanBytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(2)}MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Scaffold(
      backgroundColor: t.background,
      body: FutureBuilder<List<_PcapEntry>>(
        future: _entries,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return IosPage(
              title: 'Saved captures',
              slivers: [
                SliverToBoxAdapter(
                  child: IosEmpty(
                    icon: CupertinoIcons.arrow_2_circlepath,
                    title: 'Loading',
                    message: '',
                  ),
                ),
              ],
            );
          }
          final list = snap.data ?? const [];
          return IosPage(
            title: 'Saved captures',
            actions: [
              IosNavButton(
                icon: CupertinoIcons.arrow_2_circlepath,
                tooltip: 'Refresh',
                onPressed: _refresh,
              ),
              if (list.isNotEmpty)
                IosNavButton(
                  icon: CupertinoIcons.trash,
                  tooltip: 'Delete all',
                  onPressed: _confirmDeleteAll,
                ),
            ],
            slivers: [
              if (list.isEmpty)
                SliverToBoxAdapter(
                  child: IosEmpty(
                    icon: CupertinoIcons.tray,
                    title: 'No captures yet',
                    message: 'Captures appear here after a packet capture session.',
                  ),
                )
              else
                IosSliverSection(
                  header: '${list.length} capture${list.length == 1 ? '' : 's'}',
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final e = list[i];
                    final name = e.file.path.split('/').last;
                    final isBle = name.contains('_ble_');
                    final active = _isActiveCapture(e.file);
                    return IosRow(
                      leading: IosIcon(
                        isBle ? Icons.bluetooth : Icons.wifi,
                        isBle ? AppTheme.flockBle : AppTheme.accent,
                      ),
                      title: name,
                      subtitle: Text('${_humanBytes(e.size)} · ${AppTime.dateTimeSeconds(e.modified)}${active ? ' · Live' : ''}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CupertinoButton(padding: EdgeInsets.zero, minimumSize: const Size.square(32), onPressed: () => _share(e.file), child: Icon(CupertinoIcons.share, size: 20, color: t.textPrimary)),
                          CupertinoButton(padding: EdgeInsets.zero, minimumSize: const Size.square(32), onPressed: () => _confirmDelete(e.file), child: const Icon(CupertinoIcons.delete, size: 20, color: AppTheme.error)),
                        ],
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PcapEntry {
  _PcapEntry({required this.file, required this.size, required this.modified});
  final File file;
  final int size;
  final DateTime modified;
}
