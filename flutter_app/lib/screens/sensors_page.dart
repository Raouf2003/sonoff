import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';
import '../widgets/stees_widgets.dart';
import 'add_sensor_screen.dart';

class SensorsPage extends StatefulWidget {
  final ValueChanged<int> onNavigateToTab;
  const SensorsPage({super.key, required this.onNavigateToTab});

  @override
  State<SensorsPage> createState() => _SensorsPageState();
}

class _SensorsPageState extends State<SensorsPage> {
  final _api = ApiService();
  List<Map<String, dynamic>> _sensors = [];
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([_api.getSensors(), _api.getDevices()]);
      if (mounted) {
        setState(() {
          _sensors = results[0].cast<Map<String, dynamic>>();
          _devices = results[1].cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _deviceName(String deviceId) {
    for (final d in _devices) {
      if (d['deviceId'] == deviceId) return d['name'] as String? ?? deviceId;
    }
    return deviceId;
  }

  void _openAddSensor() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddSensorScreen()),
    );
    if (added == true) _load();
  }

  void _openSensorRules(Map<String, dynamic> sensor) async {
    widget.onNavigateToTab(3);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SteesLoading();
    if (_sensors.isEmpty) return _buildEmpty();
    return _buildSensorList();
  }

  Widget _buildEmpty() {
    return SteesEmpty(
      icon: Icons.sensors,
      title: 'No sensors yet',
      subtitle: 'Add a soil moisture sensor to\nmonitor your irrigation zones.',
      action: FilledButton.icon(
        onPressed: _openAddSensor,
        icon: const Icon(Icons.add, size: 18),
        label: Text('Add Sensor', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.stream,
          foregroundColor: AppColors.well,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
    );
  }

  Widget _buildSensorList() {
    return Column(
      children: [
        SteesSectionHeader(
          title: 'SENSORS',
          count: _sensors.length,
          trailing: _AddButton(onTap: _openAddSensor),
        ),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            color: AppColors.stream,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
              padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xxxl),
              itemCount: _sensors.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: _SensorCard(
                  sensor: _sensors[i],
                  deviceName: _deviceName(_sensors[i]['deviceId'] as String? ?? ''),
                  onTap: () => _openSensorRules(_sensors[i]),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.stream.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.stream.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 14, color: AppColors.stream),
            const SizedBox(width: AppSpacing.xs),
            Text('Add', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.stream)),
          ],
        ),
      ),
    );
  }
}

class _SensorCard extends StatefulWidget {
  final Map<String, dynamic> sensor;
  final String deviceName;
  final VoidCallback onTap;

  const _SensorCard({required this.sensor, required this.deviceName, required this.onTap});

  @override
  State<_SensorCard> createState() => _SensorCardState();
}

class _SensorCardState extends State<_SensorCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.sensor;
    final id = s['sensorId'] as String? ?? '';
    final name = s['name'] as String? ?? id;
    final online = s['status'] == 'online';
    final value = s['lastValue'];

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: SteesCard(
          active: online,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SteesAvatar(icon: Icons.agriculture, color: AppColors.leaf),
                  const SizedBox(width: AppSpacing.md),
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
                        const SizedBox(height: 2),
                        Text(
                          'ID: $id',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.7)),
                        ),
                      ],
                    ),
                  ),
                  _StatusBadge(online: online),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              SteesInfoRow(
                icon: Icons.settings_input_hdmi,
                label: 'Device: ${widget.deviceName}',
                value: value != null
                    ? Text(
                        _fmtValue(value),
                        style: GoogleFonts.sora(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.stream),
                      )
                    : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: widget.onTap,
                  icon: const Icon(Icons.rule, size: 15),
                  label: Text('Rule', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.foam,
                    side: BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtValue(dynamic value) {
    if (value is double) {
      final rounded = value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);
      return '$rounded%';
    }
    return '$value%';
  }
}

class _StatusBadge extends StatelessWidget {
  final bool online;
  const _StatusBadge({required this.online});

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.leaf : AppColors.mist;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 4),
          Text(
            online ? 'Online' : 'Offline',
            style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}
