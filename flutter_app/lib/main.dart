import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'services/auth_service.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';

const String kServerIp = 'sonoff-3na2.onrender.com';
const String kProtocol = 'https';

void main() {
  runApp(const SteesApp());
}

class SteesApp extends StatefulWidget {
  const SteesApp({super.key});

  @override
  State<SteesApp> createState() => _SteesAppState();
}

class _SteesAppState extends State<SteesApp> {
  final ThemeController _themeController = ThemeController();

  @override
  void initState() {
    super.initState();
    _themeController.load();
  }

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'STEES',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: _themeController.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 350),
          themeAnimationCurve: Curves.easeInOut,
          home: AuthGate(themeController: _themeController),
          routes: { '/home': (_) => AuthGate(themeController: _themeController) },
        );
      },
    );
  }
}

class AuthGate extends StatefulWidget {
  final ThemeController themeController;
  const AuthGate({super.key, required this.themeController});

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
    final colors = context.steesColors;
    final scheme = Theme.of(context).colorScheme;
    if (_checking) {
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [colors.well, scheme.surfaceContainerHighest, colors.well],
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
                        color: colors.stream.withValues(alpha: 0.6),
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
    return _loggedIn
        ? MainShell(themeController: widget.themeController)
        : LoginScreen(themeController: widget.themeController);
  }
}

class _SteesLogo extends StatelessWidget {
  final double size;
  const _SteesLogo({this.size = 56});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [colors.stream, colors.leaf],
        ),
        boxShadow: [
          BoxShadow(color: colors.border, blurRadius: 12, spreadRadius: 0),
        ],
      ),
      child: Center(
        child: Text('S', style: GoogleFonts.sora(fontSize: size * 0.5, fontWeight: FontWeight.w700, color: colors.well)),
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
  ChannelConfig('Zone 1', Icons.water_drop, Color(0xFF0F766E), 'CHANNEL 1'),
  ChannelConfig('Zone 2', Icons.water_drop, Color(0xFF0F766E), 'CHANNEL 2'),
  ChannelConfig('Zone 3', Icons.water_drop, Color(0xFF0F766E), 'CHANNEL 3'),
  ChannelConfig('Zone 4', Icons.water_drop, Color(0xFF0F766E), 'CHANNEL 4'),
];