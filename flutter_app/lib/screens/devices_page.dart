import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../theme.dart';
import '../services/api_service.dart';
import '../main.dart' show kServerIp, kProtocol, channels, ChannelConfig;
import '../widgets/stees_widgets.dart';
import 'add_device_screen.dart';

class DevicesPage extends StatefulWidget {
  final ValueChanged<int> onNavigateToTab;
  const DevicesPage({super.key, required this.onNavigateToTab});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> with TickerProviderStateMixin {
  final _api = ApiService();
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  String? _selectedDeviceId;
  int _deviceChannels = 4;

  io.Socket? _socket;
  bool _connected = false;
  Timer? _statusTimer;

  final List<bool> channelStates = [false, false, false, false];
  final List<bool> _channelLoading = [false, false, false, false];
  final List<AnimationController> _rippleControllers = [];
  final List<AnimationController> _entranceControllers = [];

  void _setConnected(bool connected) {
    if (!mounted || _connected == connected) return;
    setState(() => _connected = connected);
  }

  void _setChannelState(int index, bool newState, {bool applyRipple = true}) {
    if (index < 0 || index >= _deviceChannels) return;
    setState(() => channelStates[index] = newState);
    if (applyRipple) {
      if (newState) {
        _rippleControllers[index].repeat(reverse: true);
      } else {
        _rippleControllers[index].stop();
        _rippleControllers[index].reset();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 4; i++) {
      _rippleControllers.add(AnimationController(vsync: this, duration: const Duration(milliseconds: 1500)));
      _entranceControllers.add(AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 400 + i * 100),
      )..forward());
    }
    _loadDevices();
    _connectSocket();
    _statusTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetchStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
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
          _loading = false;
        });
        if (_selectedDeviceId == null && _devices.isNotEmpty) {
          _selectDevice(_devices.first['deviceId'] as String);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectDevice(String deviceId) {
    final device = _devices.firstWhere(
      (d) => d['deviceId'] == deviceId,
      orElse: () => _devices.first,
    );
    setState(() {
      _selectedDeviceId = deviceId;
      _deviceChannels = device['channels'] as int? ?? 4;
    });
    _fetchStatus();
  }

  Map<String, dynamic> _getDevice(String deviceId) {    return _devices.firstWhere((d) => d['deviceId'] == deviceId, orElse: () => _devices.first);
  }

  int get _activeCount {
    var n = 0;
    for (int i = 0; i < _deviceChannels; i++) {
      if (channelStates[i]) n++;
    }
    return n;
  }

  void _connectSocket() {
    _socket = io.io('$kProtocol://$kServerIp', <String, dynamic>{
      'transports': ['websocket'],
      'secure': true,
      'autoConnect': false,
    });

    _socket?.onConnect((_) {
      if (mounted) setState(() { /* socket to backend is up, but device status determines the pill */ });
    });
    _socket?.onDisconnect((_) => _setConnected(false));
    _socket?.onConnectError((_) => _setConnected(false));

    _socket?.on('device_status', (data) {
      if (!mounted) return;
      final map = data as Map<String, dynamic>;
      final deviceId = map['deviceId'] as String?;
      if (deviceId != null && deviceId != _selectedDeviceId) return;
      final online = map['online'] == true;
      _setConnected(online);
    });

    _socket?.on('device_update', (data) {
      if (!mounted) return;
      final map = data as Map<String, dynamic>;
      final deviceId = map['deviceId'] as String?;
      if (deviceId != null && deviceId != _selectedDeviceId) return;
      final channel = map['channel'] as int;
      final index = channel - 1;
      if (index < 0 || index >= _deviceChannels) return;
      final state = map['state'] as String;
      _setChannelState(index, state == 'ON');
    });

    _socket?.connect();
  }

  Future<void> _fetchStatus() async {
    if (_selectedDeviceId == null) return;
    try {
      final data = await _api.getStatus(_selectedDeviceId!);
      _setConnected(data['online'] == true);
      setState(() {
        for (int i = 0; i < _deviceChannels; i++) {
          final on = data['POWER${i + 1}'] == 'ON';
          channelStates[i] = on;
          if (on) _rippleControllers[i].repeat(reverse: true);
        }
      });
    } catch (e) {
      _setConnected(false);
      _showError('Failed to fetch status');
    }
  }

  Future<void> _toggle(int channel, bool targetState) async {
    if (_selectedDeviceId == null) return;
    final index = channel - 1;
    final prev = channelStates[index];
    _setChannelState(index, targetState);
    setState(() => _channelLoading[index] = true);
    try {
      await _api.control(_selectedDeviceId!, channel, targetState ? 'ON' : 'OFF');
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (msg.toLowerCase().contains('not connected') || msg.toLowerCase().contains('offline') || msg.toLowerCase().contains('powered off')) {
        _setConnected(false);
      }
      _setChannelState(index, prev);
      _showError(msg);
    } finally {
      if (mounted) setState(() => _channelLoading[index] = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: Colors.redAccent.shade200,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        margin: const EdgeInsets.all(AppSpacing.lg),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _openAddDevice() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
    );
    if (added == true) _loadDevices();
  }

  void _openSchedules() {
    widget.onNavigateToTab(2);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SteesLoading();
    if (_devices.isEmpty) return _buildEmpty();
    return _buildDeviceView();
  }

  Widget _buildEmpty() {
    return SteesEmpty(
      icon: Icons.water_drop_outlined,
      title: 'No devices yet',
      subtitle: 'Claim a Sonoff controller to start\nmanaging your irrigation zones.',
      action: FilledButton.icon(
        onPressed: _openAddDevice,
        icon: const Icon(Icons.add, size: 18),
        label: Text('Add Device', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.stream,
          foregroundColor: AppColors.well,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
    );
  }

  Widget _buildDeviceView() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPageTitle(),
          _buildDeviceRow(),
          const SizedBox(height: AppSpacing.lg),
          _buildHeroCard(),
          const SizedBox(height: AppSpacing.lg),
          _buildGridHeader(),
          const SizedBox(height: AppSpacing.md),
          _buildRelayGrid(),
          const SizedBox(height: AppSpacing.lg),
          _buildBottomActions(),
        ],
      ),
    );
  }

  Widget _buildPageTitle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm),
      child: Text(
        'DEVICES',
        style: GoogleFonts.sora(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.8,
          color: AppColors.mist,
        ),
      ),
    );
  }

  Widget _buildDeviceRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Expanded(child: _buildSelectorList()),
          const SizedBox(width: AppSpacing.sm),
          _buildAddButton(),
        ],
      ),
    );
  }

  Widget _buildSelectorList() {
    if (_devices.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _devices.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (_, i) {
          final d = _devices[i];
          final id = d['deviceId'] as String;
          final name = d['name'] as String;
          final ch = d['channels'] as int? ?? 4;
          final selected = id == _selectedDeviceId;
          return GestureDetector(
            onTap: () => _selectDevice(id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                color: selected ? AppColors.surfaceLight : AppColors.surface,
                border: Border.all(
                  color: selected ? AppColors.stream.withValues(alpha: 0.6) : AppColors.border,
                  width: selected ? 1.5 : 1,
                ),
                boxShadow: selected ? [BoxShadow(color: AppColors.stream.withValues(alpha: 0.15), blurRadius: 10)] : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sensors, size: 14, color: selected ? AppColors.stream : AppColors.mist),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Text(
                    '$name · $ch',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.foam : AppColors.mist,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: _openAddDevice,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.stream.withValues(alpha: 0.1),
          border: Border.all(color: AppColors.stream.withValues(alpha: 0.4)),
        ),
        child: const Icon(Icons.add, size: 18, color: AppColors.stream),
      ),
    );
  }

  Widget _buildHeroCard() {
    final device = _getDevice(_selectedDeviceId ?? _devices.first['deviceId'] as String);
    final name = device['name'] as String? ?? _selectedDeviceId ?? '';
    final channelsCount = device['channels'] as int? ?? _deviceChannels;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_connected ? AppColors.stream.withValues(alpha: 0.14) : AppColors.submerged, AppColors.surface],
        ),
        border: Border.all(color: _connected ? AppColors.stream.withValues(alpha: 0.25) : AppColors.border),
        boxShadow: _connected ? AppShadows.glow : AppShadows.card,
      ),
      child: Row(
        children: [
          _HeroIcon(connected: _connected),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.foam),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '$channelsCount zones · $_activeCount flowing',
                  style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.mist),
                ),
              ],
            ),
          ),
          _StatusPill(connected: _connected),
        ],
      ),
    );
  }

  Widget _buildGridHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Row(
        children: [
          Text(
            'ZONES',
            style: GoogleFonts.sora(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.8,
              color: AppColors.mist,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              '$_deviceChannels',
              style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.mist),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelayGrid() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: _deviceChannels == 1 ? 1 : 2,
        mainAxisSpacing: AppSpacing.lg,
        crossAxisSpacing: AppSpacing.lg,
        childAspectRatio: _deviceChannels == 1 ? 1.25 : 1.05,
        children: List.generate(
          _deviceChannels,
          (i) => _WaterCard(
            index: i,
            channel: i + 1,
            config: channels[i],
            isOn: channelStates[i],
            loading: _channelLoading[i],
            entrance: _entranceControllers[i],
            ripple: _rippleControllers[i],
            onToggle: (val) => _toggle(i + 1, val),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: _openSchedules,
          icon: const Icon(Icons.schedule, size: 16),
          label: Text('Schedules', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.foam,
            side: BorderSide(color: AppColors.stream.withValues(alpha: 0.35)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
          ),
        ),
      ),
    );
  }
}

class _HeroIcon extends StatelessWidget {
  final bool connected;
  const _HeroIcon({required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connected
              ? [AppColors.stream.withValues(alpha: 0.25), AppColors.leaf.withValues(alpha: 0.05)]
              : [AppColors.submerged, AppColors.surface],
        ),
        border: Border.all(color: connected ? AppColors.stream.withValues(alpha: 0.35) : AppColors.border),
      ),
      child: Icon(
        connected ? Icons.water_drop : Icons.water_drop_outlined,
        size: 22,
        color: connected ? AppColors.stream : AppColors.mist,
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool connected;
  const _StatusPill({required this.connected});

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppColors.leaf : AppColors.mist;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: connected ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 5)] : null,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            connected ? 'Online' : 'Offline',
            style: GoogleFonts.sora(fontSize: 10, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Water Card (relay control)
// ──────────────────────────────────────────────────────────────

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
    final scale = Curves.easeOutBack.transform(entrance.value);
    return Transform.scale(
      scale: scale,
      child: _WaterCardBody(
        channel: channel,
        config: config,
        isOn: isOn,
        loading: loading,
        ripple: ripple,
        onToggle: onToggle,
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
  late AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
  }

  @override
  void dispose() { _press.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final isOn = widget.isOn;

    return GestureDetector(
      onTapDown: (_) => _press.forward(),
      onTapUp: (_) { _press.reverse(); widget.onToggle(!isOn); },
      onTapCancel: () => _press.reverse(),
      child: AnimatedScale(
        scale: 1.0 - _press.value * 0.03,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.xxl),
            gradient: isOn
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [c.color.withValues(alpha: 0.12), c.color.withValues(alpha: 0.04)],
                  )
                : null,
            color: isOn ? null : AppColors.surface,
            border: Border.all(
              color: isOn ? c.color.withValues(alpha: 0.3) : AppColors.border,
              width: 1.5,
            ),
            boxShadow: isOn
                ? [BoxShadow(color: c.color.withValues(alpha: 0.12), blurRadius: 20, spreadRadius: -2)]
                : AppShadows.card,
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    c.subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                      color: isOn ? c.color.withValues(alpha: 0.8) : AppColors.mist.withValues(alpha: 0.5),
                    ),
                  ),
                  _DropletToggle(
                    isOn: isOn,
                    loading: widget.loading,
                    activeColor: c.color,
                    onTap: () => widget.onToggle(!isOn),
                  ),
                ],
              ),
              const Spacer(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: isOn
                    ? _RippleIcon(icon: c.icon, color: c.color, ripple: widget.ripple)
                    : Icon(c.icon, key: const ValueKey('off'), size: 24, color: AppColors.mist.withValues(alpha: 0.3)),
              ),
              const SizedBox(height: AppSpacing.sm),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: GoogleFonts.sora(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isOn ? c.color : AppColors.foam,
                ),
                child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 4),
              _FlowPill(isOn: isOn, color: c.color),
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
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: 36,
        height: 21,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: isOn ? activeColor : AppColors.surfaceLight,
          boxShadow: isOn ? [BoxShadow(color: activeColor.withValues(alpha: 0.3), blurRadius: 8)] : null,
        ),
        padding: const EdgeInsets.all(2.5),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: isOn ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOn ? AppColors.well : AppColors.mist.withValues(alpha: 0.5),
            ),
            child: Center(
              child: loading
                  ? SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.6, color: isOn ? activeColor : AppColors.mist))
                  : Icon(isOn ? Icons.water_drop : Icons.water_drop_outlined, size: 9, color: isOn ? activeColor : AppColors.well),
            ),
          ),
        ),
      ),
    );
  }
}

