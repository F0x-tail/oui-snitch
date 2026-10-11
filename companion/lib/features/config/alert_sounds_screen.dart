import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/melody_state.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

void _preview(WidgetRef ref, List<MelodyNote> notes) {
  ref.read(bleManagerProvider).writeMelodyOps([MelodyState.previewOp(notes)]);
}

Widget _playButton(VoidCallback? onPressed) => CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(44, 44),
      onPressed: onPressed,
      child: const Icon(CupertinoIcons.play_circle, size: 26, semanticLabel: 'Play on board'),
    );

Widget _page(BuildContext context, {required String title, String? back, Widget? trailing, required List<Widget> children}) {
  final t = AppTheme.of(context);
  return CupertinoPageScaffold(
    backgroundColor: t.background,
    navigationBar: CupertinoNavigationBar(
      backgroundColor: t.background.withValues(alpha: 0.92),
      middle: Text(title, style: TextStyle(color: t.textPrimary)),
      previousPageTitle: back,
      trailing: trailing,
    ),
    child: Material(
      color: t.background,
      child: SafeArea(child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 24), children: children)),
    ),
  );
}

Future<T?> _pick<T>(BuildContext context, String title, List<(T, String)> options, T current) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: Text(title),
      actions: [
        for (final (v, label) in options)
          CupertinoActionSheetAction(isDefaultAction: v == current, onPressed: () => Navigator.pop(ctx, v), child: Text(label)),
      ],
      cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
    ),
  );
}

class AlertSoundsScreen extends ConsumerWidget {
  const AlertSoundsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final mel = ref.watch(melodyProvider);
    final supported = ref.read(bleManagerProvider).hasMelodySupport;
    String nameOf(String? id) => id == null ? 'Default' : id == melodySilent ? 'Silent' : (mel.byId(id)?.name ?? 'Default');
    return _page(
      context,
      title: 'Alert sounds',
      back: 'Hardware',
      children: [
        if (!supported)
          const IosSection(children: [
            IosRow(
              leading: IosIcon(CupertinoIcons.exclamationmark_triangle_fill, AppTheme.warning),
              title: 'Firmware has no melody support',
              subtitle: Text('Update the node to use these sounds.'),
            ),
          ]),
        IosSection(
          header: 'Sound for each alert',
          children: [
            for (final slot in kAlertSlots)
              Builder(builder: (context) {
                final current = mel.assignmentFor(slot);
                final melody = current == null ? null : mel.byId(current);
                return IosRow(
                  title: slot.label,
                  detail: Text(nameOf(current), style: TextStyle(color: t.textSecondary, fontSize: 17)),
                  trailing: _playButton(melody == null ? null : () => _preview(ref, melody.notes)),
                  onTap: () async {
                    final v = await _pick<String?>(context, slot.label, [
                      (null, 'Default'),
                      (melodySilent, 'Silent'),
                      for (final m in mel.melodies) (m.id, m.name),
                    ], current);
                    if (v != current) mel.assign(slot, v);
                  },
                );
              }),
          ],
        ),
        IosSection(
          header: 'Melodies',
          footer: 'Swipe a melody you made to delete it.',
          children: [
            for (final m in mel.melodies) _MelodyRow(melody: m),
            IosRow(
              leading: const IosIcon(CupertinoIcons.add, AppTheme.accent),
              title: 'Compose melody',
              chevron: true,
              onTap: () => Navigator.of(context).push(CupertinoPageRoute(builder: (_) => const MelodyComposerScreen())),
            ),
          ],
        ),
      ],
    );
  }
}

class _MelodyRow extends ConsumerWidget {
  const _MelodyRow({required this.melody});

