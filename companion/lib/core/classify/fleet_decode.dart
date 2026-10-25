// SPDX-License-Identifier: MIT
import 'dart:convert';
import 'dart:typed_data';

import 'package:oui_spy/core/classify/adv_decoder.dart';
import 'package:oui_spy/core/classify/observation.dart';

class DecodedField {
  final String label;
  final String display;
  final String note;
  final bool live;
  final bool emphasis;
  const DecodedField(this.label, this.display, this.note, {this.live = false, this.emphasis = false});
}

class FleetDecode {
  FleetDecode._();

  static const _len = {'u8': 1, 'i8': 1, 'bool': 1, 'u16': 2, 'i16': 2, 'u24': 3, 'u32': 4, 'i32': 4, 'f32': 4, 'mac': 6};
  static final _rocks = ascii.encode('INTELLI_ROCKS');

  static List<DecodedField> decode(Map<String, dynamic> decode, Observation o) {
    final out = <DecodedField>[];
    final seen = <String>{};
    for (final payload in _payloads(decode, o)) {
      for (final f in (decode['fields'] as List? ?? const []).cast<Map<String, dynamic>>()) {
        final id = f['id'] as String? ?? '';
        if (seen.contains(id) || !_gateOk(f['when'] as Map<String, dynamic>?, payload)) continue;
        final r = _field(f, payload);
        if (r == null || r.display.isEmpty) continue;
        seen.add(id);
        out.add(r);
      }
    }
    return out;
  }

  static List<Uint8List> _payloads(Map<String, dynamic> d, Observation o) {
    final hexes = <String>[];
    switch (d['source']) {
      case 'manufacturerData':
        if (o.kind != RadioKind.ble) return const [];
        final want = (d['companyId'] as num?)?.toInt();
        for (final r in o.mfgRecords) {
          if (want != null && want != 0 && r.companyId != want) continue;
          hexes.add(d['includeCompanyId'] == true
              ? '${(r.companyId & 0xff).toRadixString(16).padLeft(2, '0')}${(r.companyId >> 8).toRadixString(16).padLeft(2, '0')}${r.dataHex}'
              : r.dataHex);
        }
      case 'serviceData':
        final want = uuid16(d['serviceUuid'] as String? ?? '');
        if (want == null) return const [];
        for (final s in o.serviceData) {
          if (uuid16(s.uuid) == want) hexes.add(s.dataHex);
        }
    }
    return [
      for (final h in hexes)
        if (hexToBytes(h) case final b? when _strip(b).isNotEmpty) _strip(b),
    ];
  }

  static Uint8List _strip(Uint8List b) {
    if (b.length <= _rocks.length) return b;
    for (var i = 0; i + _rocks.length <= b.length; i++) {
      var hit = true;
      for (var j = 0; j < _rocks.length && hit; j++) {
        hit = b[i + j] == _rocks[j];
      }
      if (hit) return Uint8List.sublistView(b, 0, i);
    }
    return b;
  }

  static bool _gateOk(Map<String, dynamic>? g, Uint8List p) {
    if (g == null) return true;
    final op = g['op'] as String? ?? 'eq';
    if (op == 'len') {
      final n = (g['length'] as num?)?.toInt() ?? 1;
      if (p.length != (n < 1 ? 1 : n)) return false;
    } else {
      final want = hexToBytes((g['valueHex'] as String? ?? '').replaceFirst(RegExp('^0x', caseSensitive: false), ''));
      if (want == null || want.isEmpty) return _gateOk(g['and'] as Map<String, dynamic>?, p);
      final off = (g['offset'] as num?)?.toInt() ?? 0;
      if (off < 0 || off + want.length > p.length) return false;
      var eq = true, mask = true, nmask = true;
      for (var i = 0; i < want.length; i++) {
        final v = p[off + i], w = want[i];
        if (v != w) eq = false;
        if (v & w != w) mask = false;
        if (v & w != 0) nmask = false;
      }
      final ok = switch (op) { 'eq' => eq, 'neq' => !eq, 'mask' => mask, 'nmask' => nmask, _ => false };
      if (!ok) return false;
    }
    return _gateOk(g['and'] as Map<String, dynamic>?, p);
  }

