import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'theme.dart';
import 'services/auth_service.dart';
import 'services/api_service.dart';
import 'screens/login_screen.dart';
import 'screens/add_device_screen.dart';
import 'screens/add_sensor_screen.dart';
import 'screens/rule_form_screen.dart';
import 'screens/sensor_rules_screen.dart';
import 'screens/schedule_list_screen.dart';

const String kServerIp = 'sonoff-3na2.onrender.com';
const String kProtocol = 'https';

void main() {
  runApp(const SteesApp());
}

class SteesApp extends StatelessWidget {
  const SteesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'STEES',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.well,
        colorScheme: ColorScheme.dark(
          primary: AppColors.stream,
          secondary: AppColors.leaf,
          surface: AppColors.submerged,
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        useMaterial3: true,
      ),
      home: const AuthGate(),
      routes: { '/home': (_) => const AuthGate() },
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _auth = AuthService();
  bool _checking = true;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final loggedIn = await _auth.isLoggedIn();
    if (mounted) setState(() { _loggedIn = loggedIn; _checking = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [AppColors.well, Color(0xFF0F2332), AppColors.well],
            ),
          ),
          child: Center(
            child: TweenAnimationBuilder(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 1200),
              builder: (_, val, _) => Opacity(
                opacity: val,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SteesLogo(size: 72),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.stream.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return _loggedIn ? const HomePage() : const LoginScreen();
  }
}

class _SteesLogo extends StatelessWidget {
  final double size;
  const _SteesLogo({this.size = 56});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [AppColors.stream, AppColors.leaf],
        ),
        boxShadow: [
          BoxShadow(color: AppColors.stream.withValues(alpha: 0.3), blurRadius: 20, spreadRadius: 0),
        ],
      ),
      child: Center(
        child: Text('S', style: GoogleFonts.sora(fontSize: size * 0.5, fontWeight: FontWeight.w700, color: AppColors.well)),
      ),
    );
  }
}

class _ActionRail extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onSensors;
  final VoidCallback onSchedules;
  final VoidCallback onLogout;
  const _ActionRail({
    required this.onAdd,
    required this.onSensors,
    required this.onSchedules,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.submerged,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RailCell(
            icon: Icons.add,
            color: AppColors.stream,
            filled: true,
            tooltip: 'Add device',
            onTap: onAdd,
          ),
          _railDivider(),
          _RailCell(
            icon: Icons.sensors,
            color: AppColors.leaf,
            tooltip: 'Add sensor',
            onTap: onSensors,
          ),
          _railDivider(),
          _RailCell(
            icon: Icons.schedule,
            color: AppColors.sunlight,
            tooltip: 'Schedules',
            onTap: onSchedules,
          ),
          _railDivider(),
          _RailCell(
            icon: Icons.logout,
            color: const Color(0xFFFF7A7A),
            tooltip: 'Log out',
            onTap: onLogout,
          ),
        ],
      ),
    );
  }

  Widget _railDivider() {
    return Container(width: 1, height: 22, color: Colors.white.withValues(alpha: 0.08));
  }
}

class _RailCell extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool filled;
  final String tooltip;
  final VoidCallback onTap;
  const _RailCell({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: filled ? color.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 18, color: filled ? color : color.withValues(alpha: 0.9)),
        ),
      ),
    );
  }
}

class ChannelConfig {
  final String name;
  final IconData icon;
  final Color color;
  final String subtitle;
  const ChannelConfig(this.name, this.icon, this.color, this.subtitle);
}

