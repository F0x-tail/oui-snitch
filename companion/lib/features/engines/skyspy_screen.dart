import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/engine_control.dart';
import 'package:oui_spy/core/drone_grouping.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/radio_classifier.dart';
import 'package:oui_spy/features/engines/drone_map_view.dart';
import 'package:oui_spy/features/feed/detection_row.dart';
import 'package:oui_spy/features/home/engine_card.dart' show agoLabel;
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

class SkySpyScreen extends ConsumerWidget {
  const SkySpyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final state = ref.watch(appStateProvider);
    final isActive = state.isEngineActive(Engine.skySpy);
    final groups = groupDronesByUavId(state.recentDetections);
    final droneList = groups.map((g) => g.representative).toList();

    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: 'Drones',
        leading: CupertinoNavigationBarBackButton(color: AppTheme.accent, onPressed: () => context.canPop() ? context.pop() : context.go('/home')),
        slivers: [
          SliverToBoxAdapter(
            child: IosSection(
              footer: 'Listens for FAA Remote ID broadcasts over Wi-Fi and Bluetooth.',
              children: [
                IosRow(
                  leading: const IosIcon(CupertinoIcons.airplane, AppTheme.skySpy),
                  title: 'Sky Spy',
                  subtitle: Text(isActive ? 'Scanning' : 'Off'),
                  trailing: CupertinoSwitch(
                    value: isActive,
                    activeTrackColor: AppTheme.skySpy,
                    onChanged: (enable) => setEngineEnabled(ref, Engine.skySpy, enable),
                  ),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(height: MediaQuery.of(context).size.height * 0.35, child: DroneMapView(drones: droneList)),
              ),
            ),
          ),
          if (groups.isEmpty)
            SliverToBoxAdapter(
              child: IosEmpty(
                icon: CupertinoIcons.airplane,
                title: isActive ? 'No drones yet' : 'Sky Spy is off',
                message: isActive ? 'Drones broadcasting Remote ID appear here as they are heard.' : 'Turn on Sky Spy to listen for drones.',
              ),
            )
          else
            IosSliverSection(
              header: '${groups.length} drone${groups.length == 1 ? '' : 's'}',
              itemCount: groups.length,
              itemBuilder: (context, i) => _DroneRow(
                group: groups[i],
                onTap: () => showDetectionDetails(context, ref, groups[i].representative, showMapAction: false),
              ),
            ),
        ],
      ),
    );
  }
}

class _DroneRow extends StatelessWidget {
  const _DroneRow({required this.group, required this.onTap});
  final DroneGroup group;
  final VoidCallback onTap;

  static String _transport(String method) => switch (method) {
        'odid_nan' => 'Wi-Fi NAN',
        'odid_beacon' => 'Wi-Fi beacon',
        'odid_ble' => 'Bluetooth',
        _ => method,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final d = group.representative;
    final odid = d.odid;
    final lines = <String>[
      if (odid != null) ...[
        'Altitude ${odid.altitudeMsl ?? 0} m · height ${odid.heightAgl ?? 0} m',
        'Speed ${odid.droneSpeed ?? 0} m/s · heading ${odid.droneHeading ?? 0}°',
        if (odid.droneLat != null && odid.droneLat != 0 && odid.droneLon != null)
          'Drone ${odid.droneLat!.toStringAsFixed(4)}, ${odid.droneLon!.toStringAsFixed(4)}'
        else
          'Range ${rssiRangeLabel(d.rssi, isBle: isBleMethod(d.method))}',
        if (odid.pilotLat != null && odid.pilotLat != 0 && odid.pilotLon != null)
          'Pilot ${odid.pilotLat!.toStringAsFixed(4)}, ${odid.pilotLon!.toStringAsFixed(4)}',
        if (odid.operatorId != null && odid.operatorId!.isNotEmpty) 'Operator ${odid.operatorId}',
        if (odid.selfId != null && odid.selfId!.isNotEmpty) odid.selfId!,
      ],
      for (var i = 0; i < group.macs.length; i++) '${group.macs[i].toUpperCase()} · ${_transport(group.methods[i])}',
    ];
    return IosRow(
      leading: const IosIcon(CupertinoIcons.airplane, AppTheme.skySpy),
      title: group.uavId,
      subtitle: Text(lines.join('\n')),
      detail: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${d.rssi} dBm', style: TextStyle(color: t.textSecondary, fontSize: 15)),
          Text(agoLabel(d.appTimestamp), style: TextStyle(color: t.textDim, fontSize: 13)),
        ],
      ),
      chevron: true,
      onTap: onTap,
    );
  }
}
