import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';

class AddSensorScreen extends StatefulWidget {
  const AddSensorScreen({super.key});

  @override
  State<AddSensorScreen> createState() => _AddSensorScreenState();
}

class _AddSensorScreenState extends State<AddSensorScreen> with SingleTickerProviderStateMixin {
  final _nameCtl = TextEditingController();
  final _sensorIdCtl = TextEditingController();
  final _api = ApiService();

  List<Map<String, dynamic>> _discovered = [];
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  bool _adding = false;
  String? _selected;
  String? _selectedDeviceId;
  Timer? _timer;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
    _refreshDevices();
    _refreshDiscovered();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshDiscovered(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _nameCtl.dispose();
    _sensorIdCtl.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    try {
      final list = await _api.getDevices();
      if (mounted) setState(() => _devices = list.cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  Future<void> _refreshDiscovered({bool silent = false}) async {
    try {
      final list = await _api.getDiscoveredSensors();
      if (mounted) {
        setState(() {
          _discovered = list.cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && !silent) {
        setState(() => _loading = false);
        _err('Could not reach the STEES backend');
      }
    }
  }

  String _humanize(String id) {
    final words = id.replaceAll(RegExp(r'[-_.]'), ' ').split(' ');
    return words
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  String _fmt(dynamic value) {
    if (value is double) {
      return value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);
    }
    return value.toString();
  }

  void _select(Map<String, dynamic> d) {
    final id = d['sensorId'] as String? ?? '';
    setState(() => _selected = id);
    _nameCtl.text = _humanize(id);
    _sensorIdCtl.text = id;
  }

  Future<void> _add() async {
    final name = _nameCtl.text.trim();
    final id = _sensorIdCtl.text.trim();
    if (name.isEmpty || id.isEmpty) { _err('Enter a Sensor Name and Sensor ID'); return; }
    if (_selectedDeviceId == null) { _err('Select the Sonoff device for this sensor'); return; }
    setState(() => _adding = true);
    try {
      await _api.createSensor(name, id, _selectedDeviceId!);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) { _err(e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _adding = false); }
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
        title: Text('Add Sensor', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
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
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetectedHeader(),
                const SizedBox(height: 10),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 36),
                    child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream))),
                  )
                else if (_discovered.isEmpty)
                  _buildEmptyDetected()
                else
                  ..._discovered.map(_buildDetectedTile),
                const SizedBox(height: 24),
                _buildForm(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetectedHeader() {
    return Row(
      children: [
        _PulseDot(controller: _pulse, color: AppColors.stream),
        const SizedBox(width: 10),
        Text('DETECTED', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2.2, color: AppColors.mist)),
        const Spacer(),
        IconButton(
          onPressed: () => _refreshDiscovered(),
          icon: const Icon(Icons.refresh, size: 20, color: AppColors.mist),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          tooltip: 'Refresh',
        ),
      ],
    );
  }

  Widget _buildEmptyDetected() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: AppColors.submerged,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Icon(Icons.sensors, size: 40, color: AppColors.mist.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text('No sensors detected yet', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
          const SizedBox(height: 6),
          Text(
            'Power on your sensor node so it publishes to tele/<DEVICE_ID>/SENSOR.\nIt refreshes automatically every 10 seconds.',
            style: GoogleFonts.inter(fontSize: 12, height: 1.5, color: AppColors.mist.withValues(alpha: 0.7)),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDetectedTile(Map<String, dynamic> d) {
    final id = d['sensorId'] as String? ?? '';
    final value = d['lastValue'];
    final online = d['status'] == 'online';
    final selected = _selected == id;

    return GestureDetector(
      onTap: () => _select(d),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: selected ? AppColors.stream.withValues(alpha: 0.08) : AppColors.submerged,
          border: Border.all(
            color: selected ? AppColors.stream.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.06),
            width: 1.4,
          ),
        ),
        child: Row(
          children: [
            _PulseDot(controller: _pulse, color: online ? AppColors.leaf : AppColors.mist),
            const SizedBox(width: 12),
            Expanded(
              child: Text(id, style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
            ),
            if (value != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.stream.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_fmt(value), style: GoogleFonts.sora(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.stream)),
              ),
            const SizedBox(width: 12),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.stream : AppColors.mist.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.submerged,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sensor details', style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.foam)),
          const SizedBox(height: 4),
          Text(
            'Enter the Sensor ID exactly as configured on the device, then choose which Sonoff controller it belongs to.',
            style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 18),
          _Field(controller: _nameCtl, hint: 'Sensor Name', subtitle: 'e.g. Soil Moisture', icon: Icons.label_outline, next: true),
          const SizedBox(height: 12),
          _Field(controller: _sensorIdCtl, hint: 'Sensor ID', subtitle: 'e.g. soil_1', icon: Icons.sensors, onSubmit: () => _add()),
          const SizedBox(height: 12),
          _DeviceDropdown(
            devices: _devices,
            value: _selectedDeviceId,
            onChanged: (v) => setState(() => _selectedDeviceId = v),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity, height: 50,
            child: FilledButton(
              onPressed: _adding ? null : _add,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.stream,
                foregroundColor: AppColors.well,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _adding
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.well))
                  : Text('Add Sensor', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatelessWidget {
  final AnimationController controller;
  final Color color;
  const _PulseDot({required this.controller, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, child) => Container(
        width: 9 + controller.value * 3,
        height: 9 + controller.value * 3,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35 + controller.value * 0.3), blurRadius: 6 + controller.value * 5)],
        ),
      ),
    );
  }
}

class _DeviceDropdown extends StatelessWidget {
  final List<Map<String, dynamic>> devices;
  final String? value;
  final ValueChanged<String> onChanged;

  const _DeviceDropdown({required this.devices, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
      dropdownColor: AppColors.submerged,
      icon: const Icon(Icons.expand_more, size: 18, color: AppColors.mist),
      decoration: InputDecoration(
        labelText: 'Device',
        hintText: devices.isEmpty ? 'No Sonoff devices yet' : 'Select the Sonoff device',
        labelStyle: GoogleFonts.inter(fontSize: 12, color: AppColors.mist),
        helperText: 'e.g. Greenhouse Sonoff',
        helperStyle: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.5)),
        prefixIcon: const Icon(Icons.settings_input_hdmi, size: 18, color: AppColors.mist),
        filled: true,
        fillColor: AppColors.well,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.stream, width: 1.5),
        ),
      ),
      items: devices.map<DropdownMenuItem<String>>((d) {
        return DropdownMenuItem<String>(
          value: d['deviceId'] as String,
          child: Text(
            '${d['name']}  (${d['deviceId']})',
            style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String subtitle;
  final IconData icon;
  final bool next;
  final VoidCallback? onSubmit;

  const _Field({required this.controller, required this.hint, required this.subtitle, required this.icon, this.next = false, this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
      textInputAction: next ? TextInputAction.next : TextInputAction.done,
      onSubmitted: (_) => onSubmit?.call(),
      decoration: InputDecoration(
        hintText: hint,
        helperText: subtitle,
        helperStyle: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.5)),
        prefixIcon: Icon(icon, size: 18, color: AppColors.mist),
        filled: true,
        fillColor: AppColors.well,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.stream, width: 1.5),
        ),
      ),
    );
  }
}
