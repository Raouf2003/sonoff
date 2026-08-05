import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';
import 'sensor_rules_screen.dart';

class RulesPage extends StatefulWidget {
  const RulesPage({super.key});

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  final _api = ApiService();
  List<Map<String, dynamic>> _rules = [];
  List<Map<String, dynamic>> _sensors = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([_api.getRules(), _api.getSensors()]);
      if (mounted) {
        setState(() {
          _rules = results[0].cast<Map<String, dynamic>>();
          _sensors = results[1].cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _sensorName(String sensorId) {
    for (final s in _sensors) {
      if (s['sensorId'] == sensorId) return s['name'] as String? ?? sensorId;
    }
    return sensorId;
  }

  Future<void> _toggleRule(Map<String, dynamic> rule) async {
    final id = rule['_id'] as String;
    final target = !((rule['enabled'] as bool?) ?? false);
    setState(() => rule['enabled'] = target);
    try {
      await _api.toggleRule(id);
    } catch (e) {
      setState(() => rule['enabled'] = !target);
    }
  }

  Future<void> _deleteRule(Map<String, dynamic> rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.submerged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete rule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam)),
        content: Text(
          '"${rule['name']}" will be removed permanently.',
          style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFFF7A7A))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteRule(rule['_id'] as String);
      _load();
    } catch (e) {
      // ignore
    }
  }

  void _openRule(Map<String, dynamic> rule) {
    final sensorId = rule['sensorId'] as String? ?? '';
    final name = _sensorName(sensorId);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SensorRulesScreen(sensorId: sensorId, sensorName: name)),
    ).then((_) => _load());
  }

  List<int> _channelsOf(Map<String, dynamic> rule) {
    final raw = rule['channels'];
    List<int> chs;
    if (raw is List) {
      chs = raw.whereType<int>().toList();
    } else if (raw is int) {
      chs = [raw];
    } else {
      final ch = rule['channel'];
      chs = (ch is int) ? [ch] : [];
    }
    chs.sort();
    return chs;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream)),
      );
    }
    if (_rules.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.stream.withValues(alpha: 0.08),
                border: Border.all(color: AppColors.stream.withValues(alpha: 0.15)),
              ),
              child: Icon(Icons.rule_outlined, size: 36, color: AppColors.stream.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 20),
            Text('No rules yet', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam)),
            const SizedBox(height: 8),
            Text(
              'Create rules from sensor details\nin the Sensors tab.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.stream,
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        itemCount: _rules.length,
        itemBuilder: (_, i) => _buildRuleCard(_rules[i]),
      ),
    );
  }

  Widget _buildRuleCard(Map<String, dynamic> rule) {
    final enabled = (rule['enabled'] as bool?) ?? false;
    final name = rule['name'] as String? ?? '';
    final sensorId = rule['sensorId'] as String? ?? '';
    final channels = _channelsOf(rule);
    final chLabel = channels.map((c) => 'CH$c').join(' + ');
    final condition = (rule['condition'] as String?) ?? 'below';
    final action = (rule['action'] as String?) ?? 'ON';
    final opposite = action == 'ON' ? 'OFF' : 'ON';
    final condWord = condition == 'above' ? 'above' : 'below';
    final threshold = rule['threshold'];
    final thresholdLabel = threshold is double && threshold == threshold.roundToDouble()
        ? threshold.toInt().toString()
        : threshold?.toString() ?? '...';

    return GestureDetector(
      onTap: () => _openRule(rule),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.submerged,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: enabled ? AppColors.leaf.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.sunlight.withValues(alpha: 0.12),
                  ),
                  child: const Icon(Icons.rule, size: 18, color: AppColors.sunlight),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam),
                      ),
                      Text(
                        'Sensor: ${_sensorName(sensorId)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist),
                      ),
                    ],
                  ),
                ),
                _ActiveTag(enabled: enabled),
              ],
            ),
            const SizedBox(height: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _LogicPill(label: 'When $condWord $thresholdLabel', color: AppColors.stream),
                    const SizedBox(height: 6),
                    Icon(Icons.arrow_downward_rounded, size: 16, color: AppColors.mist.withValues(alpha: 0.4)),
                  ],
                ),
                const SizedBox(height: 6),
                _LogicPill(label: '$chLabel → $action', color: AppColors.leaf),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.swap_horiz_rounded, size: 13, color: AppColors.mist.withValues(alpha: 0.5)),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    'Else → $chLabel → $opposite',
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.6)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(enabled ? 'Enabled' : 'Disabled', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                const SizedBox(width: 8),
                Switch(
                  value: enabled,
                  onChanged: (_) => _toggleRule(rule),
                  activeTrackColor: AppColors.leaf,
                  activeThumbColor: AppColors.well,
                ),
                const SizedBox(width: 2),
                IconButton(
                  onPressed: () => _deleteRule(rule),
                  icon: const Icon(Icons.delete_outline, size: 19, color: Color(0xFFFF7A7A)),
                  tooltip: 'Delete',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveTag extends StatelessWidget {
  final bool enabled;
  const _ActiveTag({required this.enabled});

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.leaf : AppColors.mist;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 4),
          Text(
            enabled ? 'Active' : 'Off',
            style: GoogleFonts.sora(fontSize: 10, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _LogicPill extends StatelessWidget {
  final String label;
  final Color color;
  const _LogicPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
