import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/wardrive_state.dart';

Future<void> setEngineEnabled(WidgetRef ref, Engine e, bool on, {String? targetNodeId}) async {
  final wd = ref.read(wardriveProvider);
  // The wardrive tile IS the session control. Turning it on starts a wardrive
  // session (GPS track + WiGLE CSV); turning it off stops it. Every other tile
  // just enables its engine — those detections are still recorded to the
  // database, under an ambient session, but produce no WiGLE output.
  if (e == Engine.wardrive) {
    return on ? wd.startWardriveTile() : wd.stopSession();
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
