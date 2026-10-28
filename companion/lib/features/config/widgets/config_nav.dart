// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';

class ConfigSection {
  const ConfigSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

const kConfigSections = <ConfigSection>[
  ConfigSection('App', Icons.tune),
  ConfigSection('Scanning', Icons.radar),
  ConfigSection('Detection', Icons.track_changes),
  ConfigSection('Alerts', Icons.notifications_active),
  ConfigSection('Node', Icons.memory),
  ConfigSection('Data', Icons.storage),
];
