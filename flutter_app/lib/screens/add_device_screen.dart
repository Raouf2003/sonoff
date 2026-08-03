import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: Colors.redAccent.shade200, behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Add Device', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: const Color(0xFFF1F5F9))),
        backgroundColor: const Color(0xFF0B1922),
        iconTheme: const IconThemeData(color: Color(0xFF94A3B8)),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xFF0B1922), Color(0xFF0F2332), Color(0xFF0B1922)],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A2D3D),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Icon(Icons.water_drop_outlined, size: 40, color: const Color(0xFF2DD4BF).withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    Text(
                      'Enter the Device ID from your Tasmota controller.',
                      style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8)),
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
                          backgroundColor: const Color(0xFF2DD4BF),
                          foregroundColor: const Color(0xFF0B1922),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _loading
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF0B1922)))
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
    );
  }
}

class _DeviceTypePicker extends StatelessWidget {
  final int channels;
  final ValueChanged<int> onChanged;
  const _DeviceTypePicker({required this.channels, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('RELAY COUNT', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: const Color(0xFF94A3B8))),
        ),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, icon: Icon(Icons.lightbulb_outline, size: 18), label: Text('1 Relay', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            ButtonSegment(value: 4, icon: Icon(Icons.grid_view, size: 18), label: Text('4 Relays', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
          ],
          selected: {channels},
          style: SegmentedButton.styleFrom(
            backgroundColor: const Color(0xFF0B1922),
            selectedBackgroundColor: const Color(0xFF2DD4BF),
            selectedForegroundColor: const Color(0xFF0B1922),
            foregroundColor: const Color(0xFF94A3B8),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
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
  final VoidCallback? onSubmit;

  const _Field({required this.controller, required this.hint, required this.subtitle, required this.icon, this.next = false, this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFFF1F5F9)),
      textInputAction: next ? TextInputAction.next : TextInputAction.done,
      onSubmitted: (_) => onSubmit?.call(),
      decoration: InputDecoration(
        hintText: hint,
        helperText: subtitle,
        helperStyle: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF94A3B8).withValues(alpha: 0.5)),
        prefixIcon: Icon(icon, size: 18, color: const Color(0xFF94A3B8)),
        filled: true,
        fillColor: const Color(0xFF0B1922),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF2DD4BF), width: 1.5),
        ),
      ),
    );
  }
}
