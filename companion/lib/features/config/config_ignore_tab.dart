part of 'device_config.dart';

class _IgnoreListTab extends ConsumerWidget {
  const _IgnoreListTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final entries = ref.watch(ignoreListProvider).entries;
    final active = entries.where((e) => e.enabled).length;
    return ListView(children: [
      IosSection(
        header: 'Ignored · $active of ${entries.length} on',
        footer: 'Matching devices are left out of the feed, exports, the database and alerts. Swipe left to delete.',
        children: entries.isEmpty
            ? [
                IosRow(
                  leading: IosIcon(CupertinoIcons.nosign, t.textDim),
                  title: 'Nothing ignored',
                  subtitle: const Text('Add your own router, phone or car so they never show up.'),
                ),
              ]
            : [for (final e in entries) _IgnoreEntryTile(entry: e)],
      ),
      IosSection(children: [
        IosRow(
          leading: const IosIcon(CupertinoIcons.add, AppTheme.accent),
          title: 'Add entry',
          chevron: true,
          onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => const _IgnoreAddPage())),
        ),
      ]),
    ]);
  }
}

class _IgnoreAddPage extends ConsumerStatefulWidget {
  const _IgnoreAddPage();

  @override
  ConsumerState<_IgnoreAddPage> createState() => _IgnoreAddPageState();
}

class _IgnoreAddPageState extends ConsumerState<_IgnoreAddPage> {
  final _value = TextEditingController();
  final _label = TextEditingController();
  IgnoreType _type = IgnoreType.ssid;
  IgnoreScope _scope = IgnoreScope.both;

  @override
  void dispose() {
    _value.dispose();
    _label.dispose();
    super.dispose();
  }

  void _save() {
    final raw = _value.text.trim();
    if (raw.isEmpty) return;
    ref.read(ignoreListProvider).add(IgnoreEntry(
          type: _type,
          value: IgnoreEntry.normalize(_type, raw),
          scope: _scope,
          label: _label.text.trim(),
        ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Scaffold(
      backgroundColor: t.background,
      body: Column(children: [
        CupertinoNavigationBar(
          backgroundColor: t.background.withValues(alpha: 0.92),
          border: Border(bottom: BorderSide(color: t.border, width: 0.5)),
          transitionBetweenRoutes: false,
          leading: CupertinoButton(padding: EdgeInsets.zero, onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          middle: Text('Ignore a device', style: TextStyle(color: t.textPrimary)),
          trailing: CupertinoButton(padding: EdgeInsets.zero, onPressed: _save, child: const Text('Add', style: TextStyle(fontWeight: FontWeight.w600))),
        ),
        Expanded(
          child: ListView(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: IosSegments<IgnoreType>(
                value: _type,
                segments: const {IgnoreType.ssid: 'Wi-Fi name', IgnoreType.mac: 'MAC', IgnoreType.oui: 'OUI'},
                onChanged: (v) => setState(() => _type = v),
              ),
            ),
            IosSection(
              footer: switch (_type) {
                IgnoreType.ssid => 'Exact network name, e.g. MyHomeNetwork.',
                IgnoreType.mac => 'One exact device, e.g. AA:BB:CC:DD:EE:FF.',
                IgnoreType.oui => 'Every device from one maker, e.g. AA:BB:CC.',
              },
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: CupertinoTextField(
                    controller: _value,
                    placeholder: switch (_type) {
                      IgnoreType.ssid => 'MyHomeNetwork',
                      IgnoreType.mac => 'AA:BB:CC:DD:EE:FF',
                      IgnoreType.oui => 'AA:BB:CC',
                    },
                    autocorrect: false,
                    textCapitalization: _type == IgnoreType.ssid ? TextCapitalization.none : TextCapitalization.characters,
                    style: TextStyle(color: t.textPrimary, fontSize: 17, fontFamily: _type == IgnoreType.ssid ? null : 'monospace'),
                    placeholderStyle: TextStyle(color: t.textDim, fontSize: 17),
                    decoration: null,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: CupertinoTextField(
                    controller: _label,
                    placeholder: 'Label (optional), e.g. Home router',
                    style: TextStyle(color: t.textPrimary, fontSize: 17),
                    placeholderStyle: TextStyle(color: t.textDim, fontSize: 17),
                    decoration: null,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
            ),
            const ConfigSectionHeader(label: 'Applies to'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: IosSegments<IgnoreScope>(
                value: _scope,
                segments: {for (final s in IgnoreScope.values) s: s.label},
                onChanged: (v) => setState(() => _scope = v),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _IgnoreEntryTile extends ConsumerWidget {
  const _IgnoreEntryTile({required this.entry});
  final IgnoreEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final value = entry.type == IgnoreType.ssid ? entry.value : entry.value.toUpperCase();
    return Dismissible(
      key: ValueKey('${entry.type.name}:${entry.value}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppTheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(CupertinoIcons.trash, color: Colors.white),
      ),
      onDismissed: (_) => ref.read(ignoreListProvider).remove(entry),
      child: IosRow(
        leading: IosIcon(
          switch (entry.type) {
            IgnoreType.ssid => CupertinoIcons.wifi,
            IgnoreType.mac => CupertinoIcons.number,
            IgnoreType.oui => CupertinoIcons.building_2_fill,
          },
          entry.enabled ? AppTheme.accent : t.textDim,
        ),
        title: entry.label.isNotEmpty ? entry.label : value,
        subtitle: Text([entry.type.label, if (entry.label.isNotEmpty) value, entry.scope.label].join(' · ')),
        trailing: CupertinoSwitch(
          value: entry.enabled,
          activeTrackColor: AppTheme.accent,
          onChanged: (v) => ref.read(ignoreListProvider).toggleEnabled(entry, enabled: v),
        ),
      ),
    );
  }
}
