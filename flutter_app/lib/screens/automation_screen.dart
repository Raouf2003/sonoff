import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';

const _well = Color(0xFF0B1922);
const _submerged = Color(0xFF1A2D3D);
const _stream = Color(0xFF2DD4BF);
const _leaf = Color(0xFF34D399);
const _sunlight = Color(0xFFFBBF24);
const _mist = Color(0xFF94A3B8);
const _foam = Color(0xFFF1F5F9);

String _two(int n) => n.toString().padLeft(2, '0');

String _fmt(DateTime? t) {
  if (t == null) return '—';
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

String _valText(dynamic v) {
  if (v is num) return v.toString();
  return v?.toString() ?? '—';
}

String _timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

String _friendlyName(String id) {
  final words = id.split(RegExp(r'[_-]')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return id;
  return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
}

class AutomationScreen extends StatefulWidget {
  const AutomationScreen({super.key});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen>
    with SingleTickerProviderStateMixin {
  final _api = ApiService();
  late final TabController _tab;

  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _sensors = [];
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;
  bool _emergencyStop = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final devices = await _api.getDevices();
      final sensors = await _api.getSensors();
      final rules = await _api.getRules();
      final emStop = await _api.getEmergencyStop();
      if (mounted) {
        setState(() {
          _devices = devices.cast<Map<String, dynamic>>();
          _sensors = sensors.cast<Map<String, dynamic>>();
          _rules = rules.cast<Map<String, dynamic>>();
          _emergencyStop = emStop;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _showError('Failed to load automation data');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      backgroundColor: Colors.redAccent.shade200,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 3),
    ));
  }

  String _deviceName(String deviceId) {
    for (final d in _devices) {
      if (d['deviceId'] == deviceId) return d['name'] as String;
    }
    return deviceId;
  }

  String _sensorName(String sensorId) {
    for (final s in _sensors) {
      if (s['sensorId'] == sensorId) return s['name'] as String;
    }
    return sensorId;
  }

  Future<void> _toggleEmergency() async {
    final target = !_emergencyStop;
    if (target) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _submerged,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Pause Automation', style: GoogleFonts.inter(color: _foam, fontWeight: FontWeight.w600)),
          content: Text('All automation rules will pause and stop sending commands until you resume them.', style: GoogleFonts.inter(color: _mist)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.inter(color: _mist))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Pause', style: GoogleFonts.inter(color: Colors.redAccent, fontWeight: FontWeight.w600))),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await _api.setEmergencyStop(target);
      if (mounted) setState(() => _emergencyStop = target);
    } catch (e) {
      _showError('Failed to update emergency stop');
    }
  }

  Future<void> _openLogs() async {
    List<Map<String, dynamic>> logs = [];
    try {
      final raw = await _api.getRuleLogs(limit: 50);
      logs = raw.cast<Map<String, dynamic>>();
    } catch (e) {
      _showError('Failed to load logs');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: _submerged,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                children: [
                  Text('Rule Log', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w700, color: _foam)),
                  const Spacer(),
                  Text('${logs.length} entries', style: GoogleFonts.inter(fontSize: 12, color: _mist)),
                ],
              ),
            ),
            Expanded(
              child: logs.isEmpty
                  ? Center(child: Text('No rule activity yet', style: GoogleFonts.inter(fontSize: 13, color: _mist)))
                  : ListView.separated(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: logs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _LogTile(log: logs[i], deviceName: _deviceName(logs[i]['deviceId'] as String? ?? '')),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_well, Color(0xFF0F2332), _well],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              if (_emergencyStop) _buildEmergencyBanner(),
              TabBar(
                controller: _tab,
                indicatorColor: _stream,
                labelColor: _stream,
                unselectedLabelColor: _mist,
                labelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
                unselectedLabelStyle: GoogleFonts.inter(fontSize: 13),
                tabs: const [
                  Tab(text: 'Rules'),
                  Tab(text: 'Sensors'),
                ],
              ),
              Expanded(
                child: Stack(
                  children: [
                    TabBarView(
                      controller: _tab,
                      children: [
                        _buildRulesTab(),
                        _buildSensorsTab(),
                      ],
                    ),
                    _addButtons(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: _mist),
          ),
          Text('Automation', style: GoogleFonts.sora(fontSize: 20, fontWeight: FontWeight.w700, color: _foam, letterSpacing: 1)),
          const Spacer(),
          IconButton(
            onPressed: _openLogs,
            tooltip: 'Rule log',
            icon: Icon(Icons.receipt_long, size: 20, color: _mist),
          ),
          IconButton(
            onPressed: _toggleEmergency,
            tooltip: 'Pause automation',
            icon: Icon(
              _emergencyStop ? Icons.power_settings_new : Icons.power_settings_new_outlined,
              size: 20,
              color: _emergencyStop ? Colors.redAccent : _mist,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmergencyBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: Colors.redAccent),
          const SizedBox(width: 10),
          Expanded(child: Text('Automation is paused — no commands will be sent until you resume', style: GoogleFonts.inter(fontSize: 12, color: Colors.redAccent))),
        ],
      ),
    );
  }

  Widget _buildRulesTab() {
    if (_loading) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: _stream)));
    }
    return RefreshIndicator(
      color: _stream,
      backgroundColor: _submerged,
      onRefresh: _load,
      child: _rules.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Icon(Icons.rule, size: 64, color: _mist.withValues(alpha: 0.3)),
                const SizedBox(height: 16),
                Center(child: Text('No automation rules yet', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600, color: _mist))),
                const SizedBox(height: 8),
                Center(child: Text('Tap + to create your first rule', style: GoogleFonts.inter(fontSize: 13, color: _mist.withValues(alpha: 0.6)))),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _rules.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _RuleCard(
                rule: _rules[i],
                sensorName: _sensorName(_rules[i]['sensorId'] as String? ?? ''),
                deviceName: _deviceName(((_rules[i]['action'] as Map<String, dynamic>?)?['deviceId']) as String? ?? ''),
                onToggle: () => _toggleRule(_rules[i]),
                onEdit: () => _editRule(_rules[i]),
                onDelete: () => _deleteRule(_rules[i]),
              ),
            ),
    );
  }

  Widget _buildSensorsTab() {
    if (_loading) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: _stream)));
    }
    return RefreshIndicator(
      color: _stream,
      backgroundColor: _submerged,
      onRefresh: _load,
      child: _sensors.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Icon(Icons.sensors, size: 64, color: _mist.withValues(alpha: 0.3)),
                const SizedBox(height: 16),
                Center(child: Text('No sensors yet', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600, color: _mist))),
                const SizedBox(height: 8),
                Center(child: Text('Tap + to add a sensor using its ID from your device code', style: GoogleFonts.inter(fontSize: 13, color: _mist.withValues(alpha: 0.6)))),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _sensors.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _SensorCard(
                sensor: _sensors[i],
                onView: () => _viewTelemetry(_sensors[i]),
                onDelete: () => _deleteSensor(_sensors[i]),
              ),
            ),
    );
  }

  Future<void> _toggleRule(Map<String, dynamic> rule) async {
    try {
      await _api.toggleRule(rule['_id'] as String);
      _load();
    } catch (e) {
      _showError('Failed to toggle rule');
    }
  }

  Future<void> _editRule(Map<String, dynamic> rule) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _submerged,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _RuleFormSheet(
        api: _api,
        sensors: _sensors,
        devices: _devices,
        initial: rule,
      ),
    );
    if (result == true) _load();
  }

  Future<void> _createRule() async {
    if (_sensors.isEmpty) {
      _showError('Create a sensor first');
      return;
    }
    if (_devices.isEmpty) {
      _showError('Claim a device first');
      return;
    }
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _submerged,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _RuleFormSheet(api: _api, sensors: _sensors, devices: _devices),
    );
    if (result == true) _load();
  }

  Future<void> _deleteRule(Map<String, dynamic> rule) async {
    final ok = await _confirm('Delete rule "${rule['name']}"?');
    if (ok != true) return;
    try {
      await _api.deleteRule(rule['_id'] as String);
      _load();
    } catch (e) {
      _showError('Failed to delete rule');
    }
  }

  Future<void> _createSensor() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _submerged,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SensorFormSheet(api: _api),
    );
    if (result == true) _load();
  }

  Future<void> _deleteSensor(Map<String, dynamic> sensor) async {
    final ok = await _confirm('Delete sensor "${sensor['name']}"?');
    if (ok != true) return;
    try {
      await _api.deleteSensor(sensor['sensorId'] as String);
      _load();
    } catch (e) {
      _showError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _viewTelemetry(Map<String, dynamic> sensor) async {
    List<Map<String, dynamic>> readings = [];
    try {
      final raw = await _api.getSensorTelemetry(sensor['sensorId'] as String, limit: 30);
      readings = raw.cast<Map<String, dynamic>>();
    } catch (e) {
      _showError('Failed to load telemetry');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: _submerged,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sensor['name'] as String, style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w700, color: _foam)),
                        Text('@${sensor['sensorId']}', style: GoogleFonts.inter(fontSize: 12, color: _mist)),
                      ],
                    ),
                  ),
                  Text('${readings.length} readings', style: GoogleFonts.inter(fontSize: 12, color: _mist)),
                ],
              ),
            ),
            Expanded(
              child: readings.isEmpty
                  ? Center(child: Text('No readings yet — waiting for device telemetry', style: GoogleFonts.inter(fontSize: 13, color: _mist)))
                  : ListView.separated(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: readings.length,
                      separatorBuilder: (_, _) => Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
                      itemBuilder: (_, i) {
                        final r = readings[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Text(_valText(r['value']), style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: _stream)),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_fmt(DateTime.tryParse(r['ts'] as String? ?? '')), style: GoogleFonts.inter(fontSize: 12, color: _mist))),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirm(String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _submerged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Confirm', style: GoogleFonts.inter(color: _foam, fontWeight: FontWeight.w600)),
        content: Text(message, style: GoogleFonts.inter(color: _mist)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.inter(color: _mist))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: GoogleFonts.inter(color: Colors.redAccent, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _addButtons() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AnimatedBuilder(
              animation: _tab,
              builder: (_, child) => FloatingActionButton.extended(
                onPressed: _tab.index == 0 ? _createRule : _createSensor,
                backgroundColor: _stream,
                foregroundColor: _well,
                icon: Icon(_tab.index == 0 ? Icons.add : Icons.sensors, size: 18),
                label: Text(_tab.index == 0 ? 'New Rule' : 'New Sensor', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  final Map<String, dynamic> rule;
  final String sensorName;
  final String deviceName;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _RuleCard({
    required this.rule,
    required this.sensorName,
    required this.deviceName,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = rule['enabled'] == true;
    final action = (rule['action'] as Map<String, dynamic>?) ?? {};
    final band = ((rule['condition'] as Map<String, dynamic>?)?['band']) as Map<String, dynamic>? ?? {};
    final min = band['min'];
    final max = band['max'];

    String cond;
    if (min != null && max != null) {
      cond = '${_valText(min)} ≤ value ≤ ${_valText(max)}';
    } else if (min != null) {
      cond = 'value ≥ ${_valText(min)}';
    } else {
      cond = 'value ≤ ${_valText(max)}';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: enabled ? _stream.withValues(alpha: 0.08) : _submerged,
        border: Border.all(color: enabled ? _stream.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(rule['name'] as String? ?? '', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: _foam)),
              ),
              IconButton(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 17, color: _mist),
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 17, color: _mist),
              ),
              Switch(
                value: enabled,
                activeThumbColor: _stream,
                onChanged: (_) => onToggle(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('IF $sensorName  ·  $cond', style: GoogleFonts.inter(fontSize: 12, color: _mist)),
          const SizedBox(height: 4),
          Text('THEN $deviceName · CH${action['channel']} → ${action['state']}',
              style: GoogleFonts.inter(fontSize: 12, color: enabled ? _stream : _mist)),
        ],
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  final Map<String, dynamic> sensor;
  final VoidCallback onView;
  final VoidCallback onDelete;

  const _SensorCard({required this.sensor, required this.onView, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final lastSeenRaw = sensor['lastSeen'];
    final lastSeen = lastSeenRaw is num ? DateTime.fromMillisecondsSinceEpoch(lastSeenRaw.toInt()) : null;
    final online = lastSeen != null && DateTime.now().difference(lastSeen).inMinutes < 60;
    final lastValue = sensor['lastValue'];

    String statusLine;
    Color statusColor;
    if (online) {
      statusLine = 'Live · updated ${_timeAgo(lastSeen)}';
      statusColor = _leaf;
    } else if (lastSeen != null) {
      statusLine = 'Offline · last seen ${_timeAgo(lastSeen)}';
      statusColor = _mist;
    } else {
      statusLine = 'Waiting for first reading';
      statusColor = _sunlight;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: _submerged,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor.withValues(alpha: 0.12),
              border: Border.all(color: statusColor.withValues(alpha: 0.5)),
            ),
            child: Icon(Icons.sensors, size: 20, color: statusColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sensor['name'] as String? ?? '', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: _foam)),
                const SizedBox(height: 2),
                Text('@${sensor['sensorId']}', style: GoogleFonts.inter(fontSize: 12, color: _mist)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 7, height: 7,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        statusLine,
                        style: GoogleFonts.inter(fontSize: 11, color: statusColor),
                      ),
                    ),
                  ],
                ),
                if (lastValue != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('Latest: ${_valText(lastValue)}', style: GoogleFonts.inter(fontSize: 11, color: _mist.withValues(alpha: 0.7))),
                  ),
              ],
            ),
          ),
          IconButton(onPressed: onView, icon: const Icon(Icons.show_chart, size: 18, color: _stream)),
          IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline, size: 18, color: _mist)),
        ],
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final Map<String, dynamic> log;
  final String deviceName;

  const _LogTile({required this.log, required this.deviceName});

  Color get _statusColor {
    switch (log['status']) {
      case 'executed':
        return _stream;
      case 'error':
        return Colors.redAccent;
      case 'blocked':
        return _sunlight;
      case 'stale':
      case 'emergency_stop':
        return _mist;
      default:
        return _mist;
    }
  }

  String get _statusText => (log['status'] as String? ?? '').replaceAll('_', ' ').toUpperCase();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: _statusColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: _statusColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                child: Text(_statusText, style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1, color: _statusColor)),
              ),
              const Spacer(),
              Text(_fmt(DateTime.tryParse(log['ts'] as String? ?? '')), style: GoogleFonts.inter(fontSize: 11, color: _mist)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$deviceName · CH${log['channel'] ?? '—'} ${log['action'] ?? ''}',
            style: GoogleFonts.inter(fontSize: 12, color: _foam),
          ),
          if (log['reason'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(log['reason'] as String, style: GoogleFonts.inter(fontSize: 11, color: _sunlight)),
            ),
        ],
      ),
    );
  }
}