  final Melody melody;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = IosRow(
      title: melody.name,
      subtitle: Text(melody.notes.map((n) => n.label).join(' '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _playButton(() => _preview(ref, melody.notes)),
      onTap: melody.builtIn
          ? null
          : () => Navigator.of(context).push(CupertinoPageRoute(builder: (_) => MelodyComposerScreen(initial: melody))),
    );
    if (melody.builtIn) return row;
    return Dismissible(
      key: ValueKey(melody.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppTheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Text('Delete', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      onDismissed: (_) => ref.read(melodyProvider).deleteMelody(melody.id),
      child: row,
    );
  }
}

class MelodyComposerScreen extends ConsumerStatefulWidget {
  const MelodyComposerScreen({super.key, this.initial});

  final Melody? initial;

  @override
  ConsumerState<MelodyComposerScreen> createState() => _MelodyComposerScreenState();
}

class _MelodyComposerScreenState extends ConsumerState<MelodyComposerScreen> {
  late final TextEditingController _name;
  late List<MelodyNote> _notes;

  static const _durations = [0, 20, 40, 60, 80, 100, 120, 150, 200, 250, 300, 400, 500, 750, 1000];
  static final _pitches = [0, for (var m = 48; m <= 108; m++) m];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? 'My melody');
    _notes = List.of(widget.initial?.notes ?? const [MelodyNote(72, 100, 50)]);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  int _snap(int ms) =>
      _durations.reduce((a, b) => (a - ms).abs() <= (b - ms).abs() ? a : b);

  void _set(int i, {int? midi, int? on, int? gap}) {
    final n = _notes[i];
    setState(() => _notes[i] = MelodyNote(midi ?? n.midi, on ?? n.onMs, gap ?? n.gapMs));
  }

  Future<void> _save() async {
    final name = _name.text.trim().isEmpty ? 'My melody' : _name.text.trim();
    final id = widget.initial?.id ?? 'u${DateTime.now().millisecondsSinceEpoch}';
    await ref.read(melodyProvider).saveMelody(Melody(id: id, name: name, notes: _notes));
    if (mounted) Navigator.of(context).pop();
  }

  Widget _value(String text, VoidCallback onTap) => CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(44, 44),
        onPressed: onTap,
        child: Text(text, style: const TextStyle(color: AppTheme.accent, fontSize: 16)),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final dim = TextStyle(color: t.textDim, fontSize: 15);
    return _page(
      context,
      title: widget.initial == null ? 'New melody' : 'Edit melody',
      back: 'Sounds',
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _notes.isEmpty ? null : _save,
        child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      children: [
        IosSection(header: 'Name', children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: CupertinoTextField(
              controller: _name,
              decoration: null,
              padding: const EdgeInsets.symmetric(vertical: 14),
              style: TextStyle(color: t.textPrimary, fontSize: 17),
            ),
          ),
        ]),
        IosSection(
          header: 'Notes ${_notes.length} of $melodyMaxNotes',
          footer: 'Tap a value to change it. Pitch 0 is a rest.',
          children: [
            for (var i = 0; i < _notes.length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    SizedBox(width: 24, child: Text('${i + 1}', style: dim)),
                    _value(_notes[i].label, () async {
                      final v = await _pick<int>(context, 'Pitch', [for (final p in _pitches) (p, MelodyNote(p, 0, 0).label)], _notes[i].midi);
                      if (v != null) _set(i, midi: v);
                    }),
                    Text('on', style: dim),
                    _value('${_snap(_notes[i].onMs)} ms', () async {
                      final v = await _pick<int>(context, 'Note length', [for (final d in _durations) (d, '$d ms')], _snap(_notes[i].onMs));
                      if (v != null) _set(i, on: v);
                    }),
                    Text('gap', style: dim),
                    _value('${_snap(_notes[i].gapMs)} ms', () async {
                      final v = await _pick<int>(context, 'Gap after', [for (final d in _durations) (d, '$d ms')], _snap(_notes[i].gapMs));
                      if (v != null) _set(i, gap: v);
                    }),
                    const Spacer(),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(44, 44),
                      onPressed: () => setState(() => _notes.removeAt(i)),
                      child: const Icon(CupertinoIcons.minus_circle_fill, color: AppTheme.error, semanticLabel: 'Remove note'),
                    ),
                  ],
                ),
              ),
            if (_notes.length < melodyMaxNotes)
              IosRow(
                leading: const IosIcon(CupertinoIcons.add, AppTheme.accent),
                title: 'Add note',
                onTap: () => setState(() => _notes.add(_notes.isEmpty ? const MelodyNote(72, 100, 50) : _notes.last)),
              ),
            IosRow(
              leading: const IosIcon(CupertinoIcons.play_fill, AppTheme.success),
              title: 'Play on board',
              disabled: _notes.isEmpty,
              onTap: _notes.isEmpty ? null : () => _preview(ref, _notes),
            ),
          ],
        ),
      ],
    );
  }
}
