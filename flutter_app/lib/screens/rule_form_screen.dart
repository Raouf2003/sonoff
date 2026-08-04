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

  Set<int> _channels = {1};
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
    if (_channels.isEmpty) { _err('Select at least one channel'); return; }
    if (threshold == null) { _err('Enter a numeric threshold'); return; }

    setState(() => _saving = true);
    try {
      await _api.createRule(
        name: name,
        sensorId: widget.sensorId,
        channels: _channels.toList()..sort(),
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
            'Turns selected channels ON/OFF based on the sensor value. When the condition is true the configured action is sent; when false the opposite action is sent automatically.',
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
          _label('CHANNELS'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [for (int i = 1; i <= widget.maxChannel; i++) _channelChip(i)],
          ),
          const SizedBox(height: 14),
          _label('ACTION (when condition is true)'),
          SegmentedButton<String>(
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
          const SizedBox(height: 8),
          Text(
            _action == 'ON'
                ? 'True: channels ON | False: channels OFF'
                : 'True: channels OFF | False: channels ON',
            style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.5)),
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

  Widget _channelChip(int ch) {
    final selected = _channels.contains(ch);
    return FilterChip(
      label: Text('CH$ch', style: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: selected ? AppColors.well : AppColors.mist,
      )),
      selected: selected,
      onSelected: (v) {
        setState(() {
          if (v) {
            _channels.add(ch);
          } else {
            _channels.remove(ch);
          }
        });
      },
      selectedColor: AppColors.stream,
      backgroundColor: AppColors.well,
      checkmarkColor: AppColors.well,
      side: BorderSide(
        color: selected ? AppColors.stream : Colors.white.withValues(alpha: 0.1),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
