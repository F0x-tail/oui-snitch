part of 'device_config.dart';

class _ScanTimingSliders extends ConsumerWidget {
  const _ScanTimingSliders();

  static const _steps = [50, 100, 110, 150, 200, 250, 300, 350, 400, 500, 800, 1000, 1500, 2000, 3000, 5000];

  int _prevStep(int current) {
    for (int i = _steps.length - 1; i >= 0; i--) {
      if (_steps[i] < current) return _steps[i];
    }
    return _steps.first;
  }

  int _nextStep(int current) {
    for (final s in _steps) {
      if (s > current) return s;
    }
    return _steps.last;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wd = ref.watch(wardriveProvider);

    return IosSection(
      header: 'Scan timing',
      footer: 'Wi-Fi rows set how long each channel is listened to. Lower values scan faster and use more battery.',
      children: [
        _TimingRow(
          icon: CupertinoIcons.wifi, label: 'Channels 1, 6, 11',
          value: wd.wifiScanInterval,
          onDown: () => ref.read(wardriveProvider).wifiScanInterval = _prevStep(wd.wifiScanInterval),
          onUp: () => ref.read(wardriveProvider).wifiScanInterval = _nextStep(wd.wifiScanInterval),
        ),
        _TimingRow(
          icon: CupertinoIcons.wifi, label: 'Other channels',
          value: wd.wifiDwellPerCh,
          onDown: () => ref.read(wardriveProvider).wifiDwellPerCh = _prevStep(wd.wifiDwellPerCh),
          onUp: () => ref.read(wardriveProvider).wifiDwellPerCh = _nextStep(wd.wifiDwellPerCh),
        ),
        _TimingRow(
          icon: CupertinoIcons.bluetooth, label: 'Bluetooth scan',
          value: wd.bleScanDuration,
          onDown: () => ref.read(wardriveProvider).bleScanDuration = _prevStep(wd.bleScanDuration),
          onUp: () => ref.read(wardriveProvider).bleScanDuration = _nextStep(wd.bleScanDuration),
        ),
        _TimingRow(
          icon: CupertinoIcons.bluetooth, label: 'Bluetooth scan every',
          value: wd.bleScanInterval,
          onDown: () => ref.read(wardriveProvider).bleScanInterval = _prevStep(wd.bleScanInterval),
          onUp: () => ref.read(wardriveProvider).bleScanInterval = _nextStep(wd.bleScanInterval),
        ),
      ],
    );
  }
}

class _TimingRow extends StatelessWidget {
  const _TimingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onDown,
    required this.onUp,
    this.suffix = 'ms',
  });
  final IconData icon;
  final String label;
  final int value;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    Widget step(IconData i, VoidCallback f, String label) => CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: f,
          child: Icon(i, size: 28, color: AppTheme.accent, semanticLabel: label),
        );
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
      child: Row(
        children: [
          IosIcon(icon, t.textDim),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w500)),
                Text('$value${suffix.isEmpty ? '' : ' $suffix'}', style: const TextStyle(color: AppTheme.accent, fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          step(CupertinoIcons.minus_circle, onDown, 'Decrease $label'),
          step(CupertinoIcons.plus_circle, onUp, 'Increase $label'),
        ],
      ),
    );
  }
}

class _ChannelRangeSlider extends ConsumerWidget {
  const _ChannelRangeSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wd = ref.watch(wardriveProvider);

    return IosSection(
      header: '2.4 GHz channel range',
      footer: 'A narrower range revisits each channel more often.',
      children: [
        _TimingRow(
          icon: CupertinoIcons.antenna_radiowaves_left_right,
          label: 'First channel',
          value: wd.channelStart,
          suffix: '',
          onDown: () => ref.read(wardriveProvider).channelStart = wd.channelStart - 1,
          onUp: () => ref.read(wardriveProvider).channelStart = wd.channelStart + 1,
        ),
        _TimingRow(
          icon: CupertinoIcons.antenna_radiowaves_left_right,
          label: 'Last channel',
          value: wd.channelEnd,
          suffix: '',
          onDown: () => ref.read(wardriveProvider).channelEnd = wd.channelEnd - 1,
          onUp: () => ref.read(wardriveProvider).channelEnd = wd.channelEnd + 1,
        ),
        if (ref.watch(bleManagerProvider).isC5)
          Padding(
            padding: const EdgeInsets.all(12),
            child: IosSegments<int>(
              value: wd.wardrive24Mode,
              segments: const {0: 'All channels', 1: 'Only 1, 6, 11'},
              onChanged: (i) => ref.read(wardriveProvider).wardrive24Mode = i,
            ),
          ),
      ],
    );
  }
}

