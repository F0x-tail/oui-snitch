import 'dart:convert';

/// Progress and result of the board's "what does my phone give away" check
/// (firmware `exposure.h`). Sent on the system control characteristic as
/// `0x11 phase [result]`.
enum ExposurePhase { idle, baseline, watch, done }

class ExposureResult {
  const ExposureResult({
    required this.found,
    required this.probes,
    required this.randomAddress,
    required this.factoryAddress,
    required this.networks,
  });

  /// A phone's probes rose clearly above the background while the user
  /// switched Wi-Fi off and on. False means no clear signal.
  final bool found;
  final int probes;

  /// The phone probed from a randomised (locally administered) address.
  final bool randomAddress;

  /// The phone probed from its factory address, which identifies it for life.
  final bool factoryAddress;

  /// Network names the phone called out for, readable by anyone nearby.
  final List<String> networks;
}

class ExposureUpdate {
  const ExposureUpdate(this.phase, [this.result]);
  final ExposurePhase phase;
  final ExposureResult? result;

  static const opcode = 0x11;

  /// Decodes a system-control notification, or null if it is not ours.
  static ExposureUpdate? decode(List<int> d) {
    if (d.length < 2 || d[0] != opcode) return null;
    final phase = d[1];
    if (phase < 1 || phase > 3) return null;
    if (phase != 3) return ExposureUpdate(ExposurePhase.values[phase]);
    if (d.length < 7) return null;
    final names = <String>[];
    var o = 7;
    for (var k = 0; k < d[6] && o < d.length; k++) {
      final len = d[o++];
      if (o + len > d.length) break;
      // Probe names are whatever the phone sent; show undecodable bytes
      // rather than fail.
      names.add(utf8.decode(d.sublist(o, o + len), allowMalformed: true));
      o += len;
    }
    return ExposureUpdate(
      ExposurePhase.done,
      ExposureResult(
        found: d[2] == 1,
        probes: d[3] | (d[4] << 8),
        randomAddress: d[5] & 0x01 != 0,
        factoryAddress: d[5] & 0x02 != 0,
        networks: names,
      ),
    );
  }
}
