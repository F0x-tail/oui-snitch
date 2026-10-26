// SPDX-License-Identifier: MIT
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/wardrive_state.dart';
// A core helper reaching into a feature, knowingly: starting a wardrive needs
// permission dialogs, which need a BuildContext, so the one start path has to
// live with the UI. Pointing here keeps it the *only* path.
import 'package:oui_spy/features/wardrive/session_launch.dart';

/// Turn an engine on or off.
///
/// Takes a [BuildContext] because the wardrive engine is a session, and
/// starting a session may need to ask the user something. Requiring it of
/// every caller is what stops a new screen from quietly acquiring a second,
/// dialog-free way to start a wardrive — which is exactly how the two start
/// paths diverged before.
Future<void> setEngineEnabled(BuildContext context, WidgetRef ref, Engine e, bool on,
    {String? targetNodeId, bool requireLocation = true, String origin = 'unknown'}) async {
  final wd = ref.read(wardriveProvider);
  // The wardrive tile IS the session control. Turning it on starts a wardrive
  // session (GPS track + WiGLE CSV); turning it off stops it. Every other tile
  // just enables its engine — those detections are still recorded to the
  // database, under an ambient session, but produce no WiGLE output.
  if (e == Engine.wardrive) {
    if (on) {
      await startWardriveSession(context, ref,
          requireLocation: requireLocation, origin: origin);
      return;
    }
    return stopWardriveSession(ref, origin: origin);
  }
  if (!on && wd.ownsEngine(e)) return wd.stopOwnedEngine(e);
  final app = ref.read(appStateProvider);
  final ble = ref.read(bleManagerProvider);
  if (on) {
    await ble.enableEngine(e, targetNodeId: targetNodeId, radio: app.engineRadio[e]);
  } else {
    if (e == Engine.foxhunter) app.endFoxhuntLiveActivity();
    await ble.disableEngine(e, targetNodeId: targetNodeId);
  }
}