class _WifiBandSelector extends ConsumerWidget {
  const _WifiBandSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wd = ref.watch(wardriveProvider);
    return IosSegments<WifiBand>(
      value: wd.wifiBand,
      segments: const {WifiBand.band24: '2.4 GHz', WifiBand.band5: '5 GHz', WifiBand.both: 'Both'},
      onChanged: (b) => ref.read(wardriveProvider).wifiBand = b,
    );
  }
}

class _AutoConnectToggle extends ConsumerStatefulWidget {
  const _AutoConnectToggle();

  @override
  ConsumerState<_AutoConnectToggle> createState() => _AutoConnectToggleState();
}

class _AutoConnectToggleState extends ConsumerState<_AutoConnectToggle> {
  late bool _value =
      ref.read(sharedPreferencesProvider).getBool('autoConnectEnabled') ?? false;

  Future<void> _set(bool v) async {
    setState(() => _value = v);
    await ref.read(sharedPreferencesProvider).setBool('autoConnectEnabled', v);
  }

  @override
  Widget build(BuildContext context) {
    return ConfigToggleRow(
      icon: _value ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
      label: 'Auto-connect on launch',
      subtitle: _value
          ? 'Reconnects to the last OUI-SPY device at startup'
          : 'Connect manually from the home screen',
      color: AppTheme.accent,
      value: _value,
      onChanged: _set,
    );
  }
}

class _WardriveRssiRow extends ConsumerWidget {
  const _WardriveRssiRow({required this.isBle});
  final bool isBle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wd = ref.watch(wardriveProvider);
    final value = isBle ? wd.bleRssiRelogDb : wd.wifiRssiRelogDb;
    final min = isBle ? 10 : 10;
    final max = isBle ? 50 : 60;

    return _TimingRow(
      icon: isBle ? CupertinoIcons.bluetooth : CupertinoIcons.wifi,
      label: isBle ? 'Bluetooth' : 'Wi-Fi',
      value: value,
      suffix: 'dB',
      onDown: () {
        final next = (value - 5).clamp(min, max);
        if (isBle) {
          ref.read(wardriveProvider).bleRssiRelogDb = next;
        } else {
          ref.read(wardriveProvider).wifiRssiRelogDb = next;
        }
      },
      onUp: () {
        final next = (value + 5).clamp(min, max);
        if (isBle) {
          ref.read(wardriveProvider).bleRssiRelogDb = next;
        } else {
          ref.read(wardriveProvider).wifiRssiRelogDb = next;
        }
      },
    );
  }
}

String _fmtCount(int count) {
  if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
  if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
  return '$count';
}

Widget _statRow(BuildContext context, IconData icon, Color color, String label, String value) {
  final t = AppTheme.of(context);
  return IosRow(
    leading: IosIcon(icon, color),
    title: label,
    detail: Text(value, style: TextStyle(color: t.textSecondary, fontSize: 17)),
  );
}

Widget _credentialField(
  BuildContext context, {
  required TextEditingController controller,
  required String placeholder,
  bool obscure = false,
  VoidCallback? onToggleObscure,
  bool mono = false,
}) {
  final t = AppTheme.of(context);
  return Padding(
    padding: const EdgeInsets.only(left: 16, right: 4),
    child: Row(children: [
      Expanded(
        child: CupertinoTextField(
          controller: controller,
          placeholder: placeholder,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(color: t.textPrimary, fontSize: 17, fontFamily: mono ? 'monospace' : null),
          placeholderStyle: TextStyle(color: t.textDim, fontSize: 17),
          decoration: null,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
      if (onToggleObscure != null)
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(44, 44),
          onPressed: onToggleObscure,
          child: Icon(obscure ? CupertinoIcons.eye_slash : CupertinoIcons.eye, color: t.textDim, semanticLabel: obscure ? 'Show' : 'Hide'),
        ),
    ]),
  );
}

Future<void> _confirmUnlink(BuildContext context, String service, VoidCallback onUnlink) async {
  final ok = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text('Unlink $service?'),
      content: const Text('This removes the stored credentials from this phone. You can link again any time.'),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Unlink')),
      ],
    ),
  );
  if (ok == true) onUnlink();
}

class _WigleSection extends ConsumerStatefulWidget {
  const _WigleSection();

  @override
  ConsumerState<_WigleSection> createState() => _WigleSectionState();
}

class _WigleSectionState extends ConsumerState<_WigleSection> {
  final _nameController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _obscureToken = true;
  bool _testing = false;

  @override
  void dispose() {
    _nameController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final wigle = ref.watch(wigleProvider);
    final busy = _testing || wigle.isLoading;
    if (wigle.isLoggedIn) {
      final s = wigle.stats;
      return IosSection(
        header: 'WiGLE',
        footer: wigle.rateLimited ? WigleApi.rateLimitMessage : null,
        children: [
          if (s == null)
            const IosRow(title: 'Loading your stats…', trailing: CupertinoActivityIndicator())
          else ...[
            IosRow(
              leading: const IosIcon(CupertinoIcons.person_crop_circle_fill, AppTheme.wigle),
              title: s.userName,
              subtitle: const Text('Linked'),
              detail: Text('Rank #${s.rank}', style: const TextStyle(color: AppTheme.wigle, fontSize: 17, fontWeight: FontWeight.w600)),
            ),
            _statRow(context, CupertinoIcons.wifi, AppTheme.accent, 'Wi-Fi networks', _fmtCount(s.discoveredWiFi)),
            _statRow(context, CupertinoIcons.bluetooth, AppTheme.detector, 'Bluetooth devices', _fmtCount(s.discoveredBt)),
            _statRow(context, CupertinoIcons.antenna_radiowaves_left_right, AppTheme.success, 'Cell towers', _fmtCount(s.discoveredCell)),
            _statRow(context, CupertinoIcons.chart_bar_alt_fill, AppTheme.warning, 'This month\'s rank', '#${s.monthRank}'),
          ],
          IosRow(
            leading: const IosIcon(CupertinoIcons.arrow_clockwise, AppTheme.accent),
            title: 'Refresh stats',
            onTap: () => ref.read(wigleProvider).refreshStats(),
          ),
          IosRow(
            leading: const IosIcon(CupertinoIcons.link, AppTheme.error),
            title: 'Unlink WiGLE',
            onTap: () => _confirmUnlink(context, 'WiGLE', () => ref.read(wigleProvider).logout()),
          ),
        ],
      );
    }
    return IosSection(
      header: 'WiGLE',
      footer: wigle.error ?? 'Find your API Name and Token at wigle.net/account.',
      children: [
        _credentialField(context, controller: _nameController, placeholder: 'API name'),
        _credentialField(
          context,
          controller: _tokenController,
          placeholder: 'API token',
          obscure: _obscureToken,
          onToggleObscure: () => setState(() => _obscureToken = !_obscureToken),
        ),
        IosRow(
          leading: const IosIcon(CupertinoIcons.link, AppTheme.wigle),
          title: busy ? 'Checking…' : 'Link account',
          trailing: busy ? const CupertinoActivityIndicator() : Icon(CupertinoIcons.chevron_forward, size: 18, color: t.textDim),
          onTap: busy ? null : _testAndLogin,
        ),
      ],
    );
  }

  Future<void> _testAndLogin() async {
    final name = _nameController.text.trim();
    final token = _tokenController.text.trim();
    if (name.isEmpty || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter both the API name and token')));
      return;
    }
    setState(() => _testing = true);
    final success = await ref.read(wigleProvider).login(name, token);
    if (!mounted) return;
    setState(() => _testing = false);
    if (success) {
      final stats = ref.read(wigleProvider).stats;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Linked as ${stats?.userName ?? name} (rank #${stats?.rank ?? '?'})')));
    }
  }
}

class _WdgwarsSection extends ConsumerStatefulWidget {
  const _WdgwarsSection();

  @override
  ConsumerState<_WdgwarsSection> createState() => _WdgwarsSectionState();
}

class _WdgwarsSectionState extends ConsumerState<_WdgwarsSection> {
  final _keyController = TextEditingController();
  bool _obscureKey = true;
  bool _testing = false;
  int? _flockCams;

