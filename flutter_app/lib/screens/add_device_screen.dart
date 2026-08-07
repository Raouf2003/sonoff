import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _deviceIdCtl = TextEditingController();
  final _nameCtl = TextEditingController();
  final _api = ApiService();
  bool _loading = false;
  int _channels = 4;

  @override
  void dispose() {
    _deviceIdCtl.dispose();
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    final id = _deviceIdCtl.text.trim();
    final name = _nameCtl.text.trim();
    if (id.isEmpty || name.isEmpty) { _err('Fill in all fields'); return; }
    setState(() => _loading = true);
    try {
      await _api.claimDevice(id, name, channels: _channels);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) { _err(e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  void _err(String m) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger, behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      appBar: AppBar(
        title: Text('Add Device', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam)),
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
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 20),
                Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colors.submerged,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Icon(Icons.water_drop_outlined, size: 40, color: colors.stream.withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    Text(
                      'Enter the Device ID from your Tasmota controller.',
                      style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    _Field(controller: _deviceIdCtl, hint: 'Device ID', subtitle: 'e.g. sonoff_8F9BC4', icon: Icons.devices, next: true),
                    const SizedBox(height: 14),
                    _Field(controller: _nameCtl, hint: 'Device Name', subtitle: 'e.g. Garden Controller', icon: Icons.label_outline, next: true),
                    const SizedBox(height: 14),
                    _DeviceTypePicker(
                      channels: _channels,
                      onChanged: (v) => setState(() => _channels = v),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity, height: 50,
                      child: FilledButton(
                        onPressed: _loading ? null : _claim,
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.stream,
                          foregroundColor: colors.well,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _loading
                            ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.well))
                            : Text('Claim Device', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }
}

class _DeviceTypePicker extends StatelessWidget {
  final int channels;
  final ValueChanged<int> onChanged;
  const _DeviceTypePicker({required this.channels, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('RELAY COUNT', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: colors.mist)),
        ),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, icon: Icon(Icons.lightbulb_outline, size: 18), label: Text('1 Relay', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            ButtonSegment(value: 4, icon: Icon(Icons.grid_view, size: 18), label: Text('4 Relays', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
          ],
          selected: {channels},
          style: SegmentedButton.styleFrom(
            backgroundColor: colors.well,
            selectedBackgroundColor: colors.stream,
            selectedForegroundColor: colors.well,
            foregroundColor: colors.mist,
            side: BorderSide(color: colors.border),
            textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700),
          ),
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String subtitle;
  final IconData icon;
  final bool next;

  const _Field({required this.controller, required this.hint, required this.subtitle, required this.icon, this.next = false});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return TextField(
      controller: controller,
      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
      textInputAction: next ? TextInputAction.next : TextInputAction.done,
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
