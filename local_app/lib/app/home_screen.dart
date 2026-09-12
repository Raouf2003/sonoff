import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../connection/ap_connect_screen.dart';
import '../connection/session.dart';
import '../theme/theme_controller.dart';
import '../devices/channel_state_machine.dart';
import '../devices/device_profile.dart';
import '../devices/device_repository.dart';
import '../devices/device_setup.dart';
import '../theme/app_theme.dart';
import '../transport/clock_sync.dart';
import '../transport/device_transport.dart';
import '../widgets/stees_widgets.dart';
import 'diagnostics_screen.dart';

const _reducerConfig = ChannelReducerConfig(
  localHold: Duration(seconds: 60),
  cloudFreshWindow: Duration(seconds: 30),
  evidenceFreshWindow: Duration(seconds: 120),
  pendingIndicatorDelay: Duration(milliseconds: 700),
  maxPollFailures: 3,
  pollBackoff: Duration(seconds: 5),
  offlineDebounce: Duration(seconds: 2),
);

const _pollInterval = Duration(seconds: 1);
const _tapTimeout = Duration(seconds: 6);

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.password,
    LocalDeviceRepository? repository,
    ClockSync? clock,
    ThemeController? themes,
    SessionState? session,
    String? profileId,
  })  : _repository = repository,
        _clock = clock,
        _themes = themes,
        _session = session,
        profileId = profileId ?? DeviceProfile.defaultId;

  final String deviceId;
  final String deviceName;
  final String? password;
  final LocalDeviceRepository? _repository;
  final ClockSync? _clock;
  final ThemeController? _themes;
  final SessionState? _session;
  final String? profileId;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final LocalDeviceRepository _repo;
  late final ClockSync _clock;
  DateTime? _lastSyncAt;

  final Map<int, ChannelState> _channels = {
    for (var i = 1; i <= 4; i++) i: const ChannelState(),
  };
  DeviceConnectivityState _connectivity = const DeviceConnectivityState();
  final Set<int> _busy = {};
  final Map<int, Timer> _pendingTimers = {};
  final Map<int, Timer> _tapTimeouts = {};
  Timer? _pollTimer;
  int _opSeq = 0;
  bool _loading = true;
  String? _pollError;
  DeviceClock _deviceClock = const DeviceClock(health: ClockHealth.invalid);
  bool _clockChecking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repo = widget._repository ?? LocalDeviceRepository();
    _clock = widget._clock ?? ClockSync();
    _refresh(initial: true);
    _startPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _refresh();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    for (final t in _pendingTimers.values) {
      t.cancel();
    }
    for (final t in _tapTimeouts.values) {
      t.cancel();
    }
    super.dispose();
  }

  DateTime get _now => DateTime.now();

  String _timeOfDay(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }

  void _applyChannel(int channel, ChannelEvent event) {
    final current = _channels[channel] ?? const ChannelState();
    final result = channelReduce(current, event, _reducerConfig, now: _now);
    setState(() => _channels[channel] = result.state);
    for (final effect in result.effects) {
      if (effect == FollowUp.startPendingTimer) _startPendingTimer(channel);
      if (effect == FollowUp.cancelPendingTimer) _cancelPendingTimer(channel);
    }
    if (result.committed) {
      final report = _reportOf(channel);
      if (report != null) {
        _applyDevice(LocalReport(report));
      }
    }
  }

  ChannelReport? _reportOf(int channel) {
    final s = _channels[channel]?.reported;
    return ChannelReport(s);
  }

  void _applyDevice(ChannelEvent event) {
    final result = deviceReduce(_connectivity, event, _reducerConfig, now: _now);
    if (result.state != _connectivity) {
      setState(() => _connectivity = result.state);
    }
  }

  void _startPendingTimer(int channel) {
    _cancelPendingTimer(channel);
    _pendingTimers[channel] = Timer(
      _reducerConfig.pendingIndicatorDelay,
      () {
        final s = _channels[channel];
        if (s != null && s.pending) {
          setState(() => _channels[channel] = s.copyWith(showIndicator: true));
        }
      },
    );
  }

  void _cancelPendingTimer(int channel) {
    _pendingTimers.remove(channel)?.cancel();
  }

  int _channelCount = 4;

  Future<void> _refresh({bool initial = false}) async {
    try {
      final result = await _repo.getStatus(widget.deviceId, password: widget.password);
      if (result.channels.isNotEmpty) {
        final detected = result.channels.keys.reduce((a, b) => a > b ? a : b);
        if (detected != _channelCount) {
          setState(() => _channelCount = detected.clamp(1, 4));
        }
      }
      for (var ch = 1; ch <= _channelCount; ch++) {
        final r = result.channels[ch];
        _applyChannel(ch, LocalReport(r ?? const ChannelReport(null)));
      }
      _applyDevice(const LocalReport(ChannelReport('ON')));
      if (mounted) {
        setState(() {
          _pollError = null;
          _lastSyncAt = _now;
        });
      }
    } catch (e) {
      debugPrint('[LOCAL][POLL] failed: $e');
      _applyDevice(PollFailure(_now));
      if (!mounted) return;
      setState(() => _pollError = '$e');
    } finally {
      if (initial && mounted) {
        setState(() => _loading = false);
        _checkClock();
      }
    }
  }

  Future<void> _checkClock() async {
    if (_clockChecking) return;
    setState(() => _clockChecking = true);
    try {
      final clock = await _clock.readClock(kApAddress, password: widget.password);
      if (mounted) setState(() => _deviceClock = clock);
    } finally {
      if (mounted) setState(() => _clockChecking = false);
    }
  }

  Future<void> _syncClock() async {
    setState(() => _clockChecking = true);
    try {
      final clock = await _clock.ensureSynced(kApAddress, password: widget.password);
      if (mounted) {
        setState(() => _deviceClock = clock);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clock synchronized from phone.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _clockChecking = false);
    }
  }

  void _toggle(int channel) {
    if (_connectivity.connectivity == Connectivity.offline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device offline — join its Wi-Fi access point first.')),
      );
      return;
    }
    final current = _channels[channel] ?? const ChannelState();
    final target = !(current.reported == 'ON');
    final opId = 'op-${++_opSeq}';
    final tapped = channelReduce(current, UserTap(target, opId: opId), _reducerConfig, now: _now);
    setState(() => _channels[channel] = tapped.state);
    for (final effect in tapped.effects) {
      if (effect == FollowUp.startPendingTimer) _startPendingTimer(channel);
      if (effect == FollowUp.cancelPendingTimer) _cancelPendingTimer(channel);
    }
    if (_busy.contains(channel)) return;
    _send(channel, target ? 'ON' : 'OFF', opId);
  }

  Future<void> _send(int channel, String state, String opId) async {
    _busy.add(channel);
    _tapTimeouts.remove(channel)?.cancel();
    _tapTimeouts[channel] = Timer(_tapTimeout, () {
      _busy.remove(channel);
      _applyChannel(channel, Timeout(channel));
    });
    try {
      final result = await _repo.control(
        widget.deviceId,
        channel,
        state,
        password: widget.password,
        opId: opId,
      );
      _tapTimeouts.remove(channel)?.cancel();
      _busy.remove(channel);
      final r = result.channels[channel];
      _applyChannel(
        channel,
        RestResponse(channel,
            report: r, online: result.online, source: DeviceTransportSource.local),
      );
      final pending = _channels[channel];
      if (pending != null && pending.desired != null && pending.desired != pending.reported) {
        _send(channel, pending.desired!, 'op-${++_opSeq}');
      }
    } catch (e) {
      _tapTimeouts.remove(channel)?.cancel();
      _busy.remove(channel);
      _applyChannel(channel, Timeout(channel));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  String get _connectivityLabel {
    switch (_connectivity.connectivity) {
      case Connectivity.online:
        return 'ONLINE';
      case Connectivity.offline:
        return 'OFFLINE';
      case Connectivity.syncing:
        return 'SYNCING';
    }
  }

  String get _clockLabel {
    switch (_deviceClock.health) {
      case ClockHealth.ok:
        return 'CLOCK OK';
      case ClockHealth.needsSync:
        return 'CLOCK NEEDS SYNC';
      case ClockHealth.invalid:
        return 'CLOCK INVALID';
    }
  }

  bool _applyingTemplate = false;

  DeviceProfile get _profile => DeviceProfile.fromId(widget.profileId);

  Future<void> _enableFourRelays() async {
    final profile = _profile;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Enable 4 relays?'),
        content: Text(
            'This writes the stock ${profile.displayName} template to the device and restarts it. Only continue on genuine ${profile.displayName} hardware.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _applyingTemplate = true);
    try {
      await applyProfileTemplate(_repo, widget.deviceId, profile, password: widget.password);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Template applied. The device is restarting — pull to refresh in about 15 seconds.'),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _applyingTemplate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
        actions: [
          if (widget._themes != null)
            ListenableBuilder(
              listenable: widget._themes!,
              builder: (_, __) => IconButton(
                icon: Icon(widget._themes!.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                tooltip: 'Theme',
                onPressed: () => widget._themes!.toggle(),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'Diagnostics',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DiagnosticsScreen(entries: _repo.diagnostics),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _refresh(),
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  SteesCard(
                    child: Row(
                      children: [
                        _statusDot(),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _connectivityLabel,
                                style: GoogleFonts.sora(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: context.steesColors.foam,
                                ),
                              ),
                              Text(
                                _pollError != null
                                    ? 'Poll failed: $_pollError'
                                    : _lastSyncAt == null
                                        ? '192.168.4.1 · local link'
                                        : '192.168.4.1 · synced ${_timeOfDay(_lastSyncAt!)}',
                                style: TextStyle(fontSize: 12, color: context.steesColors.mist),
                              ),
                            ],
                          ),
                        ),
                        _clockPill(),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_deviceClock.health != ClockHealth.ok)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: SteesCard(
                        borderColor: context.steesColors.sunlight,
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Device clock needs attention',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: context.steesColors.foam,
                                    ),
                                  ),
                                  Text(
                                    'Schedules only run on a valid clock.',
                                    style: TextStyle(fontSize: 12, color: context.steesColors.mist),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: _syncClock,
                              child: const Text('Sync'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_channelCount < _profile.channelCount)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: SteesCard(
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Single relay mode',
                                      style: TextStyle(fontWeight: FontWeight.w600)),
                                  Text(
                                    _profile.tasmotaTemplate == null
                                        ? 'This ${_profile.displayName} should expose ${_profile.channelCount} relays. Check its template on the device console.'
                                        : 'This ${_profile.displayName} has ${_profile.channelCount} relays but its template exposes 1 channel.',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            if (_profile.tasmotaTemplate != null)
                              ElevatedButton(
                                onPressed: _applyingTemplate ? null : _enableFourRelays,
                                child: Text(_applyingTemplate ? 'Working…' : 'Enable ${_profile.channelCount} relays'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  SteesSectionHeader(title: 'Relays', count: _channelCount),
                  for (var ch = 1; ch <= _channelCount; ch++) _channelCard(ch),
                ],
              ),
            ),
    );
  }

  Widget _statusDot() {
    final online = _connectivity.connectivity == Connectivity.online;
    final color = online ? context.steesColors.leaf : context.steesColors.sunlight;
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [AppShadows.glow(color)],
      ),
    );
  }

  bool get _offline => _connectivity.connectivity == Connectivity.offline;

  Future<void> _openWifiPage() async {
    final session = widget._session;
    if (session == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ApConnectScreen(session: session, autoScan: true)),
    );
    _refresh();
  }

  Widget _clockPill() {
    final ok = _deviceClock.health == ClockHealth.ok;
    final color = ok ? context.steesColors.leaf : context.steesColors.sunlight;
    final label = _clockChecking ? '…' : _clockLabel;
    return GestureDetector(
      onTap: _offline ? _openWifiPage : (ok ? _checkClock : _syncClock),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: GoogleFonts.sora(fontSize: 10, fontWeight: FontWeight.w600, color: color),
        ),
      ),
    );
  }

  Widget _channelCard(int channel) {
    final s = _channels[channel] ?? const ChannelState();
    final isOn = s.reported == 'ON';
    final unknown = s.reported == null;
    final colors = context.steesColors;
    final statusText = s.pending
        ? (s.showIndicator ? 'TURNING…' : 'Sending…')
        : unknown
            ? 'Unknown'
            : (isOn ? 'ON' : 'OFF');
    final accent = isOn ? colors.leaf : colors.mist;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: SteesCard(
        active: isOn,
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.12),
                border: Border.all(color: accent.withValues(alpha: 0.35)),
              ),
              child: Icon(Icons.water_drop_outlined, color: accent),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Relay $channel',
                    style: GoogleFonts.sora(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: colors.foam,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(statusText, style: TextStyle(fontSize: 12, color: colors.mist)),
                ],
              ),
            ),
            SteesActiveTag(active: isOn),
            const SizedBox(width: AppSpacing.sm),
            Switch(
              value: isOn,
              onChanged: s.pending && _busy.contains(channel) ? null : (_) => _toggle(channel),
            ),
          ],
        ),
      ),
    );
  }
}
