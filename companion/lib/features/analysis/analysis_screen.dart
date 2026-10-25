// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/analysis/local_archive.dart';
import 'package:oui_spy/core/db/app_database.dart' show databaseProvider;
import 'package:oui_spy/core/oui/oui_lookup_service.dart';
import 'package:oui_spy/theme/app_theme.dart';

/// Offline analysis of the local archive — live captures plus WiGLE CSV
/// imports. Entirely local; no lookup here costs an API call.
class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({super.key});

  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  final _controller = TextEditingController();
  ArchiveOverview? _overview;
  List<ArchiveSighting> _results = const [];
  bool _loading = true;
  bool _searching = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _loadOverview();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadOverview() async {
    final db = ref.read(databaseProvider);
    final o = await db.archiveOverview();
    if (!mounted) return;
    setState(() {
      _overview = o;
      _loading = false;
    });
  }

  Future<void> _search(String term) async {
    if (term.trim().isEmpty) {
      setState(() {
        _results = const [];
        _lastQuery = '';
      });
      return;
    }
    setState(() => _searching = true);
    final db = ref.read(databaseProvider);
    final rows = await db.archiveLookup(term);
    if (!mounted) return;
    setState(() {
      _results = rows;
      _searching = false;
      _lastQuery = term.trim();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: const Text('ANALYSIS'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Recalculate',
            onPressed: () {
              setState(() => _loading = true);
              _loadOverview();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SearchBox(
                  controller: _controller,
                  onSubmitted: _search,
                  searching: _searching,
                ),
                const SizedBox(height: 16),
                if (_lastQuery.isNotEmpty) ...[
                  _SectionLabel('RESULTS FOR "$_lastQuery"'),
                  const SizedBox(height: 8),
                  if (_results.isEmpty)
                    _Hint('Nothing in the local archive matches that.')
                  else
                    ..._results.map((s) => _SightingTile(sighting: s)),
                  const SizedBox(height: 24),
                ],
                _OverviewCard(overview: _overview!),
              ],
            ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.onSubmitted,
    required this.searching,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return TextField(
      controller: controller,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      style: TextStyle(color: t.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        hintText: 'MAC, SSID or device name',
        hintStyle: TextStyle(color: t.textDim, fontSize: 13),
        prefixIcon: Icon(Icons.search, color: t.textDim, size: 20),
        suffixIcon: searching
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                icon: Icon(Icons.clear, color: t.textDim, size: 18),
                onPressed: () {
                  controller.clear();
                  onSubmitted('');
                },
              ),
        filled: true,
        fillColor: t.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.border),
        ),
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.overview});

  final ArchiveOverview overview;

  @override
  Widget build(BuildContext context) {
    if (overview.isEmpty) {
      return _Hint(
        'The archive is empty. Run a session, or import a WiGLE CSV from the '
        'Export screen, and the numbers will appear here.',
      );
    }

    final engines = overview.byEngine.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('ARCHIVE'),
        const SizedBox(height: 8),
        _StatGrid(cells: [
          _Stat('Observations', _num(overview.detections)),
          _Stat('Unique devices', _num(overview.uniqueMacs)),
          _Stat('Networks', _num(overview.uniqueSsids)),
          _Stat('Sessions', _num(overview.sessions)),
        ]),
        const SizedBox(height: 12),
        _KeyValue(
          'GPS coverage',
          '${(overview.gpsCoverage * 100).toStringAsFixed(0)}% '
              '(${_num(overview.withGps)} positioned)',
        ),
        if (overview.first != null && overview.last != null)
          _KeyValue('Span', '${_date(overview.first!)} → ${_date(overview.last!)}'),
        const SizedBox(height: 20),
        const _SectionLabel('BY ENGINE'),
        const SizedBox(height: 8),
        ...engines.map((e) => _BarRow(
              label: e.key,
              value: e.value,
              max: engines.first.value,
              color: AppTheme.accent,
            )),
      ],
    );
  }

  static String _num(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _SightingTile extends ConsumerWidget {
  const _SightingTile({required this.sighting});

  final ArchiveSighting sighting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final vendor = ref.read(ouiLookupProvider).lookup(sighting.mac);
    final label = sighting.ssid.isNotEmpty
        ? sighting.ssid
        : sighting.deviceName.isNotEmpty
            ? sighting.deviceName
            : vendor ?? sighting.mac;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
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
            label,
            style: TextStyle(
              color: t.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            sighting.mac + (vendor != null ? '  ·  $vendor' : ''),
            style: TextStyle(
              color: t.textDim,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _Chip('${sighting.observations}x'),
              _Chip('${sighting.bestRssi} dBm'),
              _Chip(sighting.engine),
              if (sighting.hasPosition) const _Chip('has GPS'),
              _Chip(_span(sighting.span)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'First ${_stamp(sighting.firstSeen)} · last ${_stamp(sighting.lastSeen)}',
            style: TextStyle(color: t.textDim, fontSize: 11),
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String _span(Duration d) {
    if (d.inMinutes < 1) return 'single hit';
    if (d.inHours < 1) return 'over ${d.inMinutes}m';
    if (d.inDays < 1) return 'over ${d.inHours}h';
    return 'over ${d.inDays}d';
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.cells});

  final List<_Stat> cells;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final c in cells)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: c,
            ),
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              color: t.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: t.textDim, fontSize: 10)),
        ],
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.value,
    required this.max,
    required this.color,
  });

  final String label;
  final int value;
  final int max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final fraction = max == 0 ? 0.0 : value / max;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: TextStyle(color: t.textPrimary, fontSize: 12)),
              Text('$value', style: TextStyle(color: t.textDim, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 5,
              backgroundColor: t.border,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Text(
      text,
      style: TextStyle(
        color: t.textDim,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.border),
      ),
      child: Text(text, style: TextStyle(color: t.textDim, fontSize: 10)),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.border),
      ),
      child: Text(text, style: TextStyle(color: t.textDim, fontSize: 12, height: 1.4)),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.k, this.v);

  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: TextStyle(color: t.textDim, fontSize: 12)),
          Flexible(
            child: Text(
              v,
              style: TextStyle(color: t.textPrimary, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
