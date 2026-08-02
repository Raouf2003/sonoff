import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';

class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rules = await _api.getRules();
      if (mounted) setState(() { _rules = rules.cast<Map<String, dynamic>>(); _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(Map<String, dynamic> rule) async {
    try {
      await _api.toggleRule(rule['_id'] as String);
      await _load();
    } catch (e) { _err(e.toString().replaceFirst('Exception: ', '')); }
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    try {
      await _api.deleteRule(rule['_id'] as String);
      await _load();
    } catch (e) { _err(e.toString().replaceFirst('Exception: ', '')); }
  }

  Future<void> _openAdd() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const _AddRuleScreen()),
    );
    if (added == true) _load();
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

  String _conditionText(Map<String, dynamic> r) {
    final op = r['condition'] == 'above' ? '>' : '<';
    final val = (r['threshold'] as num?)?.toString() ?? '?';
    return 'IF ${r['sensorName'] ?? r['sensorId']} $op $val';
  }

  String _targetText(Map<String, dynamic> r) {
    final device = r['deviceName'] ?? r['deviceId'] ?? '';
    final ch = r['channel'] as int? ?? 1;
    final action = r['action'] == 'ON' ? 'ON' : 'OFF';
    return 'THEN $device · CH$ch $action';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Rules', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
        backgroundColor: AppColors.well,
        iconTheme: const IconThemeData(color: AppColors.mist),
        actions: [
          IconButton(
            onPressed: _openAdd,
            icon: const Icon(Icons.add, size: 20, color: AppColors.stream),
            tooltip: 'Add rule',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [AppColors.well, Color(0xFF0F2332), AppColors.well],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream)))
              : _rules.isEmpty
                  ? _buildEmpty()
                  : RefreshIndicator(
                      color: AppColors.stream,
                      onRefresh: _load,
                      child: ListView.separated(
                        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        itemCount: _rules.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (_, i) => _buildRuleCard(_rules[i]),
                      ),
                    ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.rule, size: 56, color: AppColors.mist.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text('No rules yet', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.mist)),
          const SizedBox(height: 8),
          Text('Tap + to create your first rule', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist.withValues(alpha: 0.6))),
        ],
      ),
    );
  }

  Widget _buildRuleCard(Map<String, dynamic> r) {
    final enabled = r['enabled'] == true;
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.55,
      duration: const Duration(milliseconds: 200),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: AppColors.submerged,
          border: Border.all(color: enabled ? AppColors.stream.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(r['name'] as String? ?? 'Rule', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
                ),
                Switch(
                  value: enabled,
                  activeTrackColor: AppColors.stream,
                  onChanged: (_) => _toggle(r),
                ),
                InkWell(
                  onTap: () => _delete(r),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.delete_outline, size: 18, color: AppColors.mist.withValues(alpha: 0.6)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(_conditionText(r), style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist)),
            const SizedBox(height: 3),
            Text(_targetText(r), style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: r['action'] == 'ON' ? AppColors.leaf : AppColors.sunlight)),
          ],
        ),
      ),
    );
  }
}

class _AddRuleScreen extends StatefulWidget {
  const _AddRuleScreen();

  @override
  State<_AddRuleScreen> createState() => _AddRuleScreenState();
}

class _AddRuleScreenState extends State<_AddRuleScreen> {
  final _api = ApiService();
  final _nameCtl = TextEditingController();
  final _thresholdCtl = TextEditingController();
  final _deviceCtl = TextEditingController();

  List<Map<String, dynamic>> _sensors = [];
  Map<String, String> _deviceNames = {};
  bool _loading = true;
  bool _submitting = false;

  String? _sensorId;
  int _channel = 1;
  String _condition = 'below';
  String _action = 'ON';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _thresholdCtl.dispose();
    _deviceCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sensors = await _api.getSensors();
      final devices = await _api.getDevices();
      final names = <String, String>{
        for (final d in devices.cast<Map<String, dynamic>>()) d['deviceId'] as String: d['name'] as String,
      };
      if (mounted) {
        setState(() {
          _sensors = sensors.cast<Map<String, dynamic>>();
          _deviceNames = names;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSensorChanged(String? sensorId) {
    if (sensorId == null) return;
    final sensor = _sensors.firstWhere((s) => s['sensorId'] == sensorId);
    final deviceId = sensor['deviceId'] as String? ?? '';
    final deviceName = _deviceNames[deviceId] ?? deviceId;
    setState(() {
      _sensorId = sensorId;
      _deviceCtl.text = deviceName.isEmpty ? '' : '$deviceName  ($deviceId)';
    });
  }

  Future<void> _submit() async {
    final name = _nameCtl.text.trim();
    final threshold = double.tryParse(_thresholdCtl.text.trim());
    if (name.isEmpty) { _err('Enter a rule name'); return; }
    if (_sensorId == null) { _err('Select a sensor'); return; }
    if (threshold == null) { _err('Enter a numeric threshold'); return; }
    setState(() => _submitting = true);
    try {
      await _api.createRule(
        name: name,
        sensorId: _sensorId!,
        channel: _channel,
        condition: _condition,
        threshold: threshold,
        action: _action,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) { _err(e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _submitting = false); }
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
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: AppColors.mist)),
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
          child: _loading
              ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream)))
              : SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('RULE NAME'),
                      TextField(
                        controller: _nameCtl,
                        style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
                        decoration: _dec('e.g. Water when dry', Icons.rule),
                      ),
                      const SizedBox(height: 18),
                      _label('IF SENSOR'),
                      DropdownButtonFormField<String>(
                        initialValue: _sensorId,
                        isExpanded: true,
                        style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
                        dropdownColor: AppColors.submerged,
                        icon: const Icon(Icons.expand_more, size: 18, color: AppColors.mist),
                        decoration: _dec(_sensors.isEmpty ? 'No sensors yet' : 'Select a sensor', Icons.sensors),
                        items: _sensors.map<DropdownMenuItem<String>>((s) {
                          return DropdownMenuItem<String>(
                            value: s['sensorId'] as String,
                            child: Text('${s['name']}  (${s['sensorId']})', style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam), overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: _onSensorChanged,
                      ),
                      const SizedBox(height: 18),
                      _label('DEVICE (FROM SENSOR)'),
                      TextField(
                        controller: _deviceCtl,
                        readOnly: true,
                        style: GoogleFonts.inter(fontSize: 14, color: AppColors.stream),
                        decoration: _dec('Select a sensor above', Icons.settings_input_hdmi),
                      ),
                      const SizedBox(height: 18),
                      _label('THEN'),
                      Row(
                        children: [
                          DropdownButtonFormField<int>(
                            initialValue: _channel,
                            isExpanded: false,
                            style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
                            dropdownColor: AppColors.submerged,
                            icon: const Icon(Icons.expand_more, size: 18, color: AppColors.mist),
                            decoration: _dec('CH', Icons.tune),
                            items: [for (int i = 1; i <= 4; i++) DropdownMenuItem<int>(value: i, child: Text('CH$i', style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam)))],
                            onChanged: (v) { if (v != null) setState(() => _channel = v); },
                          ),
                          const SizedBox(width: 12),
                          Expanded(
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
                      const SizedBox(height: 18),
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
                        decoration: _dec('Threshold value', Icons.pin_outlined),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity, height: 50,
                        child: FilledButton(
                          onPressed: _submitting ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.stream,
                            foregroundColor: AppColors.well,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _submitting
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.well))
                              : Text('Create Rule', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  InputDecoration _dec(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
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