const channels = [
  ChannelConfig('Zone 1', Icons.water_drop, Color(0xFF2DD4BF), 'CH 1'),
  ChannelConfig('Zone 2', Icons.water_drop, Color(0xFF2DD4BF), 'CH 2'),
  ChannelConfig('Zone 3', Icons.water_drop, Color(0xFF2DD4BF), 'CH 3'),
  ChannelConfig('Zone 4', Icons.water_drop, Color(0xFF2DD4BF), 'CH 4'),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final List<bool> channelStates = [false, false, false, false];
  final List<bool> _loading = [false, false, false, false];
  final List<AnimationController> _rippleControllers = [];
  final List<AnimationController> _entranceControllers = [];
  final _auth = AuthService();
  final _api = ApiService();
  bool _connected = false;
  bool _initialLoading = true;
  io.Socket? _socket;
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _sensors = [];
  String? _selectedDeviceId;
  int _deviceChannels = 4;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 4; i++) {
      _rippleControllers.add(AnimationController(vsync: this, duration: const Duration(milliseconds: 1500)));
      _entranceControllers.add(AnimationController(
        vsync: this, duration: Duration(milliseconds: 500 + i * 120),
      )..forward());
    }
    _loadDevices();
    _loadSensors();
    _connectSocket();
  }

  @override
  void dispose() {
    for (final c in _rippleControllers) { c.dispose(); }
    for (final c in _entranceControllers) { c.dispose(); }
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await _api.getDevices();
      if (mounted) {
        setState(() {
          _devices = devices.cast<Map<String, dynamic>>();
          if (_devices.isNotEmpty) {
            _selectedDeviceId = _devices.first['deviceId'] as String;
            _deviceChannels = _devices.first['channels'] as int? ?? 4;
          }
          _initialLoading = false;
        });
        if (_selectedDeviceId != null) _fetchStatus();
      }
    } catch (e) {
      if (mounted) setState(() => _initialLoading = false);
    }
  }

  Future<void> _loadSensors() async {
    try {
      final sensors = await _api.getSensors();
      if (mounted) setState(() => _sensors = sensors.cast<Map<String, dynamic>>());
    } catch (e) {
      // Non-fatal; sensors are refreshed on return from AddSensorScreen.
    }
  }

  String _deviceName(String deviceId) {
    for (final d in _devices) {
      if (d['deviceId'] == deviceId) return d['name'] as String? ?? deviceId;
    }
    return deviceId;
  }

  int _deviceChannelsOf(String deviceId) {
    for (final d in _devices) {
      if (d['deviceId'] == deviceId) return d['channels'] as int? ?? 4;
    }
    return 4;
  }

  void _openAddSensor() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddSensorScreen()),
    );
    if (added == true) _loadSensors();
  }

  void _openSchedules() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ScheduleListScreen()),
    );
  }

  void _connectSocket() {
    _socket = io.io('$kProtocol://$kServerIp', <String, dynamic>{
      'transports': ['websocket'], 'secure': true, 'autoConnect': false,
    });

    _socket?.onConnect((_) { if (mounted) setState(() => _connected = true); });
    _socket?.onDisconnect((_) { if (mounted) setState(() => _connected = false); });
    _socket?.onConnectError((_) { if (mounted) setState(() => _connected = false); });

    _socket?.on('device_update', (data) {
      if (!mounted) return;
      final map = data as Map<String, dynamic>;
      final deviceId = map['deviceId'] as String?;
      if (deviceId != null && deviceId != _selectedDeviceId) return;
      final channel = map['channel'] as int;
      final index = channel - 1;
      if (index < 0 || index >= _deviceChannels) return;
      final state = map['state'] as String;
      final newState = state == 'ON';
      setState(() => channelStates[index] = newState);
      if (newState) {
        _rippleControllers[index].repeat(reverse: true);
      } else {
        _rippleControllers[index].stop();
        _rippleControllers[index].reset();
      }
    });

    _socket?.on('sensor_update', (data) {
      if (!mounted) return;
      final map = data as Map<String, dynamic>;
      final sensorId = map['sensorId'] as String?;
      if (sensorId == null) return;
      // Only update a sensor already displayed (it belongs to the currently
      // selected device). Ignore everything else.
      int idx = -1;
      for (int i = 0; i < _sensors.length; i++) {
        if (_sensors[i]['sensorId'] == sensorId) { idx = i; break; }
      }
      if (idx < 0) return;
      final value = map['value'];
      final lastSeen = map['lastSeen'];
      setState(() {
        if (value != null) _sensors[idx]['lastValue'] = value;
        if (lastSeen != null) {
          _sensors[idx]['lastSeen'] = lastSeen;
          // A fresh reading means the sensor is online.
          _sensors[idx]['status'] = 'online';
        }
      });
    });

    _socket?.connect();
  }

  Future<void> _fetchStatus() async {
    if (_selectedDeviceId == null) return;
    try {
      final data = await _api.getStatus(_selectedDeviceId!);
      setState(() {
        for (int i = 0; i < _deviceChannels; i++) {
          final on = data['POWER${i + 1}'] == 'ON';
          channelStates[i] = on;
          if (on) _rippleControllers[i].repeat(reverse: true);
        }
      });
    } catch (e) { _showError('Failed to fetch status'); }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: Colors.redAccent.shade200,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _toggle(int channel, bool targetState) async {
    if (_selectedDeviceId == null) return;
    final index = channel - 1;
    final prev = channelStates[index];
    setState(() {
      channelStates[index] = targetState;
      _loading[index] = true;
      if (targetState) {
        _rippleControllers[index].repeat(reverse: true);
      } else {
        _rippleControllers[index].stop();
        _rippleControllers[index].reset();
      }
    });
    try {
      await _api.control(_selectedDeviceId!, channel, targetState ? 'ON' : 'OFF');
    } catch (e) {
      setState(() {
        channelStates[index] = prev;
        if (prev) {
          _rippleControllers[index].repeat(reverse: true);
        } else {
          _rippleControllers[index].stop();
          _rippleControllers[index].reset();
        }
      });
      _showError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading[index] = false);
    }
  }

  Future<void> _logout() async {
    await _auth.clear();
    if (mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AuthGate()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [AppColors.well, Color(0xFF0F2332), AppColors.well],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildDeviceSelector(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 6),
      child: Row(
        children: [
          const _SteesLogo(size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('STEES', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.foam, letterSpacing: 2)),
                Text('Smart Irrigation', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 10, color: AppColors.mist, letterSpacing: 0.5)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _ConnectionPip(connected: _connected),
          const SizedBox(width: 10),
          _ActionRail(
            onAdd: () async {
              final added = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
              );
              if (added == true) _loadDevices();
            },
            onSensors: _openAddSensor,
            onSchedules: _openSchedules,
            onLogout: _logout,
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSelector() {
    if (_devices.length <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: SizedBox(
        height: 34,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _devices.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final d = _devices[i];
            final id = d['deviceId'] as String;
            final name = d['name'] as String;
            final selected = id == _selectedDeviceId;
            return GestureDetector(
              onTap: () { setState(() { _selectedDeviceId = id; _deviceChannels = d['channels'] as int? ?? 4; }); _fetchStatus(); },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: selected ? AppColors.stream : Colors.transparent,
                  border: Border.all(color: selected ? AppColors.stream : AppColors.mist.withValues(alpha: 0.2)),
                ),
                child: Text(
                  name,
                  style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: selected ? AppColors.well : AppColors.mist,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_initialLoading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream)),
      );
    }
    if (_devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.water_drop_outlined, size: 64, color: AppColors.mist.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text('No irrigation devices yet', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.mist)),
            const SizedBox(height: 8),
            Text('Tap + to add your first controller', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist.withValues(alpha: 0.6))),
          ],
        ),
      );
    }
    final visibleSensors = _sensors
        .where((s) => s['deviceId'] == _selectedDeviceId)
        .toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (visibleSensors.isNotEmpty) ...[
            _buildSensorsHeader(count: visibleSensors.length),
            const SizedBox(height: 10),
            ...visibleSensors.map(_buildSensorCard),
            const SizedBox(height: 20),
          ],
          Expanded(
            child: GridView.count(
              crossAxisCount: _deviceChannels == 1 ? 1 : 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: _deviceChannels == 1 ? 1.0 : 0.85,
              physics: const BouncingScrollPhysics(),
              children: List.generate(_deviceChannels, (i) => _WaterCard(
                index: i,
                channel: i + 1,
                config: channels[i],
                isOn: channelStates[i],
                loading: _loading[i],
                entrance: _entranceControllers[i],
                ripple: _rippleControllers[i],
                onToggle: (val) => _toggle(i + 1, val),
              )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorsHeader({int count = 0}) {
    return Row(
      children: [
        Text('SENSORS', style: GoogleFonts.sora(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 2, color: AppColors.mist)),
        const Spacer(),
        Text('$count linked', style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.6))),
      ],
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
                width: 36, height: 36,
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
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
                    Text('ID: $id', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: online ? AppColors.leaf.withValues(alpha: 0.12) : AppColors.mist.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(online ? 'Online' : 'Offline',
                  style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600,
                    color: online ? AppColors.leaf : AppColors.mist)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.settings_input_hdmi, size: 13, color: AppColors.mist.withValues(alpha: 0.7)),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Device: $deviceName', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.8))),
              ),
              if (value != null) ...[
                Text('Value: ',
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.8))),
                Text(_fmtValue(value),
                  style: GoogleFonts.sora(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.stream)),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => SensorRulesScreen(sensorId: id, sensorName: name)),
                    );
                    _loadSensors();
                  },
                  icon: const Icon(Icons.rule, size: 16),
                  label: Text('Rules', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.foam,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    final ch = _deviceChannelsOf(s['deviceId'] as String? ?? '');
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => RuleFormScreen(sensorId: id, sensorName: name, maxChannel: ch)),
                    );
                    _loadSensors();
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: Text('Add Rule', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.stream,
                    foregroundColor: AppColors.well,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
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

class _WaterCard extends AnimatedWidget {
  final int index;
  final int channel;
  final ChannelConfig config;
  final bool isOn;
  final bool loading;
  final AnimationController entrance;
  final AnimationController ripple;
  final ValueChanged<bool> onToggle;

  const _WaterCard({
    required this.index,
    required this.channel,
    required this.config,
    required this.isOn,
    required this.loading,
    required this.entrance,
    required this.ripple,
    required this.onToggle,
  }) : super(listenable: entrance);

  @override
  Widget build(BuildContext context) {
    final anim = entrance;
    final scale = Curves.easeOutBack.transform(anim.value);
    final opacity = anim.value;

    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: opacity,
        child: _WaterCardBody(
          channel: channel,
          config: config,
          isOn: isOn,
          loading: loading,
          ripple: ripple,
          onToggle: onToggle,
        ),
      ),
    );
  }
}