class _RippleIcon extends AnimatedWidget {
  final IconData icon;
  final Color color;
  const _RippleIcon({required this.icon, required this.color, required AnimationController ripple})
      : super(listenable: ripple);

  @override
  Widget build(BuildContext context) {
    final ctrl = listenable as AnimationController;
    final scale = 1.0 + ctrl.value * 0.08;
    final opacity = 0.6 + ctrl.value * 0.4;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (ctrl.value > 0.1)
          Transform.scale(
            scale: 1.0 + ctrl.value * 0.4,
            child: Opacity(
              opacity: (1.0 - ctrl.value) * 0.25,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
              ),
            ),
          ),
        Transform.scale(scale: scale, child: Opacity(opacity: opacity, child: Icon(icon, size: 24, color: color))),
      ],
    );
  }
}

class _FlowPill extends StatelessWidget {
  final bool isOn;
  final Color color;
  const _FlowPill({required this.isOn, required this.color});

  @override
  Widget build(BuildContext context) {
    final bg = isOn ? color.withValues(alpha: 0.14) : AppColors.surfaceLight;
    final fg = isOn ? color : AppColors.mist.withValues(alpha: 0.5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fg,
              boxShadow: isOn ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4)] : null,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            isOn ? 'FLOWING' : 'DRY',
            style: GoogleFonts.sora(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: fg),
          ),
        ],
      ),
    );
  }
}
