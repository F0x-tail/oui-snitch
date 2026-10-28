// SPDX-License-Identifier: MIT
part of 'device_config.dart';

/// Status for the BSSID lookup feature. Credentials are not entered here —
/// WigleProvider owns the login, under Wardrive settings, and lookups reuse
/// that same account.
class _WigleCredentialsSection extends ConsumerStatefulWidget {
  const _WigleCredentialsSection();

  @override
  ConsumerState<_WigleCredentialsSection> createState() =>
      _WigleCredentialsSectionState();
}

class _WigleCredentialsSectionState
    extends ConsumerState<_WigleCredentialsSection> {
  @override
  void initState() {
    super.initState();
    // The user may have signed in since this service last read storage.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(wigleLookupProvider).refreshCredentials();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final lookup = ref.watch(wigleLookupProvider);
    final account = ref.watch(wigleProvider);

    return Column(
      children: [
        ConfigActionRow(
          icon: Icons.travel_explore,
          label: 'Access-point lookup',
          subtitle: account.isLoggedIn
              ? '${lookup.budgetLabel} · ${lookup.cachedCount} cached'
              : 'Sign in to WiGLE under Wardrive settings to enable',
          onTap: () => ref.read(wigleLookupProvider).refreshCredentials(),
          trailing: Icon(
            account.isLoggedIn ? Icons.check_circle : Icons.remove_circle_outline,
            size: 18,
            color: account.isLoggedIn ? AppTheme.success : t.textDim,
          ),
        ),
        if (lookup.cachedCount > 0)
          ConfigActionRow(
            icon: Icons.delete_sweep,
            label: 'Clear lookup cache',
            subtitle: 'Forget ${lookup.cachedCount} stored WiGLE answers',
            onTap: () => ref.read(wigleLookupProvider).clearCache(),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'Lookups ask whether an access point is recorded where you are '
            'seeing it, to corroborate a suspected evil twin. Always manual — '
            'the free WiGLE budget is only a handful of queries a day.',
            style: TextStyle(color: t.textDim, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}
