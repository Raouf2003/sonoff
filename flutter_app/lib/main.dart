import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:convert';

const String kServerIp = 'sonoff.onrender.com';
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
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorSchemeSeed: Colors.cyan,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class ChannelConfig {
  final String name;
  final IconData icon;
  final Color color;
  final Color glow;

  const ChannelConfig(this.name, this.icon, this.color, this.glow);
}

const channels = [
  ChannelConfig('Main Valve', Icons.water, Color(0xFF4FC3F7), Color(0x664FC3F7)),
  ChannelConfig('Water Pump', Icons.water_drop, Color(0xFF29B6F6), Color(0x6629B6F6)),
  ChannelConfig('Zone 1', Icons.grass, Color(0xFF81C784), Color(0x6681C784)),
  ChannelConfig('Zone 2', Icons.agriculture, Color(0xFFA5D6A7), Color(0x66A5D6A7)),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final List<bool> channelStates = [false, false, false, false];
  final List<bool> _loading = [false, false, false, false];
  final List<AnimationController> _pulseControllers = [];
  final List<AnimationController> _entranceControllers = [];
  bool _connected = false;
  bool _initialLoading = true;
  IO.Socket? _socket;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 4; i++) {
      _pulseControllers.add(AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      ));
      _entranceControllers.add(AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 400 + i * 100),
      )..forward());
    }
    _fetchInitialStatus();
    _connectSocket();
  }

  @override
  void dispose() {
    for (final c in _pulseControllers) { c.dispose(); }
    for (final c in _entranceControllers) { c.dispose(); }
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  void _connectSocket() {
    _socket = IO.io('$kProtocol://$kServerIp', <String, dynamic>{
      'secure': true,
      'autoConnect': false,
    });

    _socket?.onConnect((_) {
      if (mounted) setState(() => _connected = true);
    });

    _socket?.onDisconnect((_) {
      if (mounted) setState(() => _connected = false);
    });

    _socket?.onConnectError((data) {
      print('Socket connection error: $data');
      if (mounted) setState(() => _connected = false);
    });

    _socket?.onError((data) {
      print('Socket error: $data');
    });

    _socket?.on('device_update', (data) {
      if (!mounted) return;
      final map = data as Map<String, dynamic>;
      final channel = map['channel'] as int;
      final state = map['state'] as String;
      final index = channel - 1;
      final newState = state == 'ON';
      setState(() => channelStates[index] = newState);
      if (newState) {
        _pulseControllers[index].repeat(reverse: true);
      } else {
        _pulseControllers[index].stop();
        _pulseControllers[index].reset();
      }
    });

    _socket?.connect();
  }

  Future<void> _fetchInitialStatus() async {
    final url = '$kProtocol://$kServerIp/api/status';
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          for (int i = 0; i < 4; i++) {
            final on = data['POWER${i + 1}'] == 'ON';
            channelStates[i] = on;
            if (on) _pulseControllers[i].repeat(reverse: true);
          }
          _initialLoading = false;
        });
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _initialLoading = false);
        _showError('Failed to fetch status');
      }
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: const TextStyle(fontSize: 14))),
        ]),
        backgroundColor: Colors.redAccent.shade200,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _toggle(int channel, bool targetState) async {
    final index = channel - 1;
    setState(() => _loading[index] = true);

    try {
      final response = await http.post(
        Uri.parse('$kProtocol://$kServerIp/api/control'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'channel': channel, 'state': targetState ? 'ON' : 'OFF'}),
      );

      if (response.statusCode == 200) {
        setState(() => channelStates[index] = targetState);
        if (targetState) {
          _pulseControllers[index].repeat(reverse: true);
        } else {
          _pulseControllers[index].stop();
          _pulseControllers[index].reset();
        }
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      _showError('Failed to control ${channels[index].name}');
    } finally {
      setState(() => _loading[index] = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D1117), Color(0xFF161B22), Color(0xFF0D1117)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF00B8D4)]),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(child: Text('S', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.black))),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('STEES', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 2)),
              Text('Smart Irrigation', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ),
          const Spacer(),
          _connectionIndicator(),
        ],
      ),
    );
  }

  Widget _connectionIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _connected ? const Color(0xFF4CAF50) : Colors.grey.shade600,
            boxShadow: [
              BoxShadow(
                color: _connected ? const Color(0x664CAF50) : Colors.transparent,
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _connected ? 'Live' : 'Offline',
          style: TextStyle(fontSize: 12, color: _connected ? const Color(0xFF4CAF50) : Colors.grey.shade500),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF00E5FF)));
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.78,
        physics: const BouncingScrollPhysics(),
        children: List.generate(4, (i) {
          final cfg = channels[i];
          return _AnimatedChannelCard(
            index: i,
            channel: i + 1,
            name: cfg.name,
            icon: cfg.icon,
            color: cfg.color,
            glow: cfg.glow,
            isOn: channelStates[i],
            loading: _loading[i],
            entranceAnimation: _entranceControllers[i],
            pulseAnimation: _pulseControllers[i],
            onToggle: (val) => _toggle(i + 1, val),
          );
        }),
      ),
    );
  }
}