  static int _readU(Uint8List b, bool le) {
    var v = 0;
    for (var i = 0; i < b.length; i++) {
      v = le ? v | (b[i] << (8 * i)) : (v << 8) | b[i];
    }
    return v;
  }

  static String _num(double n) {
    if (!n.isFinite) return '$n';
    if (n == n.truncateToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  static String _normKey(String raw) {
    final t = raw.trim();
    if (t.toLowerCase().startsWith('0x')) return int.tryParse(t.substring(2), radix: 16)?.toString() ?? t;
    return int.tryParse(t)?.toString() ?? t;
  }

  static DecodedField? _field(Map<String, dynamic> f, Uint8List p) {
    final type = f['type'] as String? ?? 'u8';
    final off = (f['offset'] as num?)?.toInt() ?? 0;
    final len = (f['length'] as num?)?.toInt() ?? _len[type] ?? 1;
    if (off < 0 || len < 1 || off + len > p.length) return null;
    final s = Uint8List.sublistView(p, off, off + len);
    final le = f['endian'] != 'be';
    double? raw;
    String key;
    String text;
    switch (type) {
      case 'utf8':
        text = utf8.decode(s, allowMalformed: true).replaceAll(RegExp(r'^[\x00-\x20]+|[\x00-\x20]+$'), '');
        key = text;
        if (text.isEmpty) return null;
      case 'hex':
        key = [for (final b in s) b.toRadixString(16).padLeft(2, '0').toUpperCase()].join();
        text = [for (final b in s) b.toRadixString(16).padLeft(2, '0').toUpperCase()].join(' ');
      case 'mac':
        text = key = [for (final b in s.take(6)) b.toRadixString(16).padLeft(2, '0').toUpperCase()].join(':');
      case 'bool':
        final on = s.any((b) => b != 0);
        raw = on ? 1 : 0;
        key = on ? '1' : '0';
        text = on ? 'yes' : 'no';
      case 'bits':
        final width = ((f['bitWidth'] as num?)?.toInt() ?? 1).clamp(1, 32);
        final v = (_readU(s, le) >> ((f['bitOffset'] as num?)?.toInt() ?? 0)) & ((1 << width) - 1);
        raw = v.toDouble();
        text = key = '$v';
      case 'f32':
        final f32 = ByteData.sublistView(s).getFloat32(0, le ? Endian.little : Endian.big).toDouble();
        raw = f32;
        key = '$f32';
        text = _num(f32);
      case 'i8' || 'i16' || 'i32':
        final bits = s.length * 8;
        var v = _readU(s, le);
        if (v & (1 << (bits - 1)) != 0) v -= 1 << bits;
        raw = v.toDouble();
        text = key = '$v';
      default:
        final v = _readU(s, le);
        raw = v.toDouble();
        text = key = '$v';
    }
    final scale = (f['scale'] as num?)?.toDouble();
    final add = (f['offsetAdd'] as num?)?.toDouble();
    final mod = (f['modulo'] as num?)?.toDouble();
    if (raw != null && (scale != null || add != null || mod != null)) {
      var n = raw;
      if (mod != null && mod != 0) n %= mod;
      if (scale != null) n *= scale;
      if (add != null) n += add;
      text = _num(n);
    }
    final labels = (f['enum'] as Map?)?.map((k, v) => MapEntry(_normKey('$k'), '$v'));
    final mapped = labels?[_normKey(key)] ?? (raw == null ? null : labels?['${raw.toInt()}']);
    final unit = (f['unit'] as String? ?? '').trim();
    final shown = mapped ?? text;
    final notes = (f['enumNotes'] as Map?)?.map((k, v) => MapEntry(_normKey('$k'), '$v'));
    final live = f['live'] == true;
    return DecodedField(
      f['label'] as String? ?? '',
      unit.isEmpty ? shown : '$shown $unit',
      notes?[_normKey(key)]?.trim() ?? '',
      live: live,
      emphasis: live && ((f['liveEmphasis'] as List?) ?? const []).any((e) => _normKey('$e') == _normKey(key)),
    );
  }
}
