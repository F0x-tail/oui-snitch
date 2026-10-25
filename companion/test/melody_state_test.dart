// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/melody_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('firmware ops: clear-all first, SET layout, silent has zero notes', () async {
    final s = MelodyState();
    await Future<void>.delayed(Duration.zero);
    final axon = kAlertSlots.firstWhere((e) => e.engine == 0 && e.method == 8);
    final flock = kAlertSlots.firstWhere((e) => e.engine == 1);
    await s.assign(axon, 'lubdub');
    await s.assign(flock, melodySilent);

    final ops = s.serializeForFirmware();
    expect(ops.first, [melodyOpClearAll]);
    expect(ops[1], [melodyOpSet, 0, 8, 2, 72, 6, 4, 67, 11, 3]);
    expect(ops[2], [melodyOpSet, 1, melodyAny, 0]);
    expect(ops.every((o) => o.length <= 32), isTrue);
  });

  test('preview op caps at 8 notes and encodes 10ms units', () {
    final notes = List.generate(10, (i) => const MelodyNote(69, 250, 30));
    final op = MelodyState.previewOp(notes);
    expect(op[0], melodyOpPreview);
    expect(op[1], melodyMaxNotes);
    expect(op.length, 2 + melodyMaxNotes * 3);
    expect(op.sublist(2, 5), [69, 25, 3]);
  });

  test('deleting a melody drops its assignments', () async {
    final s = MelodyState();
    await Future<void>.delayed(Duration.zero);
    await s.saveMelody(Melody(id: 'u1', name: 'x', notes: const [MelodyNote(60, 100, 0)]));
    await s.assign(kAlertSlots.first, 'u1');
    await s.deleteMelody('u1');
    expect(s.assignmentFor(kAlertSlots.first), isNull);
    expect(s.serializeForFirmware().length, 1);
  });
}
