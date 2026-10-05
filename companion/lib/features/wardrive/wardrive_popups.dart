part of 'wardrive_screen.dart';

bool _targetEngineRunning(AppState app, WardriveTarget m) {
  bool on(Engine e) => app.getEngineState(e) != EngineState.disabled;
  return switch (m) {
    WardriveTarget.flock => on(Engine.flockBle) || on(Engine.flockWifi),
    WardriveTarget.drone => on(Engine.skySpy),
    WardriveTarget.detector => on(Engine.detector),
    WardriveTarget.wigle => on(Engine.wardrive),
    WardriveTarget.wigleFlock =>
      on(Engine.wardrive) || on(Engine.flockBle) || on(Engine.flockWifi),
  };
}

class _ScanningPill extends StatefulWidget {
  const _ScanningPill({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  State<_ScanningPill> createState() => _ScanningPillState();
}

class _ScanningPillState extends State<_ScanningPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: t.background.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: widget.color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween(begin: 0.3, end: 1.0).animate(_c),
            child: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(
                    color: widget.color.withValues(alpha: 0.6), blurRadius: 6)],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(widget.label, style: TextStyle(
            color: widget.color, fontSize: 11,
            fontWeight: FontWeight.w700, letterSpacing: 1)),
        ],
      ),
    );
  }
}

class _RadioRolePopup extends StatefulWidget {
  const _RadioRolePopup({
    required this.nodes,
    required this.labelFor,
    required this.initial,
  });

  final List<String> nodes;
  final String Function(String) labelFor;
  final Map<String, int> initial;

  @override
  State<_RadioRolePopup> createState() => _RadioRolePopupState();
}

class _RadioRolePopupState extends State<_RadioRolePopup> {
  late final Map<String, int> _roles = {
    for (final n in widget.nodes) n: widget.initial[n] ?? 0x03,
  };

  static const _wifiColor = Color(0xFF6B8AFF);
  static const _bleColor = Color(0xFF9B6BFF);
  static const _bothColor = Color(0xFF5AE6D6);

  static Color _radioColor(int mask) => switch (mask & 0x03) {
    0x01 => _wifiColor,
    0x02 => _bleColor,
    _ => _bothColor,
  };

  static String _maskLabel(int mask) => switch (mask & 0x03) {
    0x01 => 'WIFI',
    0x02 => 'BLE',
    _ => 'BOTH',
  };

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Row(
        children: [
          const Icon(Icons.settings_input_antenna, color: AppTheme.accent, size: 18),
          const SizedBox(width: 8),
          Text('NODE RADIOS', style: TextStyle(
            color: t.textPrimary, fontSize: 15,
            fontWeight: FontWeight.w700, letterSpacing: 1)),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Assign each node WiFi, BLE, or Both for this wardrive. '
                'WiFi nodes split channels; BLE nodes cover BLE.',
                style: TextStyle(fontSize: 12, color: t.textSecondary),
              ),
            ),
            ...widget.nodes.map((id) {
              final mask = _roles[id] ?? 0x03;
              final selColor = _radioColor(mask);
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: t.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selColor.withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 9, height: 9,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: selColor,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(
                                color: selColor.withValues(alpha: 0.6), blurRadius: 6)],
                          ),
                        ),
                        Expanded(
                          child: Text(
                            widget.labelFor(id),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: t.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                          ),
                        ),
                        Text(
                          _maskLabel(mask),
                          style: TextStyle(
                              color: selColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<int>(
                        showSelectedIcon: false,
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: WidgetStateProperty.all(
                              const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                          backgroundColor: WidgetStateProperty.resolveWith((states) =>
                              states.contains(WidgetState.selected)
                                  ? selColor.withValues(alpha: 0.22)
                                  : Colors.transparent),
                          side: WidgetStateProperty.all(
                              BorderSide(color: selColor.withValues(alpha: 0.45))),
                        ),
                        segments: const [
                          ButtonSegment(
                              value: 0x01,
                              icon: Icon(Icons.wifi, size: 15, color: _wifiColor),
                              label: Text('WiFi')),
                          ButtonSegment(
                              value: 0x02,
                              icon: Icon(Icons.bluetooth, size: 15, color: _bleColor),
                              label: Text('BLE')),
                          ButtonSegment(
                              value: 0x03,
                              icon: Icon(Icons.sensors, size: 15, color: _bothColor),
                              label: Text('Both')),
                        ],
                        selected: {mask},
                        onSelectionChanged: (s) =>
                            setState(() => _roles[id] = s.first),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('CANCEL', style: TextStyle(color: t.textDim)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accent,
            foregroundColor: AppTheme.background,
          ),
          onPressed: () => Navigator.pop(context, _roles),
          child: const Text('START'),
        ),
      ],
    );
  }
}