class _WaterCardBody extends StatefulWidget {
  final int channel;
  final ChannelConfig config;
  final bool isOn;
  final bool loading;
  final AnimationController ripple;
  final ValueChanged<bool> onToggle;

  const _WaterCardBody({
    required this.channel,
    required this.config,
    required this.isOn,
    required this.loading,
    required this.ripple,
    required this.onToggle,
  });

  @override
  State<_WaterCardBody> createState() => _WaterCardBodyState();
}

class _WaterCardBodyState extends State<_WaterCardBody> with SingleTickerProviderStateMixin {
  late AnimationController _hover;

  @override
  void initState() {
    super.initState();
    _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() { _hover.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;

    return AnimatedBuilder(
      animation: _hover,
      builder: (_, child) => Transform.scale(scale: 1.0 + _hover.value * 0.02, child: child),
      child: GestureDetector(
        onTapDown: (_) => _hover.forward(), onTapUp: (_) => _hover.reverse(),
        onTapCancel: () => _hover.reverse(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: widget.isOn ? c.color.withValues(alpha: 0.1) : AppColors.submerged,
            border: Border.all(
              color: widget.isOn ? c.color.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.06),
              width: 1.5,
            ),
            boxShadow: widget.isOn
                ? [BoxShadow(color: c.color.withValues(alpha: 0.15), blurRadius: 24, spreadRadius: 0)]
                : [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(c.subtitle, style: GoogleFonts.inter(
                    fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1.2,
                    color: widget.isOn ? c.color.withValues(alpha: 0.8) : AppColors.mist.withValues(alpha: 0.6),
                  )),
                  _DropletToggle(
                    isOn: widget.isOn,
                    loading: widget.loading,
                    activeColor: c.color,
                    onTap: () => widget.onToggle(!widget.isOn),
                  ),
                ],
              ),
              const Spacer(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: widget.isOn
                    ? _WaterRippleIcon(icon: c.icon, color: c.color, ripple: widget.ripple)
                    : Icon(c.icon, key: const ValueKey('off'), size: 34, color: AppColors.mist.withValues(alpha: 0.4)),
              ),
              const SizedBox(height: 12),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: GoogleFonts.sora(
                  fontSize: 14, fontWeight: FontWeight.w600,
                  color: widget.isOn ? c.color : AppColors.foam,
                ),
                child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: GoogleFonts.inter(
                  fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 1.2,
                  color: widget.isOn ? c.color.withValues(alpha: 0.7) : AppColors.mist.withValues(alpha: 0.5),
                ),
                child: Text(widget.isOn ? 'FLOWING' : 'DRY'),
              ),
            ],
          ),
        ),
      ),
    );
  }

}

