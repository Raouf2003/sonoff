import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';

class RuleFormScreen extends StatefulWidget {
  final String sensorId;
  final String sensorName;
  final int maxChannel;
  const RuleFormScreen({super.key, required this.sensorId, required this.sensorName, this.maxChannel = 4});

  @override
  State<RuleFormScreen> createState() => _RuleFormScreenState();
}

class _RuleFormScreenState extends State<RuleFormScreen> {
  final _nameCtl = TextEditingController();
  final _thresholdCtl = TextEditingController();
  final _api = ApiService();

  int _channel = 1;
  String _condition = 'below';
  String _action = 'ON';
  bool _saving = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _thresholdCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    final threshold = double.tryParse(_thresholdCtl.text.trim());
    if (name.isEmpty) { _err('Enter a rule name'); return; }
    if (threshold == null) { _err('Enter a numeric threshold'); return; }

    setState(() => _saving = true);
    try {
      await _api.createRule(
        name: name,
        sensorId: widget.sensorId,
        channel: _channel,
        condition: _condition,
        threshold: threshold,
        action: _action,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _err(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
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
        title: Text('Add Rule', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
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
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.stream.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.stream.withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SENSOR', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2.2, color: AppColors.stream)),
                      const SizedBox(height: 6),
                      Text(widget.sensorName, style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
                      const SizedBox(height: 2),
                      Text('ID: ${widget.sensorId}', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _buildForm(),
              ],
            ),
          ),
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
          Text('Rule details', style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.foam)),
          const SizedBox(height: 4),
          Text(
            'Turns a channel on the linked Sonoff device ON/OFF based on the sensor value. The device is always taken from the sensor.',
            style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _nameCtl,
            style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
            textInputAction: TextInputAction.next,
            decoration: _inputDec('Rule name', 'e.g. Water when dry', Icons.label_outline),
          ),
          const SizedBox(height: 14),
          _label('CHANNEL'),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _channel,
                  isExpanded: false,
                  style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
                  dropdownColor: AppColors.submerged,
                  icon: const Icon(Icons.expand_more, size: 18, color: AppColors.mist),
                  decoration: _inputDec('CH', '', Icons.tune),
                  items: [for (int i = 1; i <= widget.maxChannel; i++) DropdownMenuItem<int>(value: i, child: Text('CH$i', style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam)))],
                  onChanged: (v) { if (v != null) setState(() => _channel = v); },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'ON', label: Text('ON', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                    ButtonSegment(value: 'OFF', label: Text('OFF', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                  ],
                  selected: {_action},
                  style: SegmentedButton.styleFrom(
                    backgroundColor: AppColors.well,
                    selectedBackgroundColor: _action == 'ON' ? AppColors.leaf : AppColors.sunlight,
                    selectedForegroundColor: AppColors.well,
                    foregroundColor: AppColors.mist,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  onSelectionChanged: (s) => setState(() => _action = s.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _label('WHEN VALUE IS'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'below', label: Text('Below', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
              ButtonSegment(value: 'above', label: Text('Above', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            ],
            selected: {_condition},
            style: SegmentedButton.styleFrom(
              backgroundColor: AppColors.well,
              selectedBackgroundColor: AppColors.stream,
              selectedForegroundColor: AppColors.well,
              foregroundColor: AppColors.mist,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            onSelectionChanged: (s) => setState(() => _condition = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _thresholdCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
            decoration: _inputDec('Threshold value', 'e.g. 30', Icons.pin_outlined),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity, height: 50,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.stream,
                foregroundColor: AppColors.well,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.well))
                  : Text('Create Rule', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: AppColors.mist)),
    );
  }

  InputDecoration _inputDec(String hint, String helper, IconData icon) {
    return InputDecoration(
      hintText: hint,
      helperText: helper,
      helperStyle: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.5)),
      hintStyle: GoogleFonts.inter(fontSize: 14, color: AppColors.mist.withValues(alpha: 0.6)),
      prefixIcon: Icon(icon, size: 18, color: AppColors.mist),
      filled: true,
      fillColor: AppColors.well,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.stream, width: 1.5),
      ),
    );
  }
}
