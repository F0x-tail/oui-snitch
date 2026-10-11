import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:oui_spy/theme/app_theme.dart';

double barIconSize(BuildContext context) {
  final base = Theme.of(context).textTheme.labelMedium?.fontSize ?? 12;
  final scaled = MediaQuery.textScalerOf(context).scale(base);
  return scaled.clamp(base, base * 1.5) * 1.7;
}

double barGap(BuildContext context, [double m = 1]) =>
    barIconSize(context) * 0.35 * m;

const kPillPalette = <Color>[
  AppTheme.accent,
  AppTheme.flockBle,
  AppTheme.wardrive,
  AppTheme.skySpy,
  AppTheme.flockWifi,
  AppTheme.foxhunter,
  AppTheme.warning,
  AppTheme.wdgwars,
  AppTheme.wdgwarsAlt,
  AppTheme.error,
];

Color pillColor(int i) => kPillPalette[i % kPillPalette.length];

const kPillAll = AppTheme.accent;
const kPillBle = AppTheme.flockBle;
const kPillWifi = AppTheme.wardrive;

(String, Color) wifiAuthMeta(int mode) => switch (mode) {
      0 => ('OPEN', AppTheme.error),
      1 => ('WEP', AppTheme.warning),
      2 => ('WPA', AppTheme.warning),
      3 => ('WPA2', AppTheme.success),
      4 => ('WPA/2', AppTheme.success),
      5 => ('ENT', AppTheme.accent),
      6 => ('WPA3', AppTheme.success),
      _ => ('WPA2', AppTheme.success),
    };

TextStyle barLabelStyle(BuildContext context, Color color,
    {bool bold = true}) {
  final base = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
  return base.copyWith(
    color: color,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
    letterSpacing: 0.8,
  );
}

class CommandBarAction {
  const CommandBarAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color? color;
}

class CommandSheet extends StatelessWidget {
  const CommandSheet({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.only(top: gap),
              child: Container(
                width: barIconSize(context) * 2,
                height: gap * 0.4,
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(gap),
                ),
              ),
            ),
            SizedBox(
              height: 52,
              width: double.infinity,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(title, style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
                  if (trailing != null) Positioned(left: gap, child: trailing!),
                  Positioned(
                    right: gap,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: t.border),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(gap * 2),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<T?> showCommandSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  RouteSettings? routeSettings,
}) {
  final t = AppTheme.of(context);
  return showModalBottomSheet<T>(
    context: context,
    routeSettings: routeSettings,
    backgroundColor: t.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: builder,
  );
}

class CommandSheetTile extends StatelessWidget {
  const CommandSheetTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.color,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final fg = onTap == null
        ? t.textDim.withValues(alpha: 0.4)
        : (color ?? t.textPrimary);
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: barGap(context),
      leading: Icon(icon, size: barIconSize(context), color: fg),
      title: Text(
        label,
        style: barLabelStyle(context, fg).copyWith(letterSpacing: 1),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: (Theme.of(context).textTheme.bodyMedium ??
                      const TextStyle())
                  .copyWith(color: t.textDim, fontSize: 12),
            ),
      trailing: trailing,
    );
  }
}

class CommandSheetGroup extends StatelessWidget {
  const CommandSheetGroup({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: gap * 0.75, top: gap * 0.5, left: gap * 2),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(color: t.textDim, fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.2),
          ),
        ),
        child,
        SizedBox(height: gap * 1.5),
      ],
    );
  }
}

const _acronyms = {'BLE', 'OUI', 'MAC', 'GPS', 'RSSI', 'SSID', 'UUID', 'MFG', 'GATT', 'DFU', 'ADDR1', 'ADDR2', 'ADDR3', 'IE', 'RID', 'ODID', 'NAN', 'PCAP', 'CH', 'DST', 'SRC', 'BSSID'};

String _sentenceCase(String s) {
  var first = true;
  return s.split(' ').map((w) {
    final bare = w.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final out = _acronyms.contains(bare.toUpperCase())
        ? w
        : w.toUpperCase() == 'WIFI'
            ? 'Wi-Fi'
            : first
                ? (w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase())
                : w.toLowerCase();
    first = false;
    return out;
  }).join(' ');
}

