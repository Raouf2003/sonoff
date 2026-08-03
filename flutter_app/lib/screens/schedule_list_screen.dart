import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';
import 'schedule_form_screen.dart';

class ScheduleListScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final int maxChannel;
  const ScheduleListScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.maxChannel = 4,
  });

  @override
  State<ScheduleListScreen> createState() => _ScheduleListScreenState();
}

class _ScheduleListScreenState extends State<ScheduleListScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _schedules = [];
  bool _loading = true;

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final schedules = await _api.getSchedules();
      if (mounted) {
        setState(() {
          _schedules = schedules.cast<Map<String, dynamic>>()
              .where((s) => s['deviceId'] == widget.deviceId)
              .toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _err('Failed to load schedules');
    }
  }

  Future<void> _add() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
          maxChannel: widget.maxChannel,
        ),
      ),
    );
    if (created == true) _load();
  }

  Future<void> _toggle(Map<String, dynamic> schedule) async {
    final id = schedule['_id'] as String;
    final target = !((schedule['enabled'] as bool?) ?? false);
    setState(() => schedule['enabled'] = target);
    try {
      await _api.toggleSchedule(id);
    } catch (e) {
      setState(() => schedule['enabled'] = !target);
      _err('Failed to update schedule');
    }
  }

  Future<void> _delete(Map<String, dynamic> schedule) async {
    final id = schedule['_id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.submerged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete schedule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam)),
        content: Text('"${schedule['name']}" will be removed.', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('Delete', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFFF7A7A)))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteSchedule(id);
      _load();
    } catch (e) {
      _err('Failed to delete schedule');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Schedules', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
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
                    Text(widget.deviceName, style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
                    const SizedBox(height: 2),
                    Text('ID: ${widget.deviceId}', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: SizedBox(
                  width: double.infinity, height: 46,
                  child: FilledButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text('Add Schedule', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
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
                    : _schedules.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.schedule, size: 48, color: AppColors.mist.withValues(alpha: 0.3)),
                                const SizedBox(height: 12),
                                Text('No schedules yet', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.mist)),
                                const SizedBox(height: 4),
                                Text('Add a schedule to auto-control a channel', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.6))),
                              ],
                            ),
                          )
                        : ListView.separated(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                            itemCount: _schedules.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 10),
                            itemBuilder: (_, i) => _buildTile(_schedules[i]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTile(Map<String, dynamic> schedule) {
    final enabled = (schedule['enabled'] as bool?) ?? false;
    final channels = (schedule['channels'] as List<dynamic>? ?? [])
        .map((c) => 'CH$c')
        .join(', ');
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
                Text(schedule['name'] as String? ?? '', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.foam)),
                const SizedBox(height: 4),
                Text('Channels: $channels', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                const SizedBox(height: 4),
                Text(_rangesSummary(schedule), style: GoogleFonts.inter(fontSize: 12, color: AppColors.stream.withValues(alpha: 0.9))),
                const SizedBox(height: 4),
                Text(_recurrenceSummary(schedule), style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.7))),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: enabled,
            onChanged: (_) => _toggle(schedule),
            activeTrackColor: AppColors.leaf,
            activeThumbColor: AppColors.well,
          ),
          IconButton(
            onPressed: () => _delete(schedule),
            icon: const Icon(Icons.delete_outline, size: 19, color: Color(0xFFFF7A7A)),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }

  String _rangesSummary(Map<String, dynamic> schedule) {
    final ranges = (schedule['timeRanges'] as List<dynamic>? ?? []);
    if (ranges.isEmpty) return 'No ranges';
    return ranges.map((r) => '${r['start']} - ${r['end']}').join('   ');
  }

  String _recurrenceSummary(Map<String, dynamic> schedule) {
    final recurrence = schedule['recurrence'] as Map<String, dynamic>? ?? {};
    if (recurrence['type'] == 'custom') {
      final days = (recurrence['daysOfWeek'] as List<dynamic>? ?? [])
          .map((d) => _dayLabels[(d as int?) ?? 0])
          .join(', ');
      return 'Custom: $days';
    }
    return 'Every day';
  }
}