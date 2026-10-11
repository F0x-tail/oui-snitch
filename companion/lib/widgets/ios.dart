import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:oui_spy/theme/app_theme.dart';

class IosPage extends StatelessWidget {
  const IosPage({
    super.key,
    required this.title,
    required this.slivers,
    this.actions = const [],
    this.leading,
    this.controller,
  });

  final String title;
  final List<Widget> slivers;
  final List<Widget> actions;
  final Widget? leading;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return ColoredBox(
      color: t.background,
      child: CustomScrollView(
        controller: controller,
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(title),
            leading: leading,
            trailing: actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: actions),
            backgroundColor: t.background.withValues(alpha: 0.92),
            border: null,
            transitionBetweenRoutes: false,
            heroTag: title,
          ),
          ...slivers,
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

class IosNavButton extends StatelessWidget {
  const IosNavButton({super.key, required this.icon, required this.onPressed, this.active = false, this.tooltip});

  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(44, 44),
      onPressed: onPressed,
      child: Icon(icon, size: 24, color: active ? AppTheme.accent : AppTheme.accent.withValues(alpha: 0.85)),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

class IosSection extends StatelessWidget {
  const IosSection({super.key, this.header, this.footer, required this.children});

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return CupertinoListSection.insetGrouped(
      backgroundColor: Colors.transparent,
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
      separatorColor: t.border,
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      header: header == null
          ? null
          : Text(header!.toUpperCase(),
              style: TextStyle(color: t.textDim, fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.2)),
      footer: footer == null ? null : Text(footer!, style: TextStyle(color: t.textDim, fontSize: 13)),
      children: children,
    );
  }
}

class IosSliverSection extends StatelessWidget {
  const IosSliverSection({super.key, required this.itemCount, required this.itemBuilder, this.header});

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final String? header;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    const r = Radius.circular(12);
    return SliverMainAxisGroup(slivers: [
      if (header != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 12, 32, 6),
            child: Text(header!.toUpperCase(),
                style: TextStyle(color: t.textDim, fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.2)),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        sliver: SliverList.builder(
          itemCount: itemCount,
          itemBuilder: (context, i) => ClipRRect(
            borderRadius: BorderRadius.vertical(top: i == 0 ? r : Radius.zero, bottom: i == itemCount - 1 ? r : Radius.zero),
            child: ColoredBox(
              color: t.surface,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (i > 0) Padding(padding: const EdgeInsets.only(left: 60), child: Divider(height: 0.5, thickness: 0.5, color: t.border)),
                itemBuilder(context, i),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

class IosRow extends StatelessWidget {
  const IosRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.detail,
    this.onTap,
    this.chevron = false,
    this.disabled = false,
  });

  final String title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? detail;
  final VoidCallback? onTap;
  final bool chevron;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final tile = CupertinoListTile.notched(
      onTap: onTap,
      backgroundColor: t.surface,
      backgroundColorActivated: t.surfaceLight,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 12, 10),
      leading: leading,
      leadingSize: 30,
      title: Text(title, style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w500)),
      subtitle: subtitle == null
          ? null
          : DefaultTextStyle.merge(style: TextStyle(color: t.textDim, fontSize: 14, height: 1.3), child: subtitle!),
      additionalInfo: detail == null ? null : Padding(padding: const EdgeInsets.only(left: 10), child: detail),
      trailing: trailing ?? (chevron ? const CupertinoListTileChevron() : null),
    );
    return disabled ? Opacity(opacity: 0.45, child: tile) : tile;
  }
}

class IosIcon extends StatelessWidget {
  const IosIcon(this.icon, this.color, {super.key});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 18, color: Colors.white),
      );
}

class IosSegments<T extends Object> extends StatelessWidget {
  const IosSegments({super.key, required this.value, required this.segments, required this.onChanged});

  final T value;
  final Map<T, String> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return SizedBox(
      width: double.infinity,
      child: CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        backgroundColor: t.surface,
        thumbColor: t.surfaceLight,
        onValueChanged: (v) {
          if (v != null) onChanged(v);
        },
        children: {
          for (final e in segments.entries)
            e.key: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(e.value, style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
            ),
        },
      ),
    );
  }
}

class IosSearch extends StatelessWidget {
  const IosSearch({super.key, required this.controller, required this.placeholder, required this.onChanged});

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return CupertinoSearchTextField(
      controller: controller,
      placeholder: placeholder,
      onChanged: onChanged,
      backgroundColor: t.surface,
      style: TextStyle(color: t.textPrimary, fontSize: 17),
      placeholderStyle: TextStyle(color: t.textDim, fontSize: 17),
    );
  }
}

class IosEmpty extends StatelessWidget {
  const IosEmpty({super.key, required this.icon, required this.title, required this.message, this.action});

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
      child: Column(
        children: [
          Icon(icon, size: 48, color: t.textDim),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: t.textDim, fontSize: 15, height: 1.35)),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}