class _RuleFormSheet extends StatefulWidget {
  final ApiService api;
  final List<Map<String, dynamic>> sensors;
  final List<Map<String, dynamic>> devices;
  final Map<String, dynamic>? initial;

  const _RuleFormSheet({required this.api, required this.sensors, required this.devices, this.initial});

  @override
  State<_RuleFormSheet> createState() => _RuleFormSheetState();
}

class _RuleFormSheetState extends State<_RuleFormSheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _threshold;
  late final TextEditingController _hyst;
  late final TextEditingController _cooldown;
  late final TextEditingController _freshness;

  String? _sensorId;
  String? _deviceId;
  int? _channel;
  String _state = 'ON';
  String _direction = 'below';
  double? _min;
  double? _max;
  bool _advancedOpen = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final rule = widget.initial;
    final action = (rule?['action'] as Map<String, dynamic>?) ?? {};
    final band = ((rule?['condition'] as Map<String, dynamic>?)?['band']) as Map<String, dynamic>? ?? {};
    final min = band['min'];
    final max = band['max'];
    _min = min != null ? double.tryParse(min.toString()) : null;
    _max = max != null ? double.tryParse(max.toString()) : null;
    if (_min != null && _max == null) _direction = 'above';
    if (_min == null && _max != null) _direction = 'below';
    if (_min != null && _max != null) _direction = 'below';

    _name = TextEditingController(text: rule?['name'] as String? ?? '');
    _threshold = TextEditingController(text: _primaryBound?.toString() ?? '');
    _hyst = TextEditingController(text: (band['hysteresis'] ?? 2).toString());
    _cooldown = TextEditingController(text: (rule?['cooldownS'] ?? 0).toString());
    _freshness = TextEditingController(text: (rule?['freshnessS'] ?? 3600).toString());
    _sensorId = rule?['sensorId'] as String? ?? widget.sensors.firstOrNull?['sensorId'];
    _deviceId = action['deviceId'] as String? ?? widget.devices.firstOrNull?['deviceId'];
    final ch = action['channel'];
    _channel = ch != null ? (ch as num).toInt() : 1;
    _state = (action['state'] as String? ?? 'ON').toUpperCase();
  }

  @override
  void dispose() {
    _name.dispose();
    _threshold.dispose();
    _hyst.dispose();
    _cooldown.dispose();
    _freshness.dispose();
    super.dispose();
  }

  double? get _primaryBound => _direction == 'above' ? _min : _max;

  void _setPrimaryBound(double? v) {
    if (_direction == 'above') {
      _min = v;
    } else {
      _max = v;
    }
  }

  int _channelsOf(String? deviceId) {
    for (final d in widget.devices) {
      if (d['deviceId'] == deviceId) return (d['channels'] as num?)?.toInt() ?? 4;
    }
    return 4;
  }

  String _sensorName(String? id) {
    for (final s in widget.sensors) {
      if (s['sensorId'] == id) return s['name'] as String;
    }
    return id ?? '—';
  }

  String _deviceName(String? id) {
    for (final d in widget.devices) {
      if (d['deviceId'] == id) return d['name'] as String;
    }
    return id ?? '—';
  }

  void _onDirectionChanged(String d) {
    setState(() {
      _direction = d;
      _threshold.text = _primaryBound?.toString() ?? '';
    });
  }

  void _onThresholdChanged(String t) {
    setState(() => _setPrimaryBound(double.tryParse(t.trim())));
  }

  String get _previewText {
    final dir = _direction == 'above' ? 'above' : 'below';
    final th = _primaryBound;
    return 'IF ${_sensorName(_sensorId)} is $dir${th != null ? ' ${_valText(th)}' : ''}  ·  THEN ${_deviceName(_deviceId)} CH$_channel → $_state';
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_sensorId == null || _deviceId == null || _channel == null) return;
    final min = _min;
    final max = _max;
    if (min == null && max == null) {
      _show('Enter a threshold value');
      return;
    }
    if (min != null && max != null && min >= max) {
      _show('The threshold values are not valid');
      return;
    }
    setState(() => _saving = true);
    try {
      final condition = {
        'band': {
          'min': min,
          'max': max,
          'hysteresis': double.tryParse(_hyst.text.trim()) ?? 2,
        },
      };
      final action = {'deviceId': _deviceId, 'channel': _channel, 'state': _state};
      final cooldown = int.tryParse(_cooldown.text.trim()) ?? 0;
      final freshness = int.tryParse(_freshness.text.trim()) ?? 3600;
      if (widget.initial != null) {
        await widget.api.updateRule(widget.initial!['_id'] as String,
            name: _name.text.trim(), sensorId: _sensorId!, condition: condition, action: action,
            cooldownS: cooldown, freshnessS: freshness);
      } else {
        await widget.api.createRule(name: _name.text.trim(), sensorId: _sensorId!, condition: condition,
            action: action, cooldownS: cooldown, freshnessS: freshness);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _show(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  void _show(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      backgroundColor: Colors.redAccent.shade200,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Form(
          key: _form,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            children: [
              Text(widget.initial == null ? 'New Rule' : 'Edit Rule', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w700, color: _foam)),
              const SizedBox(height: 4),
              Text('When a sensor crosses a value, control a device.', style: GoogleFonts.inter(fontSize: 12, color: _mist)),
              const SizedBox(height: 16),
              _previewCard(),
              _sectionTitle('WHEN'),
              _field(_name, 'Rule name', 'e.g. Pump on dry soil'),
              const SizedBox(height: 12),
              _label('Sensor'),
              DropdownButtonFormField<String>(
                initialValue: _sensorId,
                dropdownColor: _submerged,
                decoration: _dec(),
                items: widget.sensors.map((s) => DropdownMenuItem(value: s['sensorId'] as String, child: Text(s['name'] as String, style: GoogleFonts.inter(fontSize: 13, color: _foam)))).toList(),
                onChanged: (v) => setState(() => _sensorId = v),
              ),
              const SizedBox(height: 16),
              _label('Condition'),
              Row(
                children: [
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'above', label: Text('Above >')),
                      ButtonSegment(value: 'below', label: Text('Below <')),
                    ],
                    selected: {_direction},
                    onSelectionChanged: (s) => _onDirectionChanged(s.first),
                    style: _segmentedStyle(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _threshold,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: GoogleFonts.inter(fontSize: 14, color: _foam),
                      decoration: _dec().copyWith(
                        hintText: '40',
                        hintStyle: GoogleFonts.inter(fontSize: 13, color: _mist.withValues(alpha: 0.5)),
                      ),
                      onChanged: _onThresholdChanged,
                      validator: (v) {
                        final t = v?.trim() ?? '';
                        if (t.isEmpty) return 'required';
                        return double.tryParse(t) == null ? 'number' : null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _sectionTitle('THEN'),
              _label('Device'),
              DropdownButtonFormField<String>(
                initialValue: _deviceId,
                dropdownColor: _submerged,
                decoration: _dec(),
                items: widget.devices.map((d) => DropdownMenuItem(value: d['deviceId'] as String, child: Text(d['name'] as String, style: GoogleFonts.inter(fontSize: 13, color: _foam)))).toList(),
                onChanged: (v) => setState(() => _deviceId = v),
              ),
              const SizedBox(height: 12),
              _label('Channel'),
              Wrap(
                spacing: 8,
                children: List.generate(_channelsOf(_deviceId), (i) {
                  final ch = i + 1;
                  return ChoiceChip(
                    label: Text('CH $ch', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _channel == ch ? _well : _mist)),
                    selected: _channel == ch,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _channel = ch),
                    selectedColor: _stream,
                    backgroundColor: Colors.transparent,
                    side: BorderSide(color: _channel == ch ? _stream : Colors.white.withValues(alpha: 0.1)),
                  );
                }),
              ),
              const SizedBox(height: 16),
              _label('Action'),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: ['ON', 'OFF']
                    .map((s) => ButtonSegment(value: s, label: Text(s)))
                    .toList(),
                selected: {_state},
                onSelectionChanged: (s) => setState(() => _state = s.first),
                style: _segmentedStyle(),
              ),
              const SizedBox(height: 20),
              _advancedSection(),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: _stream, foregroundColor: _well, padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _well))
                    : Text(widget.initial == null ? 'Create Rule' : 'Save Rule', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: _stream.withValues(alpha: 0.08),
        border: Border.all(color: _stream.withValues(alpha: 0.3)),
      ),
      child: Text(_previewText, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _foam)),
    );
  }

  Widget _advancedSection() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        title: Row(
          children: [
            Icon(Icons.tune, size: 18, color: _mist),
            const SizedBox(width: 10),
            Text('Advanced Settings', style: GoogleFonts.inter(fontSize: 13, color: _mist)),
          ],
        ),
        initiallyExpanded: _advancedOpen,
        onExpansionChanged: (v) => setState(() => _advancedOpen = v),
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        iconColor: _mist,
        collapsedIconColor: _mist,
        shape: const Border(),
        collapsedShape: const Border(),
        children: [
          if (_min != null && _max != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Extended: fires when ${_valText(_min)} ≤ value ≤ ${_valText(_max)}',
                  style: GoogleFonts.inter(fontSize: 11, color: _sunlight)),
            ),
          _field(_hyst, 'Hysteresis', 're-arm margin'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _field(_cooldown, 'Cooldown (s)', 'min gap between fires')),
              const SizedBox(width: 10),
              Expanded(child: _field(_freshness, 'Freshness (s)', 'max sensor age')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(t, style: GoogleFonts.sora(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: _foam)),
    );
  }

  Widget _label(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(t.toUpperCase(), style: GoogleFonts.inter(fontSize: 10, letterSpacing: 1.2, color: _mist.withValues(alpha: 0.7))),
    );
  }

  ButtonStyle _segmentedStyle() {
    return SegmentedButton.styleFrom(
      textStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600),
      selectedBackgroundColor: _stream.withValues(alpha: 0.2),
      selectedForegroundColor: _stream,
      foregroundColor: _mist,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
  }

  InputDecoration _dec() => InputDecoration(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _stream.withValues(alpha: 0.5))),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );

  Widget _field(TextEditingController c, String label, String hint) {
    return TextFormField(
      controller: c,
      keyboardType: label == 'Rule name' ? TextInputType.text : const TextInputType.numberWithOptions(decimal: true),
      style: GoogleFonts.inter(fontSize: 13, color: _foam),
      decoration: _dec().copyWith(
        labelText: label,
        labelStyle: GoogleFonts.inter(fontSize: 13, color: _mist),
        hintText: hint,
        hintStyle: GoogleFonts.inter(fontSize: 12, color: _mist.withValues(alpha: 0.5)),
      ),
      validator: (v) {
        final t = v?.trim() ?? '';
        if (label == 'Rule name') return t.isEmpty ? 'required' : null;
        if (t.isNotEmpty && double.tryParse(t) == null) return 'number';
        return null;
      },
    );
  }
}

class _SensorFormSheet extends StatefulWidget {
  final ApiService api;

  const _SensorFormSheet({required this.api});

  @override
  State<_SensorFormSheet> createState() => _SensorFormSheetState();
}

class _SensorFormSheetState extends State<_SensorFormSheet> {
  final _form = GlobalKey<FormState>();
  final _idPattern = RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,39}$');
  late final TextEditingController _name;
  late final TextEditingController _id;
  bool _saving = false;
  bool _loadingDiscovered = false;
  List<Map<String, dynamic>> _discovered = [];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _id = TextEditingController();
    _loadDiscovered();
  }

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  Future<void> _loadDiscovered() async {
    setState(() => _loadingDiscovered = true);
    try {
      final raw = await widget.api.getDiscoveredSensors();
      if (mounted) setState(() => _discovered = raw.cast<Map<String, dynamic>>());
    } catch (_) {
      if (mounted) _discovered = [];
    } finally {
      if (mounted) setState(() => _loadingDiscovered = false);
    }
  }

  void _useDetected(Map<String, dynamic> d) {
    setState(() {
      final id = d['sensorId'] as String;
      _id.text = id;
      if (_name.text.trim().isEmpty) _name.text = _friendlyName(id);
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.api.createSensor(
        name: _name.text.trim(),
        sensorId: _id.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Form(
          key: _form,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            children: [
              Text('New Sensor', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w700, color: _foam)),
              const SizedBox(height: 4),
              Text('Name the reading your device already reports. Only the Name and Sensor ID matter.', style: GoogleFonts.inter(fontSize: 12, color: _mist)),
              const SizedBox(height: 16),
              _detectedSection(),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                keyboardType: TextInputType.text,
                style: GoogleFonts.inter(fontSize: 13, color: _foam),
                decoration: _dec('Sensor name').copyWith(hintText: 'e.g. Soil Moisture', hintStyle: GoogleFonts.inter(fontSize: 12, color: _mist.withValues(alpha: 0.5))),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _id,
                keyboardType: TextInputType.text,
                style: GoogleFonts.inter(fontSize: 13, color: _foam),
                decoration: _dec('Sensor ID').copyWith(
                  hintText: 'e.g. soil_1',
                  hintStyle: GoogleFonts.inter(fontSize: 12, color: _mist.withValues(alpha: 0.5)),
                  helperText: 'The ID used in your device code',
                  helperStyle: GoogleFonts.inter(fontSize: 10, color: _mist.withValues(alpha: 0.6)),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty) return 'required';
                  if (!_idPattern.hasMatch(t)) return 'letters, numbers, _ or - only';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: _stream, foregroundColor: _well, padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _well))
                    : Text('Create Sensor', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detectedSection() {
    if (_loadingDiscovered) {
      return const Center(child: Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: _stream))));
    }
    if (_discovered.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: _stream.withValues(alpha: 0.06),
        border: Border.all(color: _stream.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(
              children: [
                Icon(Icons.radar, size: 16, color: _stream),
                const SizedBox(width: 8),
                Text('Detected on your devices', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _stream)),
                const Spacer(),
                IconButton(
                  onPressed: _loadDiscovered,
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh, size: 16, color: _stream),
                ),
              ],
            ),
          ),
          ..._discovered.take(5).map((d) {
            final id = d['sensorId'] as String;
            return InkWell(
              onTap: () => _useDetected(d),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.add_circle_outline, size: 16, color: _stream),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('@$id', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _foam)),
                    ),
                    Text('${_valText(d['value'])} · ${d['deviceName'] ?? ''}', style: GoogleFonts.inter(fontSize: 11, color: _mist)),
                  ],
                ),
              ),
            );
          }),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: Text('Tap a reading to fill in its ID', style: GoogleFonts.inter(fontSize: 10, color: _mist.withValues(alpha: 0.6))),
          ),
        ],
      ),
    );
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(fontSize: 13, color: _mist),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _stream.withValues(alpha: 0.5))),
      );
}
