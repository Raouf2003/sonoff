import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../devices/device_profile.dart';
import '../theme/app_theme.dart';
import '../widgets/stees_widgets.dart';
import 'connection_controller.dart';
import 'connection_machine.dart' as conn;
import 'session.dart';

class ApConnectScreen extends StatefulWidget {
  const ApConnectScreen({super.key, required this.session, ConnectionController? controller, this.autoScan = false})
      : _controller = controller;

  final SessionState session;
  final ConnectionController? _controller;
  final bool autoScan;

  @override
  State<ApConnectScreen> createState() => _ApConnectScreenState();
}

class _ApConnectScreenState extends State<ApConnectScreen> with WidgetsBindingObserver {
  late final ConnectionController _controller;
  final _nameController = TextEditingController();
  String? _nameError;

  bool _wifiPrompted = false;
  bool _wifiDeclined = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget._controller ??
        ConnectionController(session: widget.session);
    _controller.addListener(_closeOnSuccess);
    _hadSession = widget.session.session != null;
    widget.session.addListener(_closeOnPaired);
    if (widget.autoScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.scan();
      });
    }
  }

  bool _hadSession = false;

  void _closeOnSuccess() {
    if (!mounted) return;
    if (_controller.state.phase != conn.ConnectionPhase.succeeded) return;
    _popToRelays();
  }

  void _closeOnPaired() {
    if (!mounted || _hadSession) return;
    if (widget.session.session == null) return;
    _popToRelays();
  }

  void _popToRelays() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Navigator.canPop(context)) Navigator.of(context).pop();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_wifiPrompted) {
        _wifiPrompted = false;
        _controller.scan();
      } else {
        _controller.recheck();
      }
    }
  }

  Future<void> _promptWifiOn() async {
    _wifiPrompted = true;
    final open = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Wi-Fi is off'),
        content: const Text('Turn on Wi-Fi to find your Tasmota device. The scan continues when you return.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Turn on Wi-Fi')),
        ],
      ),
    );
    if (open == true) {
      await _controller.openSystemWifi();
    } else {
      _wifiPrompted = false;
      _wifiDeclined = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_closeOnSuccess);
    widget.session.removeListener(_closeOnPaired);
    _nameController.dispose();
    if (widget._controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Claim Device')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _body(_controller.state),
      ),
    );
  }

  Widget _body(conn.ConnectionState state) {
    switch (state.phase) {
      case conn.ConnectionPhase.idle:
        return _ready();
      case conn.ConnectionPhase.scanning:
        return _progress('Scanning for Wi-Fi…', 'Looking for your Tasmota access point.', true);
      case conn.ConnectionPhase.networksAvailable:
        return _networkList();
      case conn.ConnectionPhase.connectingToAp:
        return _progress(
          'Connecting to ${_controller.selectedSsid ?? 'device'}…',
          'Joining the access point.',
          true,
        );
      case conn.ConnectionPhase.openingWifi:
        return _progress('Opening Wi-Fi…', 'Select the network starting with Tasmota-.', true);
      case conn.ConnectionPhase.waitingWifi:
        return _progress('Waiting for Wi-Fi…',
            'Connect to your Tasmota access point. "No internet" on that network is normal.', true);
      case conn.ConnectionPhase.wifiConnected:
      case conn.ConnectionPhase.probing:
        return _progress('Wi-Fi connected.', 'Finding Sonoff at 192.168.4.1…', false);
      case conn.ConnectionPhase.verifying:
        if (_controller.awaitingConfirm) return _deviceCard();
        return _progress('Device verified.', 'Checking device identity.', false);
      case conn.ConnectionPhase.syncingClock:
        return _progress('Synchronizing time…', 'Schedules need a valid clock.', false);
      case conn.ConnectionPhase.succeeded:
        return _success();
      case conn.ConnectionPhase.failed:
        return _failure(state);
    }
  }

  Widget _ready() {
    return SteesEmpty(
      icon: Icons.router_outlined,
      title: 'Connect your Sonoff',
      subtitle: 'Make sure the Sonoff is powered on. You will pick its Wi-Fi network next.',
      action: ElevatedButton(
        onPressed: () => _controller.scan(),
        child: const Text('Claim Device'),
      ),
    );
  }

  Widget _networkList() {
    final networks = _controller.networks;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Select the Tasmota access point',
            style: GoogleFonts.sora(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.steesColors.foam,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _controller.scanMessage ?? '${networks.length} networks found.',
            style: TextStyle(fontSize: 12, color: context.steesColors.mist),
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: networks.isEmpty
                ? const Center(child: Text('No Wi-Fi networks found.'))
                : ListView.builder(
                    itemCount: networks.length,
                    itemBuilder: (context, i) {
                      final n = networks[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: SteesCard(
                          active: n.looksLikeTasmota,
                          onTap: () => _controller.select(n.name),
                          child: Row(
                            children: [
                              Icon(Icons.wifi,
                                  color: n.looksLikeTasmota
                                      ? context.steesColors.stream
                                      : context.steesColors.mist),
                              const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      n.name,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: context.steesColors.foam,
                                      ),
                                    ),
                                    if (n.looksLikeTasmota)
                                      Text('Tasmota device',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: context.steesColors.leaf))
                                    else if (n.rssi != null)
                                      Text('${n.rssi} dBm',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: context.steesColors.mist)),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right,
                                  color: context.steesColors.mist),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  onPressed: () => _controller.scan(),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _controller.start(),
                  child: const Text('System Wi-Fi'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _progress(String title, String subtitle, bool cancellable) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SteesLoading(),
          const SizedBox(height: AppSpacing.lg),
          Text(title,
              style: GoogleFonts.sora(
                  fontSize: 17, fontWeight: FontWeight.w600, color: context.steesColors.foam),
              textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.sm),
          Text(subtitle,
              style: TextStyle(fontSize: 13, color: context.steesColors.mist),
              textAlign: TextAlign.center),
          if (cancellable) ...[
            const SizedBox(height: AppSpacing.xxl),
            TextButton(onPressed: () => _controller.cancel(), child: const Text('Cancel')),
          ],
        ],
      ),
    );
  }

  String _profileId = DeviceProfile.defaultId;

  Widget _deviceCard() {
    final mac = _controller.pendingMac ?? '';
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      children: [
        Text('Tasmota device detected',
            style: GoogleFonts.sora(
                fontSize: 20, fontWeight: FontWeight.w700, color: context.steesColors.foam),
            textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.lg),
        SteesCard(
          active: true,
          child: Column(
            children: [
              Text('Tasmota device',
                  style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.xs),
              Text('MAC: $mac',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              Text('MAC verified',
                  style: TextStyle(fontSize: 12, color: context.steesColors.leaf)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          controller: _nameController,
          decoration: InputDecoration(
            labelText: 'Device name *',
            hintText: 'e.g. STEES 4CH',
            errorText: _nameError,
          ),
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
        ),
        const SizedBox(height: AppSpacing.md),
        Text('Hardware',
            style: GoogleFonts.sora(
                fontSize: 13, fontWeight: FontWeight.w600, color: context.steesColors.foam)),
        const SizedBox(height: AppSpacing.xs),
        SegmentedButton<String>(
          segments: [
            for (final profile in DeviceProfile.values)
              ButtonSegment(
                value: profile.id,
                label: Text(profile.displayName),
                tooltip: profile.tasmotaTemplate == null ? 'Keeps its current template' : null,
              ),
          ],
          selected: {_profileId},
          onSelectionChanged: (s) => setState(() => _profileId = s.first),
        ),
        const SizedBox(height: AppSpacing.lg),
        ElevatedButton.icon(
          icon: const Icon(Icons.link),
          label: const Text('Connect Device'),
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) {
              setState(() => _nameError = 'Please name your device to continue.');
              return;
            }
            _controller.confirmPairing(name, profileId: _profileId);
          },
        ),
        TextButton(onPressed: () => _controller.cancel(), child: const Text('Cancel')),
      ],
    );
  }

  Widget _success() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline,
              size: 72, color: context.steesColors.leaf),
          const SizedBox(height: AppSpacing.lg),
          Text('Device connected.',
              style: GoogleFonts.sora(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: context.steesColors.foam),
              textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.sm),
          Text('Opening controls…',
              style: TextStyle(fontSize: 13, color: context.steesColors.mist),
              textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.xxl),
          OutlinedButton(
            onPressed: () => _controller.openPairedSession(),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Widget _failure(conn.ConnectionState state) {
    final mismatch = state.failure == conn.ConnectionFailure.macMismatch;
    final wifiOff = state.failure == conn.ConnectionFailure.scanFailed &&
        (state.failureDetail ?? '').toLowerCase().contains('wi-fi off');
    if (wifiOff && !_wifiPrompted && !_wifiDeclined) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _promptWifiOn();
      });
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SteesError(
            title: mismatch ? 'Device changed' : 'Connection failed',
            subtitle: conn.failureMessage(state),
            onRetry: null,
          ),
          if (mismatch) ...[
            const SizedBox(height: AppSpacing.md),
            Text('Expected:\n${state.expectedMac ?? '-'}',
                textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: AppSpacing.xs),
            Text('Detected:\n${state.foundMacValue ?? '-'}',
                textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
          const SizedBox(height: AppSpacing.xxl),
          if (wifiOff)
            ElevatedButton.icon(
              icon: const Icon(Icons.wifi_outlined),
              label: const Text('Turn on Wi-Fi'),
              onPressed: () async {
                await _controller.openSystemWifi();
              },
            ),
          if (wifiOff) const SizedBox(height: AppSpacing.sm),
          ElevatedButton(
            onPressed: () {
              setState(() => _wifiDeclined = false);
              _controller.retry();
            },
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }
}
