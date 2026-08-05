import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';
import 'add_sensor_screen.dart';
import 'sensor_rules_screen.dart';

class SensorsPage extends StatefulWidget {
  const SensorsPage({super.key});

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
    final id = sensor['sensorId'] as String? ?? '';
    final name = sensor['name'] as String? ?? id;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SensorRulesScreen(sensorId: id, sensorName: name)),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream),
        ),
      );
    }
    return _sensors.isEmpty ? _buildEmpty() : _buildSensorList();
  }

  Widget _buildEmpty() {
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
            child: Icon(Icons.sensors, size: 36, color: AppColors.stream.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 20),
          Text(
            'No sensors yet',
            style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam),
          ),
          const SizedBox(height: 8),
          Text(
            'Add a soil moisture sensor to monitor\nyour irrigation zones.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _openAddSensor,
            icon: const Icon(Icons.add, size: 18),
            label: Text('Add Sensor', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.stream,
              foregroundColor: AppColors.well,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorList() {
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            itemCount: _sensors.length,
            itemBuilder: (_, i) => _buildSensorCard(_sensors[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SENSORS',
                  style: GoogleFonts.sora(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                    color: AppColors.mist,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_sensors.length} linked',
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _openAddSensor,
            icon: const Icon(Icons.add_circle_outline, size: 22, color: AppColors.stream),
            tooltip: 'Add sensor',
          ),
        ],
      ),
    );
  }

  Widget _buildSensorCard(Map<String, dynamic> s) {
    final id = s['sensorId'] as String? ?? '';
    final name = s['name'] as String? ?? id;
    final online = s['status'] == 'online';
    final value = s['lastValue'];
    final deviceName = _deviceName(s['deviceId'] as String? ?? '');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.submerged,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: online ? AppColors.leaf.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.06),
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
                  color: AppColors.leaf.withValues(alpha: 0.12),
                ),
                child: const Icon(Icons.agriculture, size: 18, color: AppColors.leaf),
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
                      'ID: $id',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: online ? AppColors.leaf.withValues(alpha: 0.12) : AppColors.mist.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  online ? 'Online' : 'Offline',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: online ? AppColors.leaf : AppColors.mist,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.settings_input_hdmi, size: 13, color: AppColors.mist.withValues(alpha: 0.7)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Device: $deviceName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.8)),
                ),
              ),
              if (value != null) ...[
                Text(
                  'Value: ',
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.8)),
                ),
                Text(
                  _fmtValue(value),
                  style: GoogleFonts.sora(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.stream),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openSensorRules(s),
              icon: const Icon(Icons.rule, size: 16),
              label: Text('Rule', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.foam,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
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
