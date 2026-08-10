import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';

class AddSensorScreen extends StatefulWidget {
  const AddSensorScreen({super.key});

  @override
  State<AddSensorScreen> createState() => _AddSensorScreenState();
}

class _AddSensorScreenState extends State<AddSensorScreen> {
  final _nameCtl = TextEditingController();
  final _sensorIdCtl = TextEditingController();
  final _api = ApiService();

  List<Map<String, dynamic>> _devices = [];
  String? _selectedDeviceId;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _refreshDevices();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _sensorIdCtl.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    try {
      final list = await _api.getDevices();
      if (mounted) setState(() => _devices = list.cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  Future<void> _add() async {
    final name = _nameCtl.text.trim();
    final id = _sensorIdCtl.text.trim();
    if (name.isEmpty || id.isEmpty) { _err('Enter a Sensor Name and Sensor ID'); return; }
    if (_selectedDeviceId == null) { _err('Select the Sonoff device for this sensor'); return; }

    final colors = context.steesColors;

    setState(() => _adding = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SearchingDialog(),
    );

    try {
      await _api.createSensor(name, id, _selectedDeviceId!);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ResultDialog(
          icon: Icons.check_circle,
          color: colors.leaf,
          title: 'Sensor connected successfully.',
          message: 'Your sensor is now linked to the Sonoff device.',
          autoClose: Duration(milliseconds: 1500),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final msg = e is ApiException ? e.message : 'Check the Sensor ID and make sure the ESP32 is connected.';
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) => _ResultDialog(
          icon: Icons.error_outline,
          color: colors.danger,
          title: 'Sensor not found',
          message: msg,
        ),
      );
      if (mounted) setState(() => _adding = false);
    }
  }

  void _err(String m) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      appBar: AppBar(
        title: Text('Add Sensor', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam)),
        backgroundColor: colors.well,
        iconTheme: IconThemeData(color: colors.mist),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [colors.well, Theme.of(context).colorScheme.surfaceContainerHighest, colors.well],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildIntro(),
                const SizedBox(height: 18),
                _buildForm(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIntro() {
    final colors = context.steesColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sensors, size: 18, color: colors.stream),
              const SizedBox(width: 10),
              Text('LINK A SENSOR', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2.2, color: colors.mist)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'The sensor will be verified on MQTT before it is added. Make sure your ESP32 is powered on so it can be found.',
            style: GoogleFonts.inter(fontSize: 12.5, height: 1.55, color: colors.foam.withValues(alpha: 0.85)),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final colors = context.steesColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sensor details', style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foam)),
          const SizedBox(height: 4),
          Text(
            'Enter the Sensor ID exactly as configured on the device, then choose which Sonoff controller it belongs to.',
            style: GoogleFonts.inter(fontSize: 12, color: colors.mist.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 18),
          _Field(controller: _nameCtl, hint: 'Sensor Name', subtitle: 'e.g. Soil Moisture', icon: Icons.label_outline, next: true),
          const SizedBox(height: 12),
          _Field(controller: _sensorIdCtl, hint: 'Sensor ID', subtitle: 'e.g. soil_1', icon: Icons.sensors, onSubmit: _adding ? null : () => _add()),
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
                backgroundColor: colors.stream,
                foregroundColor: colors.well,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text('Add Sensor', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchingDialog extends StatelessWidget {
  const _SearchingDialog();

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Dialog(
      backgroundColor: colors.submerged,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3, color: colors.stream)),
            const SizedBox(height: 20),
            Text('Searching for sensor...', style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foam)),
            const SizedBox(height: 8),
            Text(
              'Waiting for the sensor to report on MQTT. This can take a few seconds.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 12, height: 1.5, color: colors.mist.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultDialog extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final Duration? autoClose;

  const _ResultDialog({required this.icon, required this.color, required this.title, required this.message, this.autoClose});

  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  @override
  void initState() {
    super.initState();
    if (widget.autoClose != null) {
      Future.delayed(widget.autoClose!, () {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Dialog(
      backgroundColor: colors.submerged,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 44, color: widget.color),
            const SizedBox(height: 16),
            Text(widget.title, textAlign: TextAlign.center, style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foam)),
            const SizedBox(height: 8),
            Text(
              widget.message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 12.5, height: 1.5, color: colors.mist.withValues(alpha: 0.85)),
            ),
            if (widget.autoClose == null) ...[
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity, height: 42,
                child: FilledButton(
                  onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.stream,
                    foregroundColor: colors.well,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('OK', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ],
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
    final colors = context.steesColors;
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
      dropdownColor: colors.submerged,
      icon: Icon(Icons.expand_more, size: 18, color: colors.mist),
      decoration: InputDecoration(
        labelText: 'Device',
        hintText: devices.isEmpty ? 'No Sonoff devices yet' : 'Select the Sonoff device',
        labelStyle: GoogleFonts.inter(fontSize: 12, color: colors.mist),
        helperText: 'e.g. Greenhouse Sonoff',
        helperStyle: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.75)),
        prefixIcon: Icon(Icons.settings_input_hdmi, size: 18, color: colors.mist),
        filled: true,
        fillColor: colors.well,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.stream, width: 1.5),
        ),
      ),
      items: devices.map<DropdownMenuItem<String>>((d) {
        return DropdownMenuItem<String>(
          value: d['deviceId'] as String,
          child: Text(
            '${d['name']}  (${d['deviceId']})',
            style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
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
    final colors = context.steesColors;
    return TextField(
      controller: controller,
      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
      textInputAction: next ? TextInputAction.next : TextInputAction.done,
      onSubmitted: (_) => onSubmit?.call(),
      decoration: InputDecoration(
        hintText: hint,
        helperText: subtitle,
        helperStyle: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.75)),
        prefixIcon: Icon(icon, size: 18, color: colors.mist),
        filled: true,
        fillColor: colors.well,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.stream, width: 1.5),
        ),
      ),
    );
  }
}
