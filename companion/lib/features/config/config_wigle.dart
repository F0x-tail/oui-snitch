part of 'device_config.dart';

/// WiGLE API credentials. The user's own key — nothing ships with the app, and
/// WiGLE's free budget is small enough that lookups stay user-triggered.
class _WigleCredentialsSection extends ConsumerStatefulWidget {
  const _WigleCredentialsSection();

  @override
  ConsumerState<_WigleCredentialsSection> createState() =>
      _WigleCredentialsSectionState();
}

class _WigleCredentialsSectionState
    extends ConsumerState<_WigleCredentialsSection> {
  final _nameCtl = TextEditingController();
  final _tokenCtl = TextEditingController();
  bool _editing = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _tokenCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final svc = ref.watch(wigleLookupProvider);

    if (!_editing) {
      return Column(
        children: [
          ConfigActionRow(
            icon: Icons.travel_explore,
            label: svc.hasCredentials ? 'WiGLE account linked' : 'Add WiGLE API key',
            subtitle: svc.hasCredentials
                ? '${svc.budgetLabel} · ${svc.cachedCount} cached'
                : 'Optional. Enables access-point lookups on rogue-AP hits.',
            onTap: () => setState(() => _editing = true),
            trailing: Icon(Icons.chevron_right, size: 18, color: t.textDim),
          ),
          if (svc.cachedCount > 0)
            ConfigActionRow(
              icon: Icons.delete_sweep,
              label: 'Clear lookup cache',
              subtitle: 'Forget ${svc.cachedCount} stored WiGLE answers',
              onTap: () => ref.read(wigleLookupProvider).clearCache(),
            ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'From wigle.net → Account → Show My Token. Use the API Name and '
            'API Token, not your login password.',
            style: TextStyle(color: t.textDim, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameCtl,
            style: TextStyle(color: t.textPrimary, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'API Name',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenCtl,
            obscureText: true,
            style: TextStyle(color: t.textPrimary, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'API Token',
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _editing = false),
                child: const Text('CANCEL'),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: () async {
                  await ref
                      .read(wigleLookupProvider)
                      .setCredentials(_nameCtl.text, _tokenCtl.text);
                  if (!context.mounted) return;
                  setState(() => _editing = false);
                },
                child: const Text('SAVE'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