class _DropletToggle extends StatelessWidget {
  final bool isOn;
  final bool loading;
  final Color activeColor;
  final VoidCallback onTap;

  const _DropletToggle({required this.isOn, required this.loading, required this.activeColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final w = 44.0;
    final h = 26.0;

    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        width: w, height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(h / 2),
          color: isOn ? activeColor : Colors.white.withValues(alpha: 0.1),
        ),
        padding: const EdgeInsets.all(3),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: isOn ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: h - 6, height: h - 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOn ? AppColors.well : AppColors.mist.withValues(alpha: 0.6),
              boxShadow: isOn
                  ? [BoxShadow(color: activeColor.withValues(alpha: 0.4), blurRadius: 8)]
                  : null,
            ),
            child: Center(
              child: loading
                  ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: isOn ? activeColor : AppColors.mist))
                  : Icon(isOn ? Icons.water_drop : Icons.water_drop_outlined, size: 11, color: isOn ? activeColor : AppColors.well),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaterRippleIcon extends AnimatedWidget {
  final IconData icon;
  final Color color;
  const _WaterRippleIcon({required this.icon, required this.color, required AnimationController ripple}) : super(listenable: ripple);

  @override
  Widget build(BuildContext context) {
    final ctrl = listenable as AnimationController;
    final scale = 1.0 + ctrl.value * 0.1;
    final opacity = 0.6 + ctrl.value * 0.4;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (ctrl.value > 0.1)
          Transform.scale(
            scale: 1.0 + ctrl.value * 0.4,
            child: Opacity(
              opacity: (1.0 - ctrl.value) * 0.3,
              child: Container(
                width: 46, height: 46,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
              ),
            ),
          ),
        Transform.scale(scale: scale, child: Opacity(opacity: opacity, child: Icon(icon, size: 34, color: color))),
      ],
    );
  }
}

class _ConnectionPip extends StatefulWidget {
  final bool connected;
  const _ConnectionPip({required this.connected});

  @override
  State<_ConnectionPip> createState() => _ConnectionPipState();
}

class _ConnectionPipState extends State<_ConnectionPip> with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    if (widget.connected) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_ConnectionPip old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) {
      _pulse.repeat(reverse: true);
    } else if (!widget.connected && old.connected) {
      _pulse.stop();
      _pulse.reset();
    }
  }

  @override
  void dispose() { _pulse.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, child) => Container(
        width: 10 + (_pulse.value * (widget.connected ? 3 : 0)),
        height: 10 + (_pulse.value * (widget.connected ? 3 : 0)),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.connected ? AppColors.stream : AppColors.mist.withValues(alpha: 0.3),
          boxShadow: widget.connected
              ? [BoxShadow(color: AppColors.stream.withValues(alpha: 0.3 + _pulse.value * 0.3), blurRadius: 8 + _pulse.value * 6)]
              : null,
        ),
      ),
      child: const SizedBox.shrink(),
    );
  }
}
