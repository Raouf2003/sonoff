import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'theme.dart';
import 'services/auth_service.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';

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
    return _loggedIn ? const MainShell() : const LoginScreen();
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
