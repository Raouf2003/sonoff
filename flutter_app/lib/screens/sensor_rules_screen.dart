import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';
import 'rule_form_screen.dart';

class SensorRulesScreen extends StatefulWidget {
  final String sensorId;
  final String sensorName;
  const SensorRulesScreen({super.key, required this.sensorId, required this.sensorName});

  @override
  State<SensorRulesScreen> createState() => _SensorRulesScreenState();
}

class _SensorRulesScreenState extends State<SensorRulesScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rules = await _api.getRules();
      if (mounted) {
        setState(() {
          _rules = rules.cast<Map<String, dynamic>>()
              .where((r) => r['sensorId'] == widget.sensorId)
              .toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _err('Failed to load rules');
    }
  }

  Map<String, dynamic>? get _rule => _rules.isNotEmpty ? _rules.first : null;
  bool get _hasRule => _rules.isNotEmpty;

  Future<void> _editRule() async {
    if (_rule == null) return;
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RuleFormScreen(
          sensorId: widget.sensorId,
          sensorName: widget.sensorName,
          existing: _rule,
        ),
      ),
    );
    if (updated == true) _load();
  }

  Future<void> _createRule() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RuleFormScreen(sensorId: widget.sensorId, sensorName: widget.sensorName),
      ),
    );
    if (created == true) _load();
  }

  Future<void> _toggle() async {
    if (_rule == null) return;
    final id = _rule!['_id'] as String;
    final target = !((_rule!['enabled'] as bool?) ?? false);
    setState(() => _rule!['enabled'] = target);
    try {
      await _api.toggleRule(id);
    } catch (e) {
      setState(() => _rule!['enabled'] = !target);
      _err('Failed to update rule');
    }
  }

  Future<void> _delete() async {
    if (_rule == null) return;
    final id = _rule!['_id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.submerged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete rule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam)),
        content: Text('"${_rule!['name']}" will be removed permanently.', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('Delete', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFFF7A7A)))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteRule(id);
      _load();
    } catch (e) {
      _err('Failed to delete rule');
    }
  }

  void _err(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: Colors.redAccent.shade200,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
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

  String _thresholdLabel(Map<String, dynamic> rule) {
    final t = rule['threshold'];
    if (t is double && t == t.roundToDouble()) return t.toInt().toString();
    return t?.toString() ?? '...';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Rule', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
        backgroundColor: AppColors.well,
        iconTheme: const IconThemeData(color: AppColors.mist),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [AppColors.well, Color(0xFF0F2332), AppColors.well],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream)))
              : _hasRule
                  ? _buildRuleView()
                  : _buildEmpty(),
        ),
      ),
    );
  }

  Widget _buildRuleView() {
    final rule = _rule!;
    final enabled = (rule['enabled'] as bool?) ?? false;
    final channels = _channelsOf(rule);
    final threshold = _thresholdLabel(rule);
    final condition = (rule['condition'] as String?) ?? 'below';
    final action = (rule['action'] as String?) ?? 'ON';
    final opposite = action == 'ON' ? 'OFF' : 'ON';
    final condWord = condition == 'above' ? 'above' : 'below';
    final actionColor = action == 'ON' ? AppColors.leaf : AppColors.sunlight;
    final chLabel = channels.map((c) => 'CH$c').join(' + ');

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SensorHeader(sensorName: widget.sensorName, sensorId: widget.sensorId),
          const SizedBox(height: 18),

          // ── Rule Card ──
          Container(
            width: double.infinity,
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
                InkWell(
                  onTap: _editRule,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(rule['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.foam)),
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
                                _LogicPill(label: 'When $condWord $threshold', color: AppColors.stream),
                                const SizedBox(height: 6),
                                Icon(Icons.arrow_downward_rounded, size: 16, color: AppColors.mist.withValues(alpha: 0.4)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            _LogicPill(label: '$chLabel → $action', color: actionColor),
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
                      ],
                    ),
                  ),
                ),
                Container(height: 1, color: Colors.white.withValues(alpha: 0.04)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(enabled ? 'Enabled' : 'Disabled', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                      const SizedBox(width: 8),
                      Switch(
                        value: enabled,
                        onChanged: (_) => _toggle(),
                        activeTrackColor: AppColors.leaf,
                        activeThumbColor: AppColors.well,
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        onPressed: _editRule,
                        icon: const Icon(Icons.edit_outlined, size: 19, color: AppColors.stream),
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        onPressed: _delete,
                        icon: const Icon(Icons.delete_outline, size: 19, color: Color(0xFFFF7A7A)),
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.stream.withValues(alpha: 0.08),
                border: Border.all(color: AppColors.stream.withValues(alpha: 0.15)),
              ),
              child: Icon(Icons.rule_outlined, size: 36, color: AppColors.stream.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 20),
            Text('No rule yet', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam)),
            const SizedBox(height: 8),
            Text(
              'Create a rule to automatically control a relay based on this sensor\'s readings.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity, height: 48,
              child: FilledButton.icon(
                onPressed: _createRule,
                icon: const Icon(Icons.add, size: 18),
                label: Text('Create Rule', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.stream,
                  foregroundColor: AppColors.well,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Sensor Header
// ──────────────────────────────────────────────────────────────

class _SensorHeader extends StatelessWidget {
  final String sensorName;
  final String sensorId;
  const _SensorHeader({required this.sensorName, required this.sensorId});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.stream.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.stream.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.stream.withValues(alpha: 0.15),
            ),
            child: const Icon(Icons.sensors, size: 20, color: AppColors.stream),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sensorName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
                const SizedBox(height: 2),
                Text(sensorId, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Active Tag
// ──────────────────────────────────────────────────────────────

class _ActiveTag extends StatelessWidget {
  final bool enabled;
  const _ActiveTag({required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: enabled
            ? AppColors.leaf.withValues(alpha: 0.15)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 5, color: enabled ? AppColors.leaf : AppColors.mist),
          const SizedBox(width: 4),
          Text(
            enabled ? 'Active' : 'Off',
            style: GoogleFonts.sora(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: enabled ? AppColors.leaf : AppColors.mist,
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Logic Pill
// ──────────────────────────────────────────────────────────────

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
