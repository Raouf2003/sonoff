import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';
import '../widgets/stees_widgets.dart';
import 'rule_form_screen.dart';
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
    final colors = context.steesColors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        title: Text('Delete rule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam)),
        content: Text(
          '"${rule['name']}" will be removed permanently.',
          style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13, color: colors.mist))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('Delete', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: colors.danger))),
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

  void _addRule() {
    final colors = context.steesColors;
    if (_sensors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No sensors available. Add a sensor first.', style: TextStyle(fontSize: 13)),
          backgroundColor: colors.danger,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          margin: const EdgeInsets.all(AppSpacing.lg),
        ),
      );
      return;
    }
    if (_sensors.length == 1) {
      _openRuleForm(_sensors.first);
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.mist.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Choose a sensor',
                style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Rules control relays based on this sensor\'s readings.',
                style: GoogleFonts.inter(fontSize: 12, color: colors.mist),
              ),
              const SizedBox(height: AppSpacing.lg),
              ..._sensors.map(
                (s) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: SteesCard(
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _openRuleForm(s);
                    },
                    child: Row(
                      children: [
                        SteesAvatar(icon: Icons.sensors, color: colors.stream),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s['name'] as String? ?? s['sensorId'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w600, color: colors.foam),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s['sensorId'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(fontSize: 11, color: colors.mist),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, size: 20, color: colors.mist),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openRuleForm(Map<String, dynamic> sensor) async {
    final sensorId = sensor['sensorId'] as String;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RuleFormScreen(
          sensorId: sensorId,
          sensorName: sensor['name'] as String? ?? sensorId,
        ),
      ),
    );
    if (created == true) _load();
  }

  void _editRule(Map<String, dynamic> rule) {
    final sensorId = rule['sensorId'] as String? ?? '';
    final sensor = _sensors.firstWhere(
      (s) => s['sensorId'] == sensorId,
      orElse: () => <String, dynamic>{'sensorId': sensorId, 'name': sensorId},
    );
    _openRuleFormEdit(sensor, rule);
  }

  Future<void> _openRuleFormEdit(Map<String, dynamic> sensor, Map<String, dynamic> rule) async {
    final sensorId = sensor['sensorId'] as String;
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RuleFormScreen(
          sensorId: sensorId,
          sensorName: sensor['name'] as String? ?? sensorId,
          existing: rule,
        ),
      ),
    );
    if (updated == true) _load();
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
    final colors = context.steesColors;
    if (_loading) return const SteesLoading();
    if (_rules.isEmpty) {
      return Column(
        children: [
          _buildHeader(),
          Expanded(
            child: const SteesEmpty(
              icon: Icons.rule_outlined,
              title: 'No rules yet',
              subtitle: 'Tap "Add Rule" to control a relay\nbased on a sensor\'s readings.',
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            color: colors.stream,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
              padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xxxl),
              itemCount: _rules.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: _RuleCard(
                  rule: _rules[i],
                  sensorName: _sensorName(_rules[i]['sensorId'] as String? ?? ''),
                  channelsOf: _channelsOf,
                  onTap: () => _openRule(_rules[i]),
                  onToggle: () => _toggleRule(_rules[i]),
                  onEdit: () => _editRule(_rules[i]),
                  onDelete: () => _deleteRule(_rules[i]),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final colors = context.steesColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm),
      child: Row(
        children: [
          Text(
            'RULES',
            style: GoogleFonts.sora(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.8,
              color: colors.mist,
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _addRule,
            icon: const Icon(Icons.add, size: 16),
            label: Text('Add Rule', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(
              backgroundColor: colors.stream,
              foregroundColor: colors.well,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 0),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleCard extends StatefulWidget {
  final Map<String, dynamic> rule;
  final String sensorName;
  final List<int> Function(Map<String, dynamic>) channelsOf;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _RuleCard({
    required this.rule,
    required this.sensorName,
    required this.channelsOf,
    required this.onTap,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_RuleCard> createState() => _RuleCardState();
}

class _RuleCardState extends State<_RuleCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final rule = widget.rule;
    final enabled = (rule['enabled'] as bool?) ?? false;
    final name = rule['name'] as String? ?? '';
    final channels = widget.channelsOf(rule);
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
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: SteesCard(
          active: enabled,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SteesAvatar(icon: Icons.rule, color: colors.sunlight),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: colors.foam),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Sensor: ${widget.sensorName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(fontSize: 11, color: colors.mist),
                        ),
                      ],
                    ),
                  ),
                  SteesActiveTag(active: enabled),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              // Logic preview
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: colors.well.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: colors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _LogicPill(label: 'When $condWord $thresholdLabel', color: colors.stream),
                        const Spacer(),
                        Icon(Icons.arrow_forward_rounded, size: 14, color: colors.mist.withValues(alpha: 0.4)),
                        const Spacer(),
                        _LogicPill(label: '$chLabel → $action', color: colors.leaf),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Icon(Icons.swap_horiz_rounded, size: 13, color: colors.mist.withValues(alpha: 0.4)),
                        const SizedBox(width: AppSpacing.xs),
                        Flexible(
                          child: Text(
                            'Otherwise → $chLabel → $opposite',
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.6)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(enabled ? 'Enabled' : 'Disabled', style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
                  const SizedBox(width: AppSpacing.sm),
                  Switch(
                    value: enabled,
                    onChanged: (_) => widget.onToggle(),
                    activeTrackColor: colors.leaf,
                    activeThumbColor: colors.well,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  IconButton(
                    onPressed: widget.onEdit,
                    icon: Icon(Icons.edit_outlined, size: 18, color: colors.stream),
                    tooltip: 'Edit',
                  ),
                  IconButton(
                    onPressed: widget.onDelete,
                    icon: Icon(Icons.delete_outline, size: 18, color: colors.danger),
                    tooltip: 'Delete',
                  ),
                ],
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
