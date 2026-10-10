import 'package:flutter/material.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/command_bar.dart';

export 'package:oui_spy/widgets/command_bar.dart';

class ConfigSection {
  const ConfigSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

const kConfigSections = <ConfigSection>[
  ConfigSection('APP', Icons.tune),
  ConfigSection('SCANNING', Icons.radar),
  ConfigSection('RULES', Icons.rule),
  ConfigSection('ALERTS', Icons.notifications_active),
  ConfigSection('NODE', Icons.memory),
  ConfigSection('DATA', Icons.storage),
];

class ConfigNav extends InheritedWidget {
  const ConfigNav({super.key, required this.controller, required super.child});

  final TabController controller;

  static TabController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConfigNav>()!.controller;

  @override
  bool updateShouldNotify(ConfigNav oldWidget) =>
      oldWidget.controller != controller;
}

class ConfigBottomBar extends StatelessWidget {
  const ConfigBottomBar({super.key, this.actions = const <CommandBarAction>[]});

  final List<CommandBarAction> actions;

  @override
  Widget build(BuildContext context) {
    final controller = ConfigNav.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final index = controller.index.clamp(0, kConfigSections.length - 1);
        final section = kConfigSections[index];
        return CommandBar(
          leading: CommandBarLeading(
            icon: section.icon,
            label: section.label,
            onTap: () => showConfigSectionSheet(context, controller),
          ),
          actions: actions,
        );
      },
    );
  }
}

const kConfigSectionSheetRoute = 'config-section-sheet';

/// Asked of the navigator, never cached — a torn-down route can't strand a flag.
bool configSectionSheetOpen(BuildContext context) {
  var open = false;
  Navigator.of(context).popUntil((r) {
    if (r.settings.name == kConfigSectionSheetRoute) open = true;
    return true;
  });
  return open;
}

Future<void> toggleConfigSectionSheet(
    BuildContext context, TabController controller) async {
  if (configSectionSheetOpen(context)) {
    await Navigator.of(context).maybePop();
    return;
  }
  await showConfigSectionSheet(context, controller);
}

Future<void> showConfigSectionSheet(
    BuildContext context, TabController controller) {
  if (configSectionSheetOpen(context)) return Future<void>.value();
  return _showSectionSheet(context, controller);
}

Future<void> _showSectionSheet(
    BuildContext context, TabController controller) {
  return showCommandSheet<void>(
    context: context,
    routeSettings: const RouteSettings(name: kConfigSectionSheetRoute),
    builder: (ctx) => CommandSheet(
      title: 'SECTION',
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final scale = MediaQuery.textScalerOf(ctx).scale(1);
          final minTile = kMinInteractiveDimension * 2 * scale;
          final columns = (constraints.maxWidth / minTile).floor().clamp(2, 5);
          final gap = barGap(ctx);
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            alignment: WrapAlignment.center,
            children: [
              for (int i = 0; i < kConfigSections.length; i++)
                SizedBox(
                  width: width,
                  child: _SectionTile(
                    section: kConfigSections[i],
                    selected: controller.index == i,
                    onTap: () {
                      controller.animateTo(i);
                      Navigator.pop(ctx);
                    },
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final ConfigSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final fg = selected ? AppTheme.accent : t.textSecondary;
    final gap = barGap(context);
    final iconSize = barIconSize(context);
    return Material(
      color: selected
          ? AppTheme.accent.withValues(alpha: 0.14)
          : t.surfaceLight,
      borderRadius: BorderRadius.circular(gap * 1.5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(gap * 1.5),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension * 1.5,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: gap,
            vertical: gap * 1.5,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(gap * 1.5),
            border: Border.all(
              color: selected ? AppTheme.accent : t.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(section.icon, size: iconSize * 1.2, color: fg),
              SizedBox(height: gap * 0.8),
              Text(
                section.label,
                textAlign: TextAlign.center,
                style: barLabelStyle(context, fg, bold: selected),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