class CommandOption extends StatelessWidget {
  const CommandOption({
    super.key,
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    final text = Theme.of(context).textTheme.bodyLarge;
    final pretty = _sentenceCase(label);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: gap * 1.6),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: gap * 1.4),
              Expanded(
                child: Text(
                  pretty,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text?.copyWith(
                    color: selected ? t.textPrimary : t.textSecondary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (count != null)
                Padding(
                  padding: EdgeInsets.only(left: gap),
                  child: Text('$count', style: text?.copyWith(color: t.textDim)),
                ),
              SizedBox(
                width: 32,
                child: selected ? const Icon(Icons.check, size: 20, color: AppTheme.accent) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CommandOptionList extends StatelessWidget {
  const CommandOptionList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final radius = BorderRadius.circular(barGap(context) * 1.4);
    return Material(
      color: t.surfaceLight,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: barGap(context) * 4.6, color: t.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class CommandActiveChip extends StatelessWidget {
  const CommandActiveChip({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      _sentenceCase(label),
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
    );
  }
}

Future<void> showSortSheet<T>({
  required BuildContext context,
  required List<T> options,
  required String Function(T) label,
  required T Function() current,
  required bool Function() ascending,
  required void Function(T) onPick,
  required VoidCallback onToggleDirection,
  String Function()? hint,
}) {
  return showCommandSheet<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => CommandSheet(
        title: 'SORT',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CommandSheetGroup(
              label: 'ORDER BY',
              child: CommandOptionList(
                children: [
                  for (var i = 0; i < options.length; i++)
                    CommandOption(
                      label: label(options[i]),
                      selected: current() == options[i],
                      color: pillColor(i),
                      onTap: () {
                        onPick(options[i]);
                        setSheet(() {});
                      },
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            CommandSheetTile(
              icon: ascending() ? Icons.arrow_upward : Icons.arrow_downward,
              label: ascending() ? 'ASCENDING' : 'DESCENDING',
              subtitle: hint?.call(),
              color: AppTheme.accent,
              onTap: () {
                onToggleDirection();
                setSheet(() {});
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class CommandHeader extends StatelessWidget {
  const CommandHeader({
    super.key,
    required this.title,
    required this.count,
    this.chips = const [],
    this.indicators = const [],
    this.actions = const <CommandBarAction>[],
    this.onChipsTap,
    this.onChipsClear,
  });

  final String title;
  final String count;
  final List<Widget> chips;
  final VoidCallback? onChipsTap;
  final VoidCallback? onChipsClear;
  final List<Widget> indicators;
  final List<CommandBarAction> actions;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    final style = Theme.of(context).textTheme.titleSmall;
    return Padding(
      padding: EdgeInsets.fromLTRB(gap * 2, gap * 1.5, gap * 2, gap * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: style?.copyWith(letterSpacing: 3, color: t.textDim, fontWeight: FontWeight.w700),
                ),
              ),
              for (final i in indicators) ...[i, SizedBox(width: gap * 0.5)],
              Text(
                count,
                style: style?.copyWith(color: AppTheme.accent, fontFamily: 'monospace', fontWeight: FontWeight.w700),
              ),
              if (actions.isNotEmpty) SizedBox(width: gap * 0.5),
              for (final a in actions)
                IconButton(
                  tooltip: a.label,
                  onPressed: a.onTap,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(a.icon, size: barIconSize(context)),
                  color: a.color ?? (a.active ? AppTheme.accent : t.textSecondary),
                ),
            ],
          ),
          if (chips.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: gap * 0.75),
              child: Material(
                color: t.surface,
                borderRadius: BorderRadius.circular(gap),
                child: InkWell(
                  onTap: onChipsTap,
                  borderRadius: BorderRadius.circular(gap),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(gap, gap * 0.5, gap * 0.25, gap * 0.5),
                    child: Row(
                      children: [
                        Icon(Icons.filter_alt, size: barIconSize(context) * 0.8, color: AppTheme.accent),
                        SizedBox(width: gap * 0.75),
                        Expanded(
                          child: Wrap(spacing: gap * 0.75, runSpacing: gap * 0.75, children: chips),
                        ),
                        if (onChipsClear != null)
                          TextButton(
                            onPressed: onChipsClear,
                            child: Text('CLEAR', style: barLabelStyle(context, AppTheme.accent)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CommandEmptyState extends StatelessWidget {
  const CommandEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gap * 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: barIconSize(context) * 3, color: t.textDim),
            SizedBox(height: gap * 1.5),
            Text(
              title,
              style: barLabelStyle(context, t.textDim)
                  .copyWith(letterSpacing: 2),
            ),
            SizedBox(height: gap * 0.75),
            Text(
              message,
              textAlign: TextAlign.center,
              style: (Theme.of(context).textTheme.bodySmall ??
                      const TextStyle())
                  .copyWith(color: t.textDim),
            ),
            if (action != null) ...[
              SizedBox(height: gap),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class CommandSearchField extends StatelessWidget {
  const CommandSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final gap = barGap(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(gap * 1.5, gap, gap * 1.5, gap),
      child: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: onChanged,
        style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
            .copyWith(color: t.textPrimary),
        decoration: InputDecoration(
          hintText: hintText,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: gap * 1.5,
            vertical: gap * 1.5,
          ),
          prefixIcon: Icon(Icons.search, size: barIconSize(context)),
          suffixIcon: IconButton(
            icon: Icon(Icons.close, size: barIconSize(context)),
            onPressed: onClose,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(gap),
            borderSide: BorderSide(color: t.border),
          ),
        ),
      ),
    );
  }
}
