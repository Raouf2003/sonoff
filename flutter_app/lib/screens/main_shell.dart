import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/auth_service.dart';
import 'devices_page.dart';
import 'sensors_page.dart';
import 'schedules_page.dart';
import 'rules_page.dart';
import 'login_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final _auth = AuthService();

  late final List<Widget> _pages = [
    DevicesPage(onNavigateToTab: (i) => _switchTab(i)),
    SensorsPage(onNavigateToTab: (i) => _switchTab(i)),
    const SchedulesPage(),
    const RulesPage(),
  ];

  void _switchTab(int index) {
    setState(() => _currentIndex = index);
  }

  Future<void> _logout() async {
    await _auth.clear();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (_, _, _) => const LoginScreen(),
          transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 300),
        ),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.well,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.well, Color(0xFF0F2332), AppColors.well],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: IndexedStack(
                  index: _currentIndex,
                  children: _pages,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: AppColors.submerged,
          surfaceTintColor: Colors.transparent,
          height: 68,
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
            final active = states.contains(WidgetState.selected);
            return GoogleFonts.inter(
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? AppColors.stream : AppColors.mist.withValues(alpha: 0.7),
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((states) {
            final active = states.contains(WidgetState.selected);
            return IconThemeData(
              size: 24,
              color: active ? AppColors.stream : AppColors.mist.withValues(alpha: 0.7),
            );
          }),
          indicatorColor: AppColors.stream.withValues(alpha: 0.12),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.water_drop_outlined), selectedIcon: Icon(Icons.water_drop), label: 'Devices'),
            NavigationDestination(icon: Icon(Icons.sensors), label: 'Sensors'),
            NavigationDestination(icon: Icon(Icons.schedule_outlined), selectedIcon: Icon(Icons.schedule), label: 'Schedules'),
            NavigationDestination(icon: Icon(Icons.rule_outlined), selectedIcon: Icon(Icons.rule), label: 'Rules'),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.stream, AppColors.leaf],
              ),
              boxShadow: [
                BoxShadow(color: AppColors.stream.withValues(alpha: 0.3), blurRadius: 12),
              ],
            ),
            child: Center(
              child: Text('S', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.well)),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'STEES',
                  style: GoogleFonts.sora(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foam,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  'Smart Irrigation',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.mist.withValues(alpha: 0.7),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _logout,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppRadius.md)),
              child: const Icon(Icons.logout_rounded, size: 20, color: AppColors.mist),
            ),
          ),
        ],
      ),
    );
  }
}