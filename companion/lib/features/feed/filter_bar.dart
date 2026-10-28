// SPDX-License-Identifier: MIT
import 'package:oui_spy/core/models/engine.dart';

enum RadioFilter { ble, wifi }

enum FilterPreset {
  all('All', null, null),
  ble('BLE', _bleEngines, RadioFilter.ble),
  wifi('Wi-Fi', _wifiEngines, RadioFilter.wifi),
  flock('Flock', _flockEngines, null),
  drones('Drones', _droneEngines, null),
  alerts('Alerts', _alertEngines, null);

  const FilterPreset(this.label, this.engines, this.radio);
  final String label;
  final Set<Engine>? engines;
  final RadioFilter? radio;

  static const _bleEngines = {
    Engine.detector,
    Engine.axon,
    Engine.foxhunter,
    Engine.uniPwn,
    Engine.wardrive,
  };
  static const _wifiEngines = {
    Engine.detector,
    Engine.flockWifi,
    Engine.foxhunter,
    Engine.skySpy,
    Engine.wardrive,
  };
  static const _flockEngines = {Engine.flockWifi};
  static const _droneEngines = {Engine.skySpy};
  static const _alertEngines = {Engine.detector};

  Set<Engine> resolve() => engines ?? Engine.values.toSet();

  bool matches(Set<Engine> active, RadioFilter? activeRadio) {
    if (radio != activeRadio) return false;
    final target = resolve();
    return active.length == target.length && active.containsAll(target);
  }
}
