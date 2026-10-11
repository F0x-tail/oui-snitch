import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

TextStyle _title(ResolvedTheme t, {Color? color}) => TextStyle(color: color ?? t.textPrimary, fontSize: 17);

TextStyle _sub(ResolvedTheme t) => TextStyle(color: t.textDim, fontSize: 14, height: 1.3);

const _rowPad = EdgeInsets.symmetric(horizontal: 16, vertical: 10);

class ConfigSectionHeader extends StatelessWidget {
  const ConfigSectionHeader({super.key, required this.label, this.topPadding = 4, this.note});
  final String label;
  final double topPadding;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 6, top: topPadding + 10, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: TextStyle(color: t.textDim, fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.2)),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(note!, style: TextStyle(color: t.textDim, fontSize: 13))),
        ],
      ),
    );
  }
}

class ConfigToggleRow extends StatelessWidget {
  const ConfigToggleRow({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    required this.color,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: _rowPad,
      child: Row(
        children: [
          IosIcon(icon, value ? color : t.textDim),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: _title(t)),
                if (subtitle != null) Text(subtitle!, style: _sub(t)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          CupertinoSwitch(value: value, onChanged: onChanged, activeTrackColor: color),
        ],
      ),
    );
  }
}

class ConfigSliderRow extends StatelessWidget {
  const ConfigSliderRow({
    super.key,
    required this.icon,
    required this.label,
    required this.valueLabel,
    required this.min,
    required this.max,
    required this.divisions,
    required this.value,
    required this.onChanged,
    this.color,
  });
  final IconData icon;
  final String label;
  final String valueLabel;
  final double min;
  final double max;
  final int divisions;
  final double value;
  final ValueChanged<double> onChanged;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final c = color ?? AppTheme.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        children: [
          Row(
            children: [
              IosIcon(icon, c),
              const SizedBox(width: 14),
              Expanded(child: Text(label, style: _title(t))),
              Text(valueLabel, style: TextStyle(color: c, fontSize: 17, fontWeight: FontWeight.w600)),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: CupertinoSlider(value: value, min: min, max: max, divisions: divisions, activeColor: c, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

class ConfigInfoRow extends StatelessWidget {
  const ConfigInfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.color,
    this.monospace = true,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: _rowPad,
      child: Row(
        children: [
          IosIcon(icon, color ?? t.textDim),
          const SizedBox(width: 14),
          Text(label, style: _title(t)),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(color: t.textSecondary, fontSize: 17, fontFamily: monospace ? 'monospace' : null),
            ),
          ),
        ],
      ),
    );
  }
}

class ConfigActionRow extends StatelessWidget {
  const ConfigActionRow({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    required this.onTap,
    this.color,
    this.destructive = false,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? color;
  final bool destructive;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final c = destructive ? AppTheme.error : (color ?? AppTheme.accent);
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: _rowPad,
          child: Row(
            children: [
              IosIcon(icon, c),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: _title(t, color: destructive ? AppTheme.error : null)),
                    if (subtitle != null) Text(subtitle!, style: _sub(t)),
                  ],
                ),
              ),
              if (trailing != null) trailing! else Icon(CupertinoIcons.chevron_forward, size: 18, color: t.textDim),
            ],
          ),
        ),
      ),
    );
  }
}

class ConfigTextField extends StatelessWidget {
  const ConfigTextField({
    super.key,
    required this.icon,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
  });
  final IconData icon;
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          IosIcon(icon, t.textDim),
          const SizedBox(width: 14),
          Expanded(
            child: CupertinoTextField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboardType,
              autocorrect: false,
              enableSuggestions: false,
              placeholder: label,
              style: TextStyle(color: t.textPrimary, fontSize: 17),
              placeholderStyle: TextStyle(color: t.textDim, fontSize: 17),
              decoration: null,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class ConfigNumberField extends StatefulWidget {
  const ConfigNumberField({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.suffix,
  });
  final IconData icon;
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final String? suffix;

  @override
  State<ConfigNumberField> createState() => _ConfigNumberFieldState();
}

class _ConfigNumberFieldState extends State<ConfigNumberField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text);
    if (parsed != null) {
      if (parsed != widget.value) widget.onChanged(parsed);
    } else {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void didUpdateWidget(ConfigNumberField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && !_focusNode.hasFocus) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          IosIcon(widget.icon, t.textDim),
          const SizedBox(width: 14),
          Expanded(child: Text(widget.label, style: _title(t))),
          SizedBox(
            width: 110,
            child: TextFormField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: AppTheme.accent, fontSize: 17, fontWeight: FontWeight.w600),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                suffixText: widget.suffix,
                suffixStyle: TextStyle(color: t.textDim, fontSize: 15),
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
              ),
              onTapOutside: (_) => _focusNode.unfocus(),
              onFieldSubmitted: (_) {
                _commit();
                _focusNode.unfocus();
              },
            ),
          ),
        ],
      ),
    );
  }
}
