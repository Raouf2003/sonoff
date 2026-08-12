import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../services/auth_service.dart';
import '../services/device_repository_service.dart';
import '../services/device_transport.dart';
import '../main.dart' show kServerIp, kProtocol, channels, ChannelConfig;
import '../widgets/stees_widgets.dart';
import 'add_device_screen.dart';

class DevicesPage extends StatefulWidget {
  final ValueChanged<int> onNavigateToTab;
  const DevicesPage({super.key, required this.onNavigateToTab})
      : testRepository = null,
        testSocketFactory = null;

  /// Test seam: injects a fake repository / socket connector so widget tests
  /// exercise the relay gate and cloud→local list fallback without network.
  @visibleForTesting
  const DevicesPage.test({
    super.key,
    required this.onNavigateToTab,
    this.testRepository,
    this.testSocketFactory,
  });

  final DeviceRepositoryService? testRepository;
  final io.Socket Function(String url, Map<String, dynamic> options)?
      testSocketFactory;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage>
    with TickerProviderStateMixin {
  late final DeviceRepositoryService _repository =
      widget.testRepository ?? DeviceRepositoryService();
  DeviceTransportSource? _lastTransportSource;
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  bool _loadError = false;
  String? _selectedDeviceId;
  int _deviceChannels = 4;

  io.Socket? _socket;
  bool _connected = false;
  Timer? _statusTimer;

  static const int _maxPollFailures = 3;
  int _pollFailures = 0;

  final List<bool> channelStates = [false, false, false, false];
  final List<bool> _channelLoading = [false, false, false, false];
  final Set<String> _pendingRelays = {};
  final List<AnimationController> _rippleControllers = [];
  final List<AnimationController> _entranceControllers = [];

  void _setConnected(bool connected) {
    if (!mounted || _connected == connected) return;
    setState(() => _connected = connected);
  }

  // The socket reflects CLOUD reachability only. When the last successful
  // operation ran on the LAN, a cloud outage must not flip the card offline —
  // the device is reachable and controllable locally. Polling re-establishes
  // truth in every other case.
  void _socketDown() {
    if (_lastTransportSource == DeviceTransportSource.local) return;
    _setConnected(false);
  }

  // Stops every ripple so an OFF channel is never left animating.
  void _stopRipples() {
    for (final c in _rippleControllers) {
      c.stop();
      c.reset();
    }
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
      _rippleControllers.add(
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1500),
        ),
      );
      _entranceControllers.add(
        AnimationController(
          vsync: this,
          duration: Duration(milliseconds: 400 + i * 100),
        )..forward(),
      );
    }
    _loadDevices();
    _connectSocket();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _fetchStatus(silent: true),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    for (final c in _rippleControllers) {
      c.dispose();
    }
    for (final c in _entranceControllers) {
      c.dispose();
    }
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      // The repository serves the registered list cloud-first and falls back
      // to the local cache on availability failures, so a cloud outage never
      // blanks the page or breaks Local Mode discovery.
      final devices = await _repository.getDevices();
      if (mounted) {
        setState(() {
          _devices = devices.cast<Map<String, dynamic>>();
          _loading = false;
          _loadError = false;
        });
        if (_selectedDeviceId == null && _devices.isNotEmpty) {
          _selectDevice(_devices.first['deviceId'] as String);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          // Distinguish "could not load" from "nothing to show": an empty
          // device list is a happy state, a failed fetch needs a retry.
          _loadError = _devices.isEmpty;
        });
      }
    }
  }

  void _retryLoad() {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    _loadDevices();
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
    // Switch context fully: previous device's states and animations must not
    // leak into the newly selected device's grid.
    for (int i = 0; i < 4; i++) {
      channelStates[i] = false;
      _channelLoading[i] = false;
    }
    _stopRipples();
    _fetchStatus();
  }

  Map<String, dynamic> _getDevice(String deviceId) {
    return _devices.firstWhere(
      (d) => d['deviceId'] == deviceId,
      orElse: () => _devices.first,
    );
  }

  int get _activeCount {
    var n = 0;
    for (int i = 0; i < _deviceChannels; i++) {
      if (channelStates[i]) n++;
    }
    return n;
  }

  void _connectSocket() {
    _connectSocketAsync();
  }

  Future<void> _connectSocketAsync() async {
    final token = await AuthService().getToken();
    final socketFactory = widget.testSocketFactory ?? io.io;
    _socket = socketFactory('$kProtocol://$kServerIp', <String, dynamic>{
      'transports': ['websocket'],
      'secure': true,
      'autoConnect': false,
      if (token != null) 'auth': <String, dynamic>{'token': token},
    });

    _socket?.onConnect((_) {
      // Socket is up. Device liveness is driven by device_status/polling, so
      // there is nothing to flip here — no-op on purpose.
    });
    _socket?.onDisconnect((_) => _socketDown());
    _socket?.onConnectError((_) => _socketDown());

    // Live events are fire-and-forget wake-ups, never the sole source of
    // truth. Casts are guarded so a malformed payload can't crash the handler.
    _socket?.on('device_status', (data) {
      try {
        if (!mounted) return;
        _pollFailures = 0;
        final map = data as Map<String, dynamic>;
        final deviceId = map['deviceId'] as String?;
        if (deviceId != null && deviceId != _selectedDeviceId) return;
        final online = map['online'] == true;
        // A socket event is always cloud truth.
        _lastTransportSource = DeviceTransportSource.cloud;
        _setConnected(online);
      } catch (_) {
        // Ignore malformed event; polling re-establishes truth.
      }
    });

    _socket?.on('device_update', (data) {
      try {
        if (!mounted) return;
        _pollFailures = 0;
        final map = data as Map<String, dynamic>;
        final deviceId = map['deviceId'] as String?;
        if (deviceId != null && deviceId != _selectedDeviceId) return;
        final channel = map['channel'] as int;
        final index = channel - 1;
        if (index < 0 || index >= _deviceChannels) return;
        final state = map['state'] as String;
        _setChannelState(index, state == 'ON');
      } catch (_) {
        // Ignore malformed event; polling re-establishes truth.
      }
    });

    _socket?.connect();
  }

  Future<void> _fetchStatus({bool silent = false}) async {
    if (_selectedDeviceId == null) return;
    try {
      final data = await _repository.getStatus(_selectedDeviceId!);
      _pollFailures = 0;
      _setConnected(data['online'] == true);
      _lastTransportSource = _repository.lastSource;
      setState(() {
        for (int i = 0; i < _deviceChannels; i++) {
          final on = data['POWER${i + 1}'] == 'ON';
          channelStates[i] = on;
          if (on) {
            _rippleControllers[i].repeat(reverse: true);
          } else {
            _rippleControllers[i].stop();
            _rippleControllers[i].reset();
          }
        }
      });
    } catch (e) {
      if (!silent) {
        _setConnected(false);
        _showError('Failed to fetch status');
        return;
      }
      // Background polling: stay silent until several consecutive failures.
      _pollFailures++;
      if (_pollFailures >= _maxPollFailures) {
        _setConnected(false);
      }
    }
  }

  Future<void> _toggle(int channel, bool targetState) async {
    if (_selectedDeviceId == null) return;
    // No `_connected` gate here: the repository owns reachability. This lets a
    // tap reach the transport layer so the cloud→local fallback can run when
    // the backend/socket is down; the card visuals still reflect `_connected`.
    final key = '${_selectedDeviceId}_$channel';
    if (_pendingRelays.contains(key)) return;
    final index = channel - 1;
    final prev = channelStates[index];
    _pendingRelays.add(key);
    _setChannelState(index, targetState);
    setState(() => _channelLoading[index] = true);
    try {
      await _repository.control(
        _selectedDeviceId!,
        channel,
        targetState ? 'ON' : 'OFF',
      );
      _lastTransportSource = _repository.lastSource;
      // A relay command that succeeded means the device IS reachable.
      _setConnected(true);
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (msg.toLowerCase().contains('not connected') ||
          msg.toLowerCase().contains('offline') ||
          msg.toLowerCase().contains('powered off')) {
        _setConnected(false);
      }
      _setChannelState(index, prev);
      _showError(msg);
    } finally {
      _pendingRelays.remove(key);
      if (mounted) setState(() => _channelLoading[index] = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        margin: const EdgeInsets.all(AppSpacing.lg),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _openAddDevice() async {
    final added = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const AddDeviceScreen()));
    if (added == true) _loadDevices();
  }

  void _openSchedules() {
    widget.onNavigateToTab(2);
  }

  // Channel label/icon for any channel count. The 4-entry default palette
  // covers the common case; additional relays fall back to a generated entry so
  // a device claimed with more channels never indexes past the list.
  ChannelConfig _configFor(int index) {
    if (index < channels.length) return channels[index];
    return ChannelConfig(
      'Zone ${index + 1}',
      Icons.water_drop,
      const Color(0xFF0F766E),
      'CHANNEL ${index + 1}',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SteesLoading();
    if (_loadError) return _buildError(context.steesColors);
    if (_devices.isEmpty) return _buildEmpty(context.steesColors);
    return _buildDeviceView(context.steesColors);
  }

  Widget _buildError(SteesColors colors) {
    // Uses the shared error component so the failure state is visually
    // consistent with the rest of the app.
    return SteesError(
      title: 'Could not load devices',
      subtitle: 'Check your connection and try again.',
      onRetry: _retryLoad,
    );
  }

  Widget _buildEmpty(SteesColors colors) {
    return SteesEmpty(
      icon: Icons.water_drop_outlined,
      title: 'No devices yet',
      subtitle:
          'Claim a Sonoff controller to start\nmanaging your irrigation zones.',
      action: FilledButton.icon(
        onPressed: _openAddDevice,
        icon: const Icon(Icons.add, size: 18),
        label: Text(
          'Add Device',
          style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: colors.stream,
          foregroundColor: colors.well,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceView(SteesColors colors) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPageTitle(colors),
          _buildDeviceRow(colors),
          const SizedBox(height: AppSpacing.lg),
          _buildHeroCard(colors),
          const SizedBox(height: AppSpacing.lg),
          _buildGridHeader(colors),
          const SizedBox(height: AppSpacing.md),
          _buildRelayGrid(),
          const SizedBox(height: AppSpacing.lg),
          _buildBottomActions(colors),
        ],
      ),
    );
  }

  Widget _buildPageTitle(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.sm,
      ),
      child: Text(
        'DEVICES',
        style: GoogleFonts.sora(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.8,
          color: colors.mist,
        ),
      ),
    );
  }

  Widget _buildDeviceRow(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Expanded(child: _buildSelectorList(colors)),
          const SizedBox(width: AppSpacing.sm),
          _buildAddButton(colors),
        ],
      ),
    );
  }

  Widget _buildSelectorList(SteesColors colors) {
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
                color: colors.submerged,
                border: Border.all(
                  color: selected
                      ? colors.stream.withValues(alpha: 0.6)
                      : colors.border,
                  width: selected ? 1.5 : 1,
                ),
                boxShadow: [AppShadows.cardShadow(colors.border)],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.memory,
                    size: 14,
                    color: selected ? colors.stream : colors.mist,
                  ),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Text(
                    '$name · $ch',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? colors.foam : colors.mist,
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

  Widget _buildAddButton(SteesColors colors) {
    return GestureDetector(
      onTap: _openAddDevice,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.stream.withValues(alpha: 0.1),
          border: Border.all(color: colors.stream.withValues(alpha: 0.4)),
        ),
        child: Icon(Icons.add, size: 18, color: colors.stream),
      ),
    );
  }

  Widget _buildHeroCard(SteesColors colors) {
    final device = _getDevice(
      _selectedDeviceId ?? _devices.first['deviceId'] as String,
    );
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
          colors: [colors.submerged, colors.surface],
        ),
        border: Border.all(
          color: _connected
              ? colors.stream.withValues(alpha: 0.25)
              : colors.border,
        ),
        boxShadow: [AppShadows.cardShadow(colors.border)],
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
                  style: GoogleFonts.sora(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: colors.foam,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  // When the device is unreachable the flowing count is not
                  // live truth (it is only the last-known relay states), so the
                  // summary stops implying current flow and shows zones alone.
                  _connected
                      ? '$channelsCount zones · $_activeCount flowing'
                      : '$channelsCount zones',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.mist,
                  ),
                ),
              ],
            ),
          ),
          _StatusPill(connected: _connected, source: _lastTransportSource),
        ],
      ),
    );
  }

  Widget _buildGridHeader(SteesColors colors) {
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
              color: colors.mist,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: colors.surfaceLight,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              '$_deviceChannels',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: colors.mist,
              ),
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
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: _deviceChannels == 1 ? 1.4 : 1.15,
        children: List.generate(
          _deviceChannels,
          (i) => _WaterCard(
            index: i,
            channel: i + 1,
            config: _configFor(i),
            isOn: channelStates[i],
            loading: _channelLoading[i],
            offline: !_connected,
            entrance: _entranceControllers[i],
            ripple: _rippleControllers[i],
            onToggle: (val) => _toggle(i + 1, val),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomActions(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: _openSchedules,
          icon: const Icon(Icons.schedule, size: 16),
          label: Text(
            'Schedules',
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.foam,
            side: BorderSide(color: colors.stream.withValues(alpha: 0.35)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
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
    final colors = context.steesColors;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connected
              ? [
                  colors.stream.withValues(alpha: 0.25),
                  colors.leaf.withValues(alpha: 0.05),
                ]
              : [colors.submerged, colors.surface],
        ),
        border: Border.all(
          color: connected
              ? colors.stream.withValues(alpha: 0.35)
              : colors.border,
        ),
      ),
      child: Icon(
        connected ? Icons.water_drop : Icons.water_drop_outlined,
        size: 22,
        color: connected ? colors.stream : colors.mist,
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool connected;
  final DeviceTransportSource? source;
  const _StatusPill({required this.connected, this.source});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    // 'LAN' is the subtle Local Mode indicator: same styling as 'Online' so the
    // relay UI itself never changes; only the label differentiates transport.
    final isLocal = connected && source == DeviceTransportSource.local;
    final color = connected ? colors.leaf : colors.mist;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: 5,
      ),
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
              boxShadow: connected
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.35),
                        blurRadius: 3,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            isLocal
                ? 'LAN'
                : connected
                    ? 'Online'
                    : 'Offline',
            style: GoogleFonts.sora(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
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
  final bool offline;
  final AnimationController entrance;
  final AnimationController ripple;
  final ValueChanged<bool> onToggle;

  const _WaterCard({
    required this.index,
    required this.channel,
    required this.config,
    required this.isOn,
    required this.loading,
    required this.offline,
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
        offline: offline,
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
  final bool offline;
  final AnimationController ripple;
  final ValueChanged<bool> onToggle;

  const _WaterCardBody({
    required this.channel,
    required this.config,
    required this.isOn,
    required this.loading,
    required this.offline,
    required this.ripple,
    required this.onToggle,
  });

  @override
  State<_WaterCardBody> createState() => _WaterCardBodyState();
}

class _WaterCardBodyState extends State<_WaterCardBody>
    with SingleTickerProviderStateMixin {
  late AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final isOn = widget.isOn;
    final colors = context.steesColors;
    // Only loading disables taps: offline cards stay tappable so the cloud→local
    // fallback can run when the socket/backend is down. Offline still renders
    // grey via widget.offline below.
    final disabled = widget.loading;

    return GestureDetector(
      onTapDown: disabled ? null : (_) => _press.forward(),
      onTapUp: disabled
          ? null
          : (_) {
              _press.reverse();
              widget.onToggle(!isOn);
            },
      onTapCancel: () => _press.reverse(),
      child: AnimatedScale(
        scale: 1.0 - _press.value * 0.03,
        duration: const Duration(milliseconds: 120),
child: AnimatedOpacity(
            opacity: widget.loading ? 0.6 : (widget.offline ? 0.72 : 1.0),
            duration: const Duration(milliseconds: 200),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOut,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                color: widget.offline
                    ? colors.submerged.withValues(alpha: 0.5)
                    : colors.submerged,
                border: Border.all(
                  color: widget.offline
                      ? colors.mist.withValues(alpha: 0.5)
                      : isOn
                          ? colors.leaf
                          : colors.border,
                  width: widget.offline ? 1 : (isOn ? 1.2 : 1),
                ),
                boxShadow: [AppShadows.cardShadow(colors.border)],
              ),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        c.subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                          color: widget.offline
                              ? colors.mist.withValues(alpha: 0.6)
                              : colors.mist,
                        ),
                      ),
                      _DropletToggle(
                        isOn: isOn,
                        loading: widget.loading,
                        disabled: widget.offline,
                        activeColor: colors.leaf,
                        onTap: disabled ? null : () => widget.onToggle(!isOn),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 34,
                        child: Center(
                          child: widget.offline
                              ? Icon(
                                  c.icon,
                                  size: 30,
                                  color: isOn
                                      ? colors.leaf.withValues(alpha: 0.6)
                                      : colors.mist.withValues(alpha: 0.35),
                                )
                              : _RippleIcon(
                                  icon: c.icon,
                                  size: 30,
                                  color: isOn
                                      ? colors.leaf
                                      : colors.mist.withValues(alpha: 0.45),
                                  ripple: widget.ripple,
                                ),
                        ),
                      ),
                    ],
                  ),
                  if (widget.offline)
                    const _OfflineBadge()
                  else
                    _FlowPill(isOn: isOn, color: colors.leaf),
                ],
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
  final double size;
  const _RippleIcon({
    required this.icon,
    required this.color,
    required AnimationController ripple,
    this.size = 24,
  }) : super(listenable: ripple);

  @override
  Widget build(BuildContext context) {
    final ctrl = listenable as AnimationController;
    final scale = 1.0 + ctrl.value * 0.08;
    final opacity = 0.6 + ctrl.value * 0.4;
    final ring = size + 12;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (ctrl.value > 0.1)
          Transform.scale(
            scale: 1.0 + ctrl.value * 0.4,
            child: Opacity(
              opacity: (1.0 - ctrl.value) * 0.25,
              child: Container(
                width: ring,
                height: ring,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                ),
              ),
            ),
          ),
        Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: Icon(icon, size: size, color: color),
          ),
        ),
      ],
    );
  }
}