class _AnimatedChannelCard extends AnimatedWidget {
  final int index;
  final int channel;
  final String name;
  final IconData icon;
  final Color color;
  final Color glow;
  final bool isOn;
  final bool loading;
  final AnimationController entranceAnimation;
  final AnimationController pulseAnimation;
  final ValueChanged<bool> onToggle;

  const _AnimatedChannelCard({
    required this.index,
    required this.channel,
    required this.name,
    required this.icon,
    required this.color,
    required this.glow,
    required this.isOn,
    required this.loading,
    required this.entranceAnimation,
    required this.pulseAnimation,
    required this.onToggle,
  }) : super(listenable: entranceAnimation);

  @override
  Widget build(BuildContext context) {
    final anim = entranceAnimation;
    final scale = Curves.easeOutBack.transform(anim.value);
    final opacity = anim.value;

    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: opacity,
        child: _ChannelCardContent(
          channel: channel,
          name: name,
          icon: icon,
          color: color,
          glow: glow,
          isOn: isOn,
          loading: loading,
          pulseAnimation: pulseAnimation,
          onToggle: onToggle,
        ),
      ),
    );
  }
}

class _ChannelCardContent extends StatefulWidget {
  final int channel;
  final String name;
  final IconData icon;
  final Color color;
  final Color glow;
  final bool isOn;
  final bool loading;
  final AnimationController pulseAnimation;
  final ValueChanged<bool> onToggle;

  const _ChannelCardContent({
    required this.channel,
    required this.name,
    required this.icon,
    required this.color,
    required this.glow,
    required this.isOn,
    required this.loading,
    required this.pulseAnimation,
    required this.onToggle,
  });

  @override
  State<_ChannelCardContent> createState() => _ChannelCardContentState();
}

class _ChannelCardContentState extends State<_ChannelCardContent> with SingleTickerProviderStateMixin {
  late AnimationController _hoverController;
  late Animation<double> _hoverAnimation;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _hoverAnimation = CurvedAnimation(parent: _hoverController, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {

    return AnimatedBuilder(
      animation: _hoverAnimation,
      builder: (context, child) {
        final hoverScale = 1.0 + _hoverAnimation.value * 0.02;
        return Transform.scale(scale: hoverScale, child: child);
      },
      child: GestureDetector(
        onTapDown: (_) => _hoverController.forward(),
        onTapUp: (_) => _hoverController.reverse(),
        onTapCancel: () => _hoverController.reverse(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: widget.isOn ? widget.color.withValues(alpha: 0.12) : const Color(0xFF1C2333),
            border: Border.all(
              color: widget.isOn ? widget.color.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.05),
              width: 1.5,
            ),
            boxShadow: widget.isOn
                ? [
                    BoxShadow(color: widget.glow, blurRadius: 16, spreadRadius: 2),
                    BoxShadow(color: widget.glow, blurRadius: 32, spreadRadius: 0),
                  ]
                : [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 4))],
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('CH${widget.channel}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey.shade400, letterSpacing: 1)),
                  ),
                  _buildToggle(),
                ],
              ),
              const Spacer(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: widget.isOn
                    ? _PulsingIcon(icon: widget.icon, color: widget.color, pulse: widget.pulseAnimation)
                    : Icon(widget.icon, key: const ValueKey('off'), size: 38, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: widget.isOn ? widget.color : Colors.grey.shade300,
                ),
                child: Text(widget.name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: widget.isOn ? widget.color.withValues(alpha: 0.7) : Colors.grey.shade600,
                ),
                child: Text(widget.isOn ? 'ACTIVE' : 'STANDBY', style: const TextStyle(letterSpacing: 1.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggle() {
    final w = 44.0;
    final h = 26.0;
    final padding = 3.0;
    final thumbSize = h - padding * 2;

    return GestureDetector(
      onTap: widget.loading ? null : () => widget.onToggle(!widget.isOn),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(h / 2),
          color: widget.isOn ? widget.color : Colors.white.withValues(alpha: 0.12),
        ),
        padding: EdgeInsets.all(padding),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: widget.isOn ? Alignment.centerRight : Alignment.centerLeft,
          child: widget.loading
              ? SizedBox(
                  width: thumbSize,
                  height: thumbSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: widget.isOn ? Colors.black : Colors.grey.shade400,
                  ),
                )
              : Container(
                  width: thumbSize,
                  height: thumbSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isOn ? Colors.black87 : Colors.white,
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 4, offset: const Offset(0, 2))],
                  ),
                ),
        ),
      ),
    );
  }
}

class _PulsingIcon extends AnimatedWidget {
  final IconData icon;
  final Color color;
  const _PulsingIcon({required this.icon, required this.color, required AnimationController pulse}) : super(listenable: pulse);

  @override
  Widget build(BuildContext context) {
    final controller = listenable as AnimationController;
    final scale = 1.0 + controller.value * 0.08;
    final opacity = 0.7 + controller.value * 0.3;
    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: opacity,
        child: Icon(icon, key: const ValueKey('on'), size: 38, color: color),
      ),
    );
  }
}