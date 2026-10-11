part of 'device_config.dart';

class _WifiStatusPanel extends ConsumerStatefulWidget {
  @override
  ConsumerState<_WifiStatusPanel> createState() => _WifiStatusPanelState();
}

class _WifiStatusPanelState extends ConsumerState<_WifiStatusPanel> {
  bool _hasCreds = false;
  bool _connected = false;
  bool _enabled = false;
  String _ssid = '';
  String _ip = '';
  int _rssi = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final r = await ref.read(bleManagerProvider).readWifiConfig();
      if (!mounted) return;
      setState(() {
        _hasCreds = r.hasCreds;
        _connected = r.connected;
        _enabled = r.enabled;
        _ssid = r.ssid;
        _ip = r.ip;
        _rssi = r.rssi;
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _hasCreds = false;
        _connected = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final Color color;
    final IconData icon;
    final String title;
    final String? subtitle;
    bool connecting = false;
    if (_connected) {
      color = AppTheme.success;
      icon = Icons.wifi;
      title = 'Connected to $_ssid';
      subtitle = '$_ip · $_rssi dBm';
    } else if (_enabled && _hasCreds) {
      color = AppTheme.accent;
      icon = Icons.wifi_find;
      connecting = true;
      title = 'Connecting to $_ssid';
      subtitle = 'Can take up to 20 seconds';
    } else if (_hasCreds) {
      color = AppTheme.warning;
      icon = Icons.wifi_off;
      title = 'Saved: $_ssid';
      subtitle = 'Turn on Join Wi-Fi to connect';
    } else {
      color = t.textDim;
      icon = Icons.signal_wifi_off;
      title = 'No network saved';
      subtitle = null;
    }
    return IosRow(
      leading: IosIcon(icon, color),
      title: title,
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: connecting ? const CupertinoActivityIndicator() : null,
    );
  }
}

class _WifiEnableToggle extends ConsumerStatefulWidget {
  @override
  ConsumerState<_WifiEnableToggle> createState() => _WifiEnableToggleState();
}

class _WifiEnableToggleState extends ConsumerState<_WifiEnableToggle> {
  bool _enabled = false;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final r = await ref.read(bleManagerProvider).readWifiConfig();
      if (!mounted) return;
      setState(() => _enabled = r.enabled);
    } on Exception catch (e) {
      DebugLog.log('WiFi refresh failed: $e');
    }
  }

  Future<void> _toggle(bool v) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(bleManagerProvider).setWifiStaEnabled(v);
      if (mounted) setState(() => _enabled = v);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Toggle failed: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConfigToggleRow(
      icon: Icons.power_settings_new,
      label: 'Join Wi-Fi',
      subtitle: _enabled ? 'Connects with the saved network' : 'The node stays off Wi-Fi',
      color: AppTheme.success,
      value: _enabled,
      onChanged: _busy ? null : _toggle,
    );
  }
}

class _MeshModeTile extends StatelessWidget {
  const _MeshModeTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IosRow(
      title: label,
      subtitle: Text(subtitle),
      onTap: onTap,
      trailing: selected ? const Icon(CupertinoIcons.check_mark, size: 20, color: AppTheme.accent) : null,
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow();

  static const String appVersion = '0.6.1';

  @override
  Widget build(BuildContext context) {
    return ConfigInfoRow(
      icon: Icons.info_outline,
      label: 'Version',
      value: appVersion,
      monospace: false,
    );
  }
}