class _DropletToggle extends StatelessWidget {
  final bool isOn;
  final bool loading;
  final bool disabled;
  final Color activeColor;
  final VoidCallback? onTap;

  const _DropletToggle({
    required this.isOn,
    required this.loading,
    required this.activeColor,
    this.disabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return GestureDetector(
      // `disabled` here is purely visual (grey when offline). Taps always
      // reach the repository so the local fallback can run while offline.
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: 36,
        height: 21,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: disabled
              ? colors.surfaceLight.withValues(alpha: 0.5)
              : isOn
                  ? activeColor
                  : colors.surfaceLight,
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
              color: disabled
                  ? colors.mist.withValues(alpha: 0.4)
                  : isOn
                      ? colors.well
                      : colors.mist.withValues(alpha: 0.5),
            ),
            child: Center(
              child: loading
                  ? SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: isOn ? activeColor : colors.mist,
                      ),
                    )
                  : Icon(
                      isOn ? Icons.water_drop : Icons.water_drop_outlined,
                      size: 9,
                      color: disabled
                          ? colors.mist.withValues(alpha: 0.4)
                          : isOn
                              ? activeColor
                              : colors.well,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.mist.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 9, color: colors.mist.withValues(alpha: 0.8)),
          const SizedBox(width: 4),
          Text(
            'OFFLINE',
            style: GoogleFonts.sora(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: colors.mist.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlowPill extends StatelessWidget {
  final bool isOn;
  final Color color;
  const _FlowPill({required this.isOn, required this.color});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final bg = isOn ? color.withValues(alpha: 0.14) : colors.surfaceLight;
    final fg = isOn ? color : colors.mist.withValues(alpha: 0.7);
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
            decoration: BoxDecoration(shape: BoxShape.circle, color: fg),
          ),
          const SizedBox(width: 4),
          Text(
            isOn ? 'FLOWING' : 'DRY',
            style: GoogleFonts.sora(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
