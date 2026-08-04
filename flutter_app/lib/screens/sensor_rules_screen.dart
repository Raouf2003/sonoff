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

  Future<void> _editRule(Map<String, dynamic> rule) async {
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RuleFormScreen(
          sensorId: widget.sensorId,
          sensorName: widget.sensorName,
          existing: rule,
        ),
      ),
    );
    if (updated == true) _load();
  }

  Future<void> _addRule() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RuleFormScreen(sensorId: widget.sensorId, sensorName: widget.sensorName),
      ),
    );
    if (created == true) _load();
  }

  Future<void> _toggle(Map<String, dynamic> rule) async {
    final id = rule['_id'] as String;
    final target = !((rule['enabled'] as bool?) ?? false);
    setState(() => rule['enabled'] = target);
    try {
      await _api.toggleRule(id);
    } catch (e) {
      setState(() => rule['enabled'] = !target);
      _err('Failed to update rule');
    }
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    final id = rule['_id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.submerged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete rule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam)),
        content: Text('"${rule['name']}" will be removed.', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist)),
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

  String _channelsLabel(Map<String, dynamic> rule) {
    final raw = rule['channels'];
    List<int> chs;
    if (raw is List) {
      chs = raw.whereType<int>().toList();
    } else if (raw is int) {
      chs = [raw];
    } else {
      // Fallback to old single `channel` field.
      final ch = rule['channel'];
      chs = (ch is int) ? [ch] : [];
    }
    chs.sort();
    if (chs.isEmpty) return '—';
    return chs.map((c) => 'CH$c').join(', ');
  }

  String _describe(Map<String, dynamic> rule) {
    final cond = rule['condition'] == 'above' ? 'above' : 'below';
    final threshold = rule['threshold'];
    final ts = threshold is double && threshold == threshold.roundToDouble()
        ? threshold.toInt().toString()
        : threshold.toString();
    final action = rule['action'] ?? 'ON';
    final opposite = action == 'ON' ? 'OFF' : 'ON';
    return '${_channelsLabel(rule)}  ->  $cond $ts  ->  $action (else $opposite)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Rules', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.sensorName, style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
                    const SizedBox(height: 2),
                    Text('ID: ${widget.sensorId}', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: SizedBox(
                  width: double.infinity, height: 46,
                  child: FilledButton.icon(
                    onPressed: _addRule,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text('Add Rule', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.stream,
                      foregroundColor: AppColors.well,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream)))
                    : _rules.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.rule_outlined, size: 48, color: AppColors.mist.withValues(alpha: 0.3)),
                                const SizedBox(height: 12),
                                Text('No rules yet', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.mist)),
                                const SizedBox(height: 4),
                                Text('Add a rule to control a Sonoff channel', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.6))),
                              ],
                            ),
                          )
                        : ListView.separated(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                            itemCount: _rules.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 10),
                            itemBuilder: (_, i) => _buildRuleTile(_rules[i]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRuleTile(Map<String, dynamic> rule) {
    final enabled = (rule['enabled'] as bool?) ?? false;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.submerged,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enabled ? AppColors.leaf.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rule['name'] as String? ?? '', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.foam)),
                const SizedBox(height: 4),
                Text(_describe(rule), style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: enabled,
            onChanged: (_) => _toggle(rule),
            activeTrackColor: AppColors.leaf,
            activeThumbColor: AppColors.well,
          ),
          IconButton(
            onPressed: () => _editRule(rule),
            icon: Icon(Icons.edit_outlined, size: 19, color: AppColors.stream),
            tooltip: 'Edit',
          ),
          IconButton(
            onPressed: () => _delete(rule),
            icon: const Icon(Icons.delete_outline, size: 19, color: Color(0xFFFF7A7A)),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}
