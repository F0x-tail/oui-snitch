import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Privacy screen (a.k.a. censor) — masks identifiers in the UI only.
///
/// Modelled on ESP32Marauder's "Censor": a shoulder-surfing / screenshot aid,
/// NOT data sanitisation. When on, MACs, SSIDs and device names are masked
/// wherever they are shown on screen. It deliberately does NOT change what is
/// written to the database, exported to CSV, or uploaded to WiGLE — those carry
/// full data, and the setting says so, so it cannot give a false sense of
/// having scrubbed the records.
class PrivacyModeNotifier extends StateNotifier<bool> {
  PrivacyModeNotifier() : super(false) {
    _load();
  }

  static const _key = 'privacy_screen_mode';

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      state = p.getBool(_key) ?? false;
    } catch (_) {/* default off */}
  }

  Future<void> set(bool on) async {
    state = on;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_key, on);
    } catch (_) {}
  }
}

final privacyModeProvider =
    StateNotifierProvider<PrivacyModeNotifier, bool>((ref) => PrivacyModeNotifier());

/// Mask a MAC, keeping only the first two bytes (the OUI portion is already
/// shown as a vendor name, so this reveals nothing new). Matches Marauder's
/// "first two bytes" rule. `enabled` false returns the input unchanged so call
/// sites can stay unconditional.
String maskMac(String mac, bool enabled) {
  if (!enabled) return mac;
  final hex = mac.replaceAll(RegExp('[^0-9a-fA-F]'), '');
  if (hex.length != 12) return 'XX:XX:XX:XX:XX:XX';
  final up = mac.toUpperCase();
  // Preserve the original separators by masking per-byte from byte 3 on.
  final sep = up.contains(':') ? ':' : (up.contains('-') ? '-' : '');
  final b0 = hex.substring(0, 2).toUpperCase();
  final b1 = hex.substring(2, 4).toUpperCase();
  return [b0, b1, 'XX', 'XX', 'XX', 'XX'].join(sep);
}

/// Mask a free-text identifier (SSID or device name), keeping the first three
/// characters, matching Marauder. Short strings keep what they have.
String maskId(String s, bool enabled) {
  if (!enabled || s.isEmpty) return s;
  if (s.length <= 3) return s;
  return s.substring(0, 3) + 'X' * (s.length - 3).clamp(1, 12);
}

@visibleForTesting
String debugMaskPreview(String mac, String name) =>
    '${maskMac(mac, true)} / ${maskId(name, true)}';
