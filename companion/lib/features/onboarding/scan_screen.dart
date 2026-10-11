import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/ble/ble_permissions.dart';
import 'package:oui_spy/core/ble/gatt_uuids.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final Map<String, ScanResult> _results = {};
  bool _scanning = false;
  bool _connecting = false;
  String? _connectingId;
  String? _error;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<NodeConnectionState>? _connSub;
  String? _rememberedMgrId;

  Future<void> _loadRememberedManager() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (p.getBool('lastPrimaryIsManager') ?? false) {
      setState(() => _rememberedMgrId = p.getString('lastPrimaryDeviceId'));
    }
  }

  @override
  void initState() {
    super.initState();
    final ble = ref.read(bleManagerProvider);
    if (ble.isConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/home');
      });
      return;
    }
    _loadRememberedManager();
    _connSub = ble.connectionState.listen((state) {
      if (state == NodeConnectionState.ready && mounted) {
        context.go('/home');
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startScan();
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_scanning) return;

    final perm = await BlePermissions.ensureForScan();
    if (!mounted) return;
    if (perm != BlePermResult.ready) {
      _showPermDialog(perm);
      return;
    }

    _results.clear();
    _error = null;
    setState(() => _scanning = true);

    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } on Exception catch (e) {
      DebugLog.log('SCAN: stopScan pre-clean: $e');
    }

    var adapter = FlutterBluePlus.adapterStateNow;
    if (adapter == BluetoothAdapterState.unknown) {
      try {
        adapter = await FlutterBluePlus.adapterState
            .firstWhere((s) => s != BluetoothAdapterState.unknown)
            .timeout(const Duration(seconds: 2),
                onTimeout: () => FlutterBluePlus.adapterStateNow);
      } on Exception catch (e) {
        DebugLog.log('SCAN: adapter check: $e');
      }
    }
    if (adapter != BluetoothAdapterState.on &&
        adapter != BluetoothAdapterState.unknown) {
      if (mounted) {
        setState(() {
          _error = 'Bluetooth not on ($adapter)';
          _scanning = false;
        });
      }
      return;
    }

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          final name = r.device.platformName.toUpperCase();
          final advName = r.advertisementData.advName.toUpperCase();
          if (name.contains('OUI') || name.contains('SPY') ||
              advName.contains('OUI') || advName.contains('SPY') ||
              r.advertisementData.serviceUuids.contains(GattUuids.service)) {
            _results[r.device.remoteId.toString()] = r;
          }
        }
      });
    }, onError: (e) {
      if (mounted) setState(() { _error = e.toString(); _scanning = false; });
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: false,
      );
    } on FlutterBluePlusException catch (e) {
      DebugLog.log('SCAN: startScan failed: ${e.description}');
      if (mounted) {
        setState(() {
          _error = 'Scan failed: ${e.description}';
          _scanning = false;
        });
      }
      return;
    }

    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connectDevice(ScanResult result) async {
    if (_connecting) {
      DebugLog.log('SCAN: tap ignored — connect in flight to $_connectingId');
      return;
    }
    final id = result.device.remoteId.toString();
    setState(() {
      _connecting = true;
      _connectingId = id;
    });

    try {
      await FlutterBluePlus.stopScan();
    } on Exception catch (e) {
      DebugLog.log('SCAN: stopScan: $e');
    }
    _scanSub?.cancel();
    if (mounted) setState(() => _scanning = false);

    final ble = ref.read(bleManagerProvider);

    try {
      await ble.connect(result.device, sessionId: const Uuid().v4());
      DebugLog.log('SCAN: connected to ${result.device.platformName}');
      if (mounted) context.go('/home');
    } on FlutterBluePlusException catch (e) {
      DebugLog.log('SCAN: connect failed: ${e.description}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: ${e.description}'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectingId = null;
        });
      }
    }
  }

  void _showPermDialog(BlePermResult result) {
    final bool servicesOff = result == BlePermResult.locationServicesOff;
    final bool permanently =
        result == BlePermResult.permissionPermanentlyDenied;

    final String title = servicesOff
        ? 'Location services off'
        : 'Bluetooth permission required';
    final String body = servicesOff
        ? 'Android requires Location Services to be ON to scan for Bluetooth '
            'devices. Enable it, then tap Scan again.'
        : permanently
            ? 'Bluetooth scanning permission was denied. Open Settings and '
                'allow Nearby devices / Location for OUI-SPY, then tap Scan again.'
            : 'OUI-SPY needs Bluetooth scanning permission to find your node. '
                'Tap Scan again and allow it.';
    final String actionLabel =
        servicesOff ? 'Enable location' : 'Open settings';
    final bool showAction = servicesOff || permanently;

    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          if (showAction)
            CupertinoDialogAction(
              onPressed: () async {
                Navigator.of(ctx).pop();
                if (servicesOff) {
                  await BlePermissions.openLocationSettings();
                } else {
                  await BlePermissions.openAppSettings();
                }
              },
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final all = _results.values.toList();
    String displayName(ScanResult r) {
      final adv = r.advertisementData.advName;
      if (adv.isNotEmpty) return adv.toUpperCase();
      return r.device.platformName.toUpperCase();
    }
    bool isMgr(ScanResult r) {
      final adv = r.advertisementData.advName.toUpperCase();
      final plat = r.device.platformName.toUpperCase();
      if (adv.contains('-MGR') || plat.contains('-MGR')) return true;
      final rem = _rememberedMgrId;
      return rem != null && rem == r.device.remoteId.toString();
    }
    final hasManager =
        all.any(isMgr) || ref.read(bleManagerProvider).isManagerConnected;
    final filtered = hasManager ? all.where(isMgr).toList() : all;
    final sorted = filtered
      ..sort((a, b) => displayName(a).compareTo(displayName(b)));

    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: 'Connect',
        leading: CupertinoNavigationBarBackButton(
          color: AppTheme.accent,
          onPressed: () => context.go('/home'),
        ),
        slivers: [
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!, style: const TextStyle(color: AppTheme.error, fontSize: 11, fontFamily: 'monospace')),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoButton.filled(
                  onPressed: _scanning ? null : _startScan,
                  child: Text(_scanning ? 'Scanning...' : 'Scan for OUI-SPY'),
                ),
              ),
            ),
          ),
          if (_scanning)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LinearProgressIndicator(color: AppTheme.accent, backgroundColor: t.border),
              ),
            ),
          if (sorted.isEmpty)
            SliverToBoxAdapter(
              child: IosEmpty(
                icon: CupertinoIcons.bluetooth,
                title: _scanning ? 'Searching' : 'No devices found',
                message: _scanning ? 'Looking for OUI-SPY nodes nearby.' : 'Tap Scan to find devices.',
              ),
            )
          else
            IosSliverSection(
              header: '${sorted.length} device${sorted.length == 1 ? '' : 's'} found',
              itemCount: sorted.length,
              itemBuilder: (context, index) {
                final r = sorted[index];
                final id = r.device.remoteId.toString();
                final isThisConnecting = _connecting && _connectingId == id;
                final isOtherConnecting = _connecting && _connectingId != id;
                final rssiColor = r.rssi > -60 ? AppTheme.success : r.rssi > -80 ? AppTheme.warning : AppTheme.error;
                return IosRow(
                  leading: isThisConnecting
                      ? const SizedBox(
                          width: 28, height: 28,
                          child: CupertinoActivityIndicator(),
                        )
                      : const IosIcon(CupertinoIcons.bluetooth, AppTheme.accent),
                  title: r.advertisementData.advName.isNotEmpty
                      ? r.advertisementData.advName
                      : (r.device.platformName.isNotEmpty
                          ? r.device.platformName
                          : (r.advertisementData.serviceUuids.contains(GattUuids.service)
                              ? 'OUI-SPY node'
                              : '(unnamed)')),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isMgr(r))
                        Text('Manager', style: TextStyle(color: AppTheme.success, fontSize: 13)),
                      Text(
                        isThisConnecting ? 'Connecting...' : id,
                        style: TextStyle(
                          color: isThisConnecting ? AppTheme.accent : t.textDim,
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  detail: isThisConnecting
                      ? null
                      : Text('${r.rssi} dBm', style: TextStyle(
                          color: rssiColor, fontSize: 13, fontFamily: 'monospace',
                        )),
                  disabled: isOtherConnecting,
                  onTap: _connecting ? null : () => _connectDevice(r),
                );
              },
            ),
        ],
      ),
    );
  }
}
