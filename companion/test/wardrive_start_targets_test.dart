// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/wardrive_state.dart';

void main() {
  group('wardriveTargetsForStart', () {
    test('nothing selected means an unfiltered WiGLE run, not a refusal', () {
      // The wardrive tile carries no selection of its own. Refusing to start
      // would make the tile do nothing at all.
      expect(wardriveTargetsForStart({}), {WardriveTarget.wigle});
    });

    test('a selection made on the map survives a start from the tile', () {
      // The regression this rule replaces: the tile path cleared the selection
      // and forced WiGLE, so choosing a target on the map and then starting
      // from HOME silently dropped it.
      expect(
        wardriveTargetsForStart({WardriveTarget.wigleFlock}),
        {WardriveTarget.wigleFlock},
      );
      expect(
        wardriveTargetsForStart({WardriveTarget.detector, WardriveTarget.drone}),
        {WardriveTarget.detector, WardriveTarget.drone},
      );
    });

    test('does not hand back the caller\'s own set', () {
      // startSession writes the result back into selectedTargets; aliasing
      // would turn that into clearing the set it is copying from.
      final selected = {WardriveTarget.wigle};
      final out = wardriveTargetsForStart(selected);
      expect(out, selected);
      expect(identical(out, selected), isFalse);
    });
  });
}