  @override
  void initState() {
    super.initState();
    _loadFlockCams();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _loadFlockCams() async {
    final n = await ref.read(databaseProvider).flockMacCountAll();
    if (mounted) setState(() => _flockCams = n);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final w = ref.watch(wdgwarsProvider);
    final busy = _testing || w.isLoading;
    if (w.isLoggedIn) {
      final s = w.stats;
      final meta = s == null
          ? const <String>[]
          : [
              if (s.country.isNotEmpty) s.country,
              if (s.joined.isNotEmpty) 'joined ${s.joined}',
              if (s.notes > 0) '${s.notes} notes',
              if (s.bountiesCompleted > 0) '${s.bountiesCompleted} bounties',
              if (s.creditsLifetime > 0) '${_fmtCount(s.creditsLifetime)} credits earned',
            ];
      return IosSection(
        header: 'WDGWars',
        footer: meta.isEmpty ? null : meta.join(' · '),
        children: [
          if (s == null)
            const IosRow(title: 'Loading your stats…', trailing: CupertinoActivityIndicator())
          else ...[
            IosRow(
              leading: const IosIcon(CupertinoIcons.person_crop_circle_fill, AppTheme.wdgwars),
              title: s.username,
              subtitle: Text(s.gang.isEmpty ? 'Linked' : (s.gangRole.isEmpty ? s.gang : '${s.gang} · ${s.gangRole}')),
              detail: s.rank == null ? null : Text('Rank #${s.rank}', style: const TextStyle(color: AppTheme.wdgwars, fontSize: 17, fontWeight: FontWeight.w600)),
            ),
            _statRow(context, CupertinoIcons.number, AppTheme.wdgwars, 'Total devices', _fmtCount(s.total)),
            _statRow(context, CupertinoIcons.wifi, AppTheme.accent, 'Wi-Fi', _fmtCount(s.wifi)),
            _statRow(context, CupertinoIcons.bluetooth, AppTheme.detector, 'Bluetooth', _fmtCount(s.ble)),
            _statRow(context, CupertinoIcons.airplane, AppTheme.skySpy, 'Aircraft', _fmtCount(s.aircraft)),
            _statRow(context, CupertinoIcons.circle_grid_hex_fill, AppTheme.success, 'Mesh', _fmtCount(s.mesh)),
            _statRow(context, CupertinoIcons.calendar_today, AppTheme.wdgwarsAlt, 'Today', _fmtCount(s.recentToday)),
            _statRow(context, CupertinoIcons.calendar, AppTheme.wdgwars, 'Last 7 days', _fmtCount(s.recent7d)),
            _statRow(context, CupertinoIcons.shield_fill, AppTheme.wdgwarsAlt, 'Reinforced', _fmtCount(s.reinforced)),
            _statRow(context, CupertinoIcons.lock_open_fill, AppTheme.error, 'Cracked', _fmtCount(s.cracked)),
            _statRow(context, CupertinoIcons.money_dollar_circle_fill, AppTheme.warning, 'Credits', _fmtCount(s.credits)),
            _statRow(context, CupertinoIcons.rosette, AppTheme.warning, 'Badges', '${s.badges.length}'),
            if (_flockCams != null)
              _statRow(context, CupertinoIcons.video_camera_solid, AppTheme.flockWifi, 'Flock cameras (this phone)', _fmtCount(_flockCams!)),
            if (s.dailyCap > 0)
              IosRow(
                leading: IosIcon(CupertinoIcons.speedometer, s.dailyRemaining < s.dailyCap * 0.1 ? AppTheme.warning : AppTheme.wdgwars),
                title: 'Daily new-AP quota',
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (s.dailyUsed / s.dailyCap).clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: t.surfaceLight,
                      valueColor: AlwaysStoppedAnimation(s.dailyRemaining < s.dailyCap * 0.1 ? AppTheme.warning : AppTheme.wdgwars),
                    ),
                  ),
                ),
                detail: Text('${_fmtCount(s.dailyRemaining)} of ${_fmtCount(s.dailyCap)} left', style: TextStyle(color: t.textSecondary, fontSize: 15)),
              ),
          ],
          IosRow(
            leading: const IosIcon(CupertinoIcons.arrow_clockwise, AppTheme.accent),
            title: 'Refresh stats',
            onTap: () {
              ref.read(wdgwarsProvider).refreshStats();
              _loadFlockCams();
            },
          ),
          IosRow(
            leading: const IosIcon(CupertinoIcons.link, AppTheme.error),
            title: 'Unlink WDGWars',
            onTap: () => _confirmUnlink(context, 'WDGWars', () => ref.read(wdgwarsProvider).logout()),
          ),
        ],
      );
    }
    return IosSection(
      header: 'WDGWars',
      footer: w.error ?? 'Register at wdgwars.pl and create a 64-character API key in your profile.',
      children: [
        _credentialField(
          context,
          controller: _keyController,
          placeholder: 'API key',
          obscure: _obscureKey,
          mono: true,
          onToggleObscure: () => setState(() => _obscureKey = !_obscureKey),
        ),
        IosRow(
          leading: const IosIcon(CupertinoIcons.link, AppTheme.wdgwars),
          title: busy ? 'Checking…' : 'Link account',
          trailing: busy ? const CupertinoActivityIndicator() : Icon(CupertinoIcons.chevron_forward, size: 18, color: t.textDim),
          onTap: busy ? null : _testAndLogin,
        ),
      ],
    );
  }

  Future<void> _testAndLogin() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter your WDGWars API key')));
      return;
    }
    setState(() => _testing = true);
    final success = await ref.read(wdgwarsProvider).login(key);
    if (!mounted) return;
    setState(() => _testing = false);
    if (success) {
      final stats = ref.read(wdgwarsProvider).stats;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Linked as ${stats?.username ?? 'player'} (${stats?.total ?? 0} devices)')));
    }
  }
}
