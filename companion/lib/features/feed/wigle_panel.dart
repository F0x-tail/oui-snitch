import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/wigle/wigle_lookup_service.dart';
import 'package:oui_spy/theme/app_theme.dart';

/// A WiGLE check for one access point, offered on rogue-AP detections.
///
/// The lookup is never automatic. WiGLE's free budget is a handful of queries a
/// day, so spending one is the user's decision, taken on a detection they have
/// already decided is worth the question.
class WiglePanel extends ConsumerStatefulWidget {
  const WiglePanel({super.key, required this.detection});

  final Detection detection;

  /// Only Wi-Fi access points can be asked about — WiGLE is keyed by BSSID.
  static bool appliesTo(Detection d) => switch (d.method) {
        'evil_twin' || 'pineapple' || 'wifi_ap' || 'wifi_watchlist' => true,
        _ => d.ssid.isNotEmpty,
      };

  @override
  ConsumerState<WiglePanel> createState() => _WiglePanelState();
}

class _WiglePanelState extends ConsumerState<WiglePanel> {
  bool _busy = false;
  WigleResult? _result;
  bool _ranOnce = false;

  @override
  void initState() {
    super.initState();
    // A cached answer costs nothing, so show it without being asked.
    final svc = ref.read(wigleLookupProvider);
    _result = svc.cached(
      widget.detection.macAddress,
      lat: widget.detection.latitude,
      lon: widget.detection.longitude,
    );
    _ranOnce = _result != null;
  }

  Future<void> _lookup() async {
    setState(() => _busy = true);
    final svc = ref.read(wigleLookupProvider);
    final r = await svc.lookup(
      widget.detection.macAddress,
      lat: widget.detection.latitude,
      lon: widget.detection.longitude,
    );
    if (!mounted) return;
    setState(() {
      _result = r;
      _busy = false;
      _ranOnce = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final svc = ref.watch(wigleLookupProvider);

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.travel_explore, size: 15, color: t.textDim),
              const SizedBox(width: 6),
              Text(
                'WIGLE',
                style: TextStyle(
                  color: t.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              const Spacer(),
              Text(
                svc.budgetLabel,
                style: TextStyle(color: t.textDim, fontSize: 9),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!svc.hasCredentials)
            Text(
              'Sign in to WiGLE under Config → Wardrive to enable lookups.',
              style: TextStyle(color: t.textDim, fontSize: 11, height: 1.4),
            )
          else if (_result != null) ...[
            Text(
              _result!.headline,
              style: TextStyle(
                color: _colorFor(_result!.verdict, t),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _result!.interpretation,
              style: TextStyle(color: t.textSecondary, fontSize: 11, height: 1.4),
            ),
            if (_result!.ssid != null && _result!.ssid!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'WiGLE records this BSSID as "${_result!.ssid}"'
                '${_result!.lastSeen != null ? ', last seen ${_result!.lastSeen}' : ''}.',
                style: TextStyle(color: t.textDim, fontSize: 11, height: 1.4),
              ),
            ],
          ] else if (_ranOnce) ...[
            Text(
              svc.exhausted
                  ? 'Daily WiGLE limit reached. It resets at 00:00 US/Pacific.'
                  : svc.lastError ?? 'No answer from WiGLE.',
              style: TextStyle(color: AppTheme.warning, fontSize: 11, height: 1.4),
            ),
          ] else
            Text(
              'Ask WiGLE whether this access point is recorded at this '
              'location. Costs one query from a small daily budget.',
              style: TextStyle(color: t.textDim, fontSize: 11, height: 1.4),
            ),
          if (svc.hasCredentials && !svc.exhausted) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _lookup,
                icon: _busy
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search, size: 15),
                label: Text(
                  _result == null ? 'Check WiGLE' : 'Check again',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static Color _colorFor(WigleVerdict v, ResolvedTheme t) => switch (v) {
        WigleVerdict.knownHere => AppTheme.success,
        WigleVerdict.knownElsewhere => AppTheme.warning,
        WigleVerdict.unknown => AppTheme.warning,
        WigleVerdict.knownNoLocalFix => t.textPrimary,
      };
}
