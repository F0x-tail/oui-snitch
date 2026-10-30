// SPDX-License-Identifier: MIT
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/exposure/exposure_result.dart';
import 'package:oui_spy/theme/app_theme.dart';

/// "What does my phone give away?"
///
/// The board listens to Wi-Fi probe requests while the user switches their
/// phone's Wi-Fi off and on, and reports what the phone called out. Nothing
/// is transmitted by the board, and nothing from the check is stored.
class PhoneLeakScreen extends ConsumerStatefulWidget {
  const PhoneLeakScreen({super.key});

  @override
  ConsumerState<PhoneLeakScreen> createState() => _PhoneLeakScreenState();
}

class _PhoneLeakScreenState extends ConsumerState<PhoneLeakScreen> {
  static const _settings = MethodChannel('io.github.f0xtail.ouisnitch/settings');
  static const _watchSeconds = 15;

  ExposurePhase _phase = ExposurePhase.idle;
  ExposureResult? _result;
  String? _error;
  int _left = 0;
  bool _connected = false;
  StreamSubscription<ExposureUpdate>? _sub;
  StreamSubscription<NodeConnectionState>? _link;
  Timer? _tick;
  Timer? _stall;

  @override
  void initState() {
    super.initState();
    final ble = ref.read(bleManagerProvider);
    _connected = ble.currentConnectionState == NodeConnectionState.ready;
    _link = ble.connectionState.listen((s) {
      if (!mounted) return;
      setState(() => _connected = s == NodeConnectionState.ready);
      final running = _phase == ExposurePhase.baseline || _phase == ExposurePhase.watch;
      if (s != NodeConnectionState.ready && running) _fail('The link to the board dropped.');
    });
  }

  @override
  void dispose() {
    _link?.cancel();
    _sub?.cancel();
    _tick?.cancel();
    _stall?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final ble = ref.read(bleManagerProvider);
    setState(() {
      _phase = ExposurePhase.baseline;
      _result = null;
      _error = null;
    });
    _sub?.cancel();
    _sub = ble.exposureUpdates.listen(_onUpdate);
    _armStall();
    try {
      await ble.startExposureCheck();
    } catch (e) {
      _fail('Could not reach the board: $e');
    }
  }

  // The whole check takes about 21 s; silence well past that means the
  // board did not run it (older firmware, or the link dropped).
  void _armStall() {
    _stall?.cancel();
    _stall = Timer(const Duration(seconds: 30), () {
      if (_phase != ExposurePhase.done) {
        _fail('The board did not answer. It may need a firmware update.');
      }
    });
  }

  void _onUpdate(ExposureUpdate u) {
    if (!mounted) return;
    if (u.phase == ExposurePhase.watch) {
      _armStall();
      _tick?.cancel();
      _left = _watchSeconds;
      _tick = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() => _left = _left > 0 ? _left - 1 : 0);
        if (_left == 0) t.cancel();
      });
    }
    if (u.phase == ExposurePhase.done) {
      _tick?.cancel();
      _stall?.cancel();
    }
    setState(() {
      _phase = u.phase;
      if (u.result != null) _result = u.result;
    });
  }

  void _fail(String msg) {
    _tick?.cancel();
    _stall?.cancel();
    if (!mounted) return;
    setState(() {
      _phase = ExposurePhase.idle;
      _error = msg;
    });
  }

  Future<void> _openWifi() async {
    try {
      await _settings.invokeMethod('openWifiPanel');
    } on PlatformException catch (_) {
      // Nothing to open: the user can use the quick settings tile instead.
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final connected = _connected;
    final running = _phase == ExposurePhase.baseline || _phase == ExposurePhase.watch;
    TextStyle body([Color? c]) => TextStyle(color: c ?? t.textSecondary, fontSize: 14, height: 1.4);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(title: const Text('What does my phone give away?')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'When Wi-Fi is on, your phone calls out to look for networks. Anyone '
            'nearby can read those calls. This check shows what yours says. '
            'The board only listens, and nothing from the check is saved.',
            style: body(),
          ),
          const SizedBox(height: 16),
          if (_phase == ExposurePhase.baseline)
            _Step(
              icon: Icons.hearing,
              title: 'Listening to what is around…',
              text: 'Leave your phone as it is for a few seconds.',
            ),
          if (_phase == ExposurePhase.watch) ...[
            _Step(
              icon: Icons.wifi_off,
              title: 'Now switch Wi-Fi off, then on again ($_left s)',
              text: 'Use the quick settings tile, or the button below. '
                  'Leave it on once it is back.',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openWifi,
              icon: const Icon(Icons.settings),
              label: const Text('Open Wi-Fi settings'),
            ),
          ],
          if (_phase == ExposurePhase.done && _result != null) _ResultView(_result!),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: body(AppTheme.error)),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: connected && !running ? _start : null,
            child: Text(_phase == ExposurePhase.done ? 'Check again' : 'Start'),
          ),
          if (!connected)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Connect to the board first.', style: body(t.textDim)),
            ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppTheme.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(text, style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView(this.r);
  final ExposureResult r;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    TextStyle body([Color? c]) => TextStyle(color: c ?? t.textSecondary, fontSize: 14, height: 1.4);
    TextStyle head = TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600);

    if (!r.found) {
      return _Step(
        icon: Icons.help_outline,
        title: 'No clear signal from your phone',
        text: 'Its calls did not stand out from the other devices around. '
            'Try again somewhere quieter, and switch Wi-Fi off and on while '
            'the countdown runs.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your phone sent ${r.probes} calls', style: head),
        const SizedBox(height: 12),
        if (r.networks.isEmpty)
          _Step(
            icon: Icons.check_circle_outline,
            title: 'It named no networks',
            text: 'Good: it only asked "who is there?", which says nothing '
                'about where you have been.',
          )
        else ...[
          _Step(
            icon: Icons.warning_amber,
            title: 'It called out ${r.networks.length == 1 ? 'a network' : '${r.networks.length} networks'} by name',
            text: 'Anyone nearby can read these, and a network name can show '
                'where you live or work. Phones usually do this only for '
                'hidden networks: make the network visible, or remove it from '
                'the phone if you no longer use it.',
          ),
          const SizedBox(height: 8),
          for (final n in r.networks)
            Padding(
              padding: const EdgeInsets.only(left: 36, bottom: 4),
              child: Text(n, style: TextStyle(color: t.textPrimary, fontFamily: 'monospace')),
            ),
        ],
        const SizedBox(height: 12),
        if (r.factoryAddress)
          _Step(
            icon: Icons.fingerprint,
            title: 'It used its factory address',
            text: 'That address is the same everywhere, so it can follow this '
                'phone from place to place. Turn on the private (randomised) '
                'address in the phone\'s Wi-Fi settings.',
          )
        else if (r.randomAddress)
          _Step(
            icon: Icons.shuffle,
            title: 'It used a randomised address',
            text: 'Good: the address changes, so it does not identify the phone '
                'on its own.',
          ),
        const SizedBox(height: 12),
        Text(
          'A likely match: in a busy place another phone may have called out '
          'at the same moment. Run it again to be sure.',
          style: body(t.textDim),
        ),
      ],
    );
  }
}
