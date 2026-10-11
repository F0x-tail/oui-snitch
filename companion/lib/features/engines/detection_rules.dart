import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:oui_spy/core/detector_signatures.dart';
import 'package:oui_spy/core/watchlist_state.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

class WatchlistPanel extends ConsumerStatefulWidget {
  const WatchlistPanel({super.key});

  @override
  ConsumerState<WatchlistPanel> createState() => _WatchlistPanelState();
}

class _WatchlistPanelState extends ConsumerState<WatchlistPanel> {
  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final watchlist = ref.watch(watchlistProvider);
    final entries = watchlist.entries;
    final on = entries.where((e) => e.enabled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSection(
          header: 'Watchlist · $on of ${entries.length} on',
          footer: 'The node alerts when it hears any enabled entry. It holds up to 50 MAC/OUI and 50 UUID targets. Swipe left to delete.',
          children: entries.isEmpty
              ? [
                  IosRow(
                    leading: IosIcon(CupertinoIcons.eye_slash, t.textDim),
                    title: 'No targets yet',
                    subtitle: const Text('Add a MAC, OUI or service UUID, or import a list.'),
                  ),
                ]
              : [
                  for (final e in entries)
                    Dismissible(
                      key: ValueKey(watchlistKey(e)),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: AppTheme.error,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(CupertinoIcons.trash, color: Colors.white),
                      ),
                      onDismissed: (_) => ref.read(watchlistProvider).remove(e),
                      child: IosRow(
                        leading: IosIcon(
                          switch (e.matchType) {
                            WatchlistMatchType.fullMac => CupertinoIcons.number,
                            WatchlistMatchType.serviceUuid => CupertinoIcons.bluetooth,
                            WatchlistMatchType.name => CupertinoIcons.textformat,
                            WatchlistMatchType.oui => CupertinoIcons.building_2_fill,
                          },
                          e.enabled ? AppTheme.detector : t.textDim,
                        ),
                        title: e.description.isNotEmpty ? e.description : e.identifier.toUpperCase(),
                        subtitle: Text('${_typeName(e.matchType)} · ${e.identifier.toUpperCase()}'),
                        trailing: CupertinoSwitch(
                          value: e.enabled,
                          activeTrackColor: AppTheme.detector,
                          onChanged: (v) => ref.read(watchlistProvider).toggleEnabled(e, enabled: v),
                        ),
                        onTap: () => _edit(e),
                      ),
                    ),
                ],
        ),
        IosSection(children: [
          IosRow(
            leading: const IosIcon(CupertinoIcons.add, AppTheme.accent),
            title: 'Add target',
            chevron: true,
            onTap: _edit,
          ),
          IosRow(
            leading: const IosIcon(CupertinoIcons.arrow_down_doc_fill, AppTheme.accent),
            title: 'Import list',
            subtitle: const Text('JSON or CSV · OUIs, MACs, UUIDs with descriptions'),
            onTap: _import,
          ),
          IosRow(
            leading: const IosIcon(CupertinoIcons.square_arrow_up, AppTheme.accent),
            title: 'Export list',
            subtitle: const Text('Share as JSON'),
            disabled: entries.isEmpty,
            onTap: entries.isEmpty ? null : _export,
          ),
        ]),
      ],
    );
  }

  static String _typeName(WatchlistMatchType m) => switch (m) {
        WatchlistMatchType.oui => 'OUI prefix',
        WatchlistMatchType.fullMac => 'Full MAC',
        WatchlistMatchType.serviceUuid => 'Service UUID',
        WatchlistMatchType.name => 'Name',
      };

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    const typeGroup = XTypeGroup(
      label: 'Watchlist',
      extensions: ['json', 'csv', 'txt'],
      uniformTypeIdentifiers: ['public.json', 'public.comma-separated-values-text', 'public.plain-text'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    try {
      if (await file.length() > 2 * 1024 * 1024) {
        messenger.showSnackBar(const SnackBar(content: Text('File too large (max 2 MB)')));
        return;
      }
      final wl = ref.read(watchlistProvider);
      final r = await wl.importText(await file.readAsString());
      final total = wl.enabledEntries.where((e) => !e.isName).length;
      messenger.showSnackBar(SnackBar(
        content: Text('Imported ${r.added}, skipped ${r.skipped} (invalid or duplicate)'
            '${total > 50 ? ' · the node holds 50 MAC/OUI and 50 UUID targets' : ''}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<void> _export() async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 100, 100);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/ouispy-watchlist.json');
    await f.writeAsString(ref.read(watchlistProvider).exportJson());
    await Share.shareXFiles([XFile(f.path, mimeType: 'application/json')], subject: 'OUI-SPY Watchlist', sharePositionOrigin: origin);
  }

  void _edit([WatchlistEntry? existing]) {
    Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => _WatchlistEditPage(existing: existing)));
  }
}

class _WatchlistEditPage extends ConsumerStatefulWidget {
  const _WatchlistEditPage({this.existing});
  final WatchlistEntry? existing;

  @override
  ConsumerState<_WatchlistEditPage> createState() => _WatchlistEditPageState();
}

class _WatchlistEditPageState extends ConsumerState<_WatchlistEditPage> {
  late final _id = TextEditingController(text: widget.existing?.identifier ?? '');
  late final _desc = TextEditingController(text: widget.existing?.description ?? '');
  late WatchlistMatchType _type = widget.existing?.matchType ?? WatchlistMatchType.oui;
  late bool _enabled = widget.existing?.enabled ?? true;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _save() {
    final parsed = parseWatchlistImport('${_id.text.trim()},${_desc.text.trim()},${_type.name}');
    if (parsed.entries.isEmpty) {
      setState(() => _error = 'That is not a valid ${_WatchlistPanelState._typeName(_type).toLowerCase()}.');
      return;
    }
    final wl = ref.read(watchlistProvider);
    final e = parsed.entries.first..enabled = _enabled;
    if (wl.entries.any((x) => !identical(x, widget.existing) && watchlistKey(x) == watchlistKey(e))) {
      setState(() => _error = 'This target is already on the watchlist.');
      return;
    }
    if (widget.existing == null) {
      wl.add(e);
    } else {
      wl.update(widget.existing!, e);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final field = TextStyle(color: t.textPrimary, fontSize: 17);
    return Scaffold(
      backgroundColor: t.background,
      body: Column(children: [
        CupertinoNavigationBar(
          backgroundColor: t.background.withValues(alpha: 0.92),
          border: Border(bottom: BorderSide(color: t.border, width: 0.5)),
          transitionBetweenRoutes: false,
          leading: CupertinoButton(padding: EdgeInsets.zero, onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          middle: Text(widget.existing == null ? 'Add target' : 'Edit target', style: TextStyle(color: t.textPrimary)),
          trailing: CupertinoButton(padding: EdgeInsets.zero, onPressed: _save, child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600))),
        ),
        Expanded(
          child: ListView(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: IosSegments<WatchlistMatchType>(
                value: _type,
                segments: const {
                  WatchlistMatchType.oui: 'OUI',
                  WatchlistMatchType.fullMac: 'MAC',
                  WatchlistMatchType.serviceUuid: 'UUID',
                },
                onChanged: (v) => setState(() {
                  _type = v;
                  _error = null;
                }),
              ),
            ),
            IosSection(
              footer: _error ??
                  switch (_type) {
                    WatchlistMatchType.oui => 'The first 3 bytes of a MAC, e.g. 00:25:DF. Matches every device from that maker.',
                    WatchlistMatchType.fullMac => 'One exact device, e.g. AA:BB:CC:DD:EE:FF.',
                    WatchlistMatchType.serviceUuid => 'A 16-bit Bluetooth service UUID, e.g. FD5F.',
                    WatchlistMatchType.name => 'Text the device name contains.',
                  },
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: CupertinoTextField(
                    controller: _id,
                    placeholder: switch (_type) {
                      WatchlistMatchType.oui => 'AA:BB:CC',
                      WatchlistMatchType.fullMac => 'AA:BB:CC:DD:EE:FF',
                      WatchlistMatchType.serviceUuid => 'FD5F',
                      WatchlistMatchType.name => 'Device name',
                    },
                    autocorrect: false,
                    style: field.copyWith(fontFamily: 'monospace'),
                    placeholderStyle: TextStyle(color: t.textDim, fontSize: 17),
                    decoration: null,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: CupertinoTextField(
                    controller: _desc,
                    placeholder: 'Name shown in alerts, e.g. Flock, Axon, My tracker',
                    style: field,
                    placeholderStyle: TextStyle(color: t.textDim, fontSize: 17),
                    decoration: null,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
            ),
            IosSection(children: [
              IosRow(
                title: 'Enabled',
                trailing: CupertinoSwitch(value: _enabled, activeTrackColor: AppTheme.detector, onChanged: (v) => setState(() => _enabled = v)),
              ),
            ]),
            if (widget.existing != null)
              IosSection(children: [
                IosRow(
                  leading: const IosIcon(CupertinoIcons.trash_fill, AppTheme.error),
                  title: 'Delete target',
                  onTap: () {
                    ref.read(watchlistProvider).remove(widget.existing!);
                    Navigator.of(context).pop();
                  },
                ),
              ]),
          ]),
        ),
      ]),
    );
  }
}

class SignaturesPanel extends ConsumerWidget {
  const SignaturesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final sigMask = ref.watch(detectorSigMaskProvider);
    return IosSection(
      header: 'Threat signatures',
      footer: 'These run on the node with the Detector engine. Each match appears in Live under its name.',
      children: [
        for (final s in detectorSignatures)
          IosRow(
            leading: IosIcon(s.icon, (sigMask & s.bit) != 0 ? AppTheme.detector : t.textDim),
            title: s.label,
            subtitle: Text(s.desc),
            trailing: CupertinoSwitch(
              value: (sigMask & s.bit) != 0,
              activeTrackColor: AppTheme.detector,
              onChanged: (v) => ref.read(detectorSigMaskProvider.notifier).setBit(s.bit, v),
            ),
          ),
      ],
    );
  }
}
