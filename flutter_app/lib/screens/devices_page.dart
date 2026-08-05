import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../theme.dart';
import '../services/api_service.dart';
import '../main.dart' show kServerIp, kProtocol, channels, ChannelConfig;
import 'add_device_screen.dart';
import 'schedule_list_screen.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

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

  final List<bool> channelStates = [false, false, false, false];
  final List<bool> _channelLoading = [false, false, false, false];
  final List<AnimationController> _rippleControllers = [];
  final List<AnimationController> _entranceControllers = [];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 4; i++) {
      _rippleControllers.add(AnimationController(vsync: this, duration: const Duration(milliseconds: 1500)));
      _entranceControllers.add(AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 500 + i * 120),
      )..forward());
    }
    _loadDevices();
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

  String _deviceName(String deviceId) {
    for (final d in _devices) {
      if (d['deviceId'] == deviceId) return d['name'] as String? ?? deviceId;
    }
    return deviceId;
  }

  void _connectSocket() {
    _socket = io.io('$kProtocol://$kServerIp', <String, dynamic>{
      'transports': ['websocket'],
      'secure': true,
      'autoConnect': false,
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
    } catch (e) {
      _showError('Failed to fetch status');
    }
  }

  Future<void> _toggle(int channel, bool targetState) async {
    if (_selectedDeviceId == null) return;
    final index = channel - 1;
    final prev = channelStates[index];
    setState(() {
      channelStates[index] = targetState;
      _channelLoading[index] = true;
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ScheduleListScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.stream),
        ),
      );
    }
    return _devices.isEmpty ? _buildEmpty() : _buildDeviceView();
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.water_drop_outlined, size: 64, color: AppColors.mist.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            'No irrigation devices yet',
            style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.mist),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to add your first controller',
            style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _openAddDevice,
            icon: const Icon(Icons.add, size: 18),
            label: Text('Add Device', style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.stream,
              foregroundColor: AppColors.well,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceView() {
    return Column(
      children: [
        _buildDeviceHeader(),
        _buildDeviceSelector(),
        if (_devices.length <= 1)
          const SizedBox(height: 8)
        else
          const SizedBox.shrink(),
        Expanded(child: _buildRelayGrid()),
        _buildBottomActions(),
      ],
    );
  }

  Widget _buildDeviceHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DEVICES',
                  style: GoogleFonts.sora(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                    color: AppColors.mist,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _selectedDeviceId != null ? _deviceName(_selectedDeviceId!) : '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.foam),
                ),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _connected ? AppColors.stream : AppColors.mist.withValues(alpha: 0.3),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            onPressed: _openAddDevice,
            icon: const Icon(Icons.add_circle_outline, size: 22, color: AppColors.stream),
            tooltip: 'Add device',
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSelector() {
    if (_devices.length <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
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
              onTap: () => _selectDevice(id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: selected ? AppColors.stream : Colors.transparent,
                  border: Border.all(
                    color: selected ? AppColors.stream : AppColors.mist.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  name,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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

  Widget _buildRelayGrid() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: _deviceChannels == 1 ? 1 : 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: _deviceChannels == 1 ? 1.0 : 0.85,
        physics: const BouncingScrollPhysics(),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: _openSchedules,
          icon: const Icon(Icons.schedule, size: 16),
          label: Text('Schedules', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.foam,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
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
        onTapDown: (_) => _hover.forward(),
        onTapUp: (_) => _hover.reverse(),
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
                  Text(
                    c.subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                      color: widget.isOn ? c.color.withValues(alpha: 0.8) : AppColors.mist.withValues(alpha: 0.6),
                    ),
                  ),
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
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: widget.isOn ? c.color : AppColors.foam,
                ),
                child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.2,
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
        width: w,
        height: h,
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
            width: h - 6,
            height: h - 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOn ? AppColors.well : AppColors.mist.withValues(alpha: 0.6),
              boxShadow: isOn
                  ? [BoxShadow(color: activeColor.withValues(alpha: 0.4), blurRadius: 8)]
                  : null,
            ),
            child: Center(
              child: loading
                  ? SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2, color: isOn ? activeColor : AppColors.mist),
                    )
                  : Icon(
                      isOn ? Icons.water_drop : Icons.water_drop_outlined,
                      size: 11,
                      color: isOn ? activeColor : AppColors.well,
                    ),
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
  const _WaterRippleIcon({required this.icon, required this.color, required AnimationController ripple})
      : super(listenable: ripple);

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
                width: 46,
                height: 46,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
              ),
            ),
          ),
        Transform.scale(
          scale: scale,
          child: Opacity(opacity: opacity, child: Icon(icon, size: 34, color: color)),
        ),
      ],
    );
  }
}
