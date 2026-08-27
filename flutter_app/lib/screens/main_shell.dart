import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import 'devices_page.dart';
import 'sensors_page.dart';
import 'schedules_page.dart';
import 'rules_page.dart';
import 'login_screen.dart';
import '../widgets/stees_nav_bar.dart';


class MainShell extends StatefulWidget {
  final dynamic themeController;
  const MainShell({super.key, this.themeController});

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

  @override
  void initState() {
    super.initState();
    // Any API response with 401 (expired/invalid token) from any tab logs the
    // user out instead of leaving every page showing a generic failure.
    ApiService.onUnauthorized = _handleSessionExpired;
  }

  @override
  void dispose() {
    if (ApiService.onUnauthorized == _handleSessionExpired) {
      ApiService.onUnauthorized = null;
    }
    super.dispose();
  }

  void _switchTab(int index) {
    setState(() => _currentIndex = index);
  }

  void _routeToLogin() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => const LoginScreen(),
        transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
      (route) => false,
    );
  }

  Future<void> _handleSessionExpired() async {
    await _auth.clear();
    if (mounted) _routeToLogin();
  }

  Future<void> _logout() async {
    await _auth.clear();
    if (mounted) _routeToLogin();
  }

  void _openAppearance() {
    final tc = widget.themeController;
    if (tc == null) return;
    setState(() {});
    tc.toggle();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.well,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.well, scheme.surfaceContainerHighest, colors.well],
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
      bottomNavigationBar: SteesNavBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          SteesNavItem(
            icon: Icons.developer_board_outlined,
            activeIcon: Icons.developer_board,
            label: 'Devices',
          ),
          SteesNavItem(
            icon: Icons.speed_outlined,
            activeIcon: Icons.speed,
            label: 'Sensors',
          ),
          SteesNavItem(
            icon: Icons.update_outlined,
            activeIcon: Icons.update,
            label: 'Schedules',
          ),
          SteesNavItem(
            icon: Icons.schema_outlined,
            activeIcon: Icons.schema,
            label: 'Rules',
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final colors = context.steesColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colors.stream, colors.leaf],
              ),
              boxShadow: [BoxShadow(color: colors.border, blurRadius: 8)],
            ),
            padding: const EdgeInsets.all(6),
            child: Center(child: Image.asset('assets/logo.png', fit: BoxFit.contain)),
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
                    color: colors.foam,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  'Smart Irrigation',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: colors.mist.withValues(alpha: 0.7),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _openAppearance,
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
              child: Icon(
                Theme.of(context).brightness == Brightness.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                key: ValueKey(Theme.of(context).brightness),
                size: 20,
              ),
            ),
            tooltip: 'Toggle theme',
          ),
          IconButton(
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded, size: 20),
            tooltip: 'Logout',
          ),
        ],
      ),
    );
  }
}