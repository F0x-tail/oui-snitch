import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path_provider/path_provider.dart';

class DebugLog {
  DebugLog._();
  static IOSink? _sink;
  static bool _ready = false;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/oui_spy.log');
      _sink = file.openWrite(mode: FileMode.append);
      _ready = true;
      log('=== OUI-SPY started ===');
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[LOG] Failed to init file logger: $e');
      }
    }
  }

  static void log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final line = '[$ts] $msg';
    // Debug builds only. These lines carry MAC addresses, SSIDs and node IDs,
    // and logcat is readable by anything holding READ_LOGS or by adb. The file
    // sink below stays on: it lives in app-private storage and is the log the
    // user can deliberately export.
    if (kDebugMode) {
      // ignore: avoid_print
      print(line);
    }
    if (_ready && _sink != null) {
      _sink!.writeln(line);
    }
  }

  static void dispose() {
    _sink?.close();
  }
}
