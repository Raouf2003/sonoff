import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import 'devices_page.dart';
import 'sensors_page.dart';
import 'schedules_page.dart';
import 'rules_page.dart';
import 'login_screen.dart';

class MainShell extends StatefulWidget {
  final dynamic themeController;
  const MainShell({super.key, this.themeController});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with TickerProviderStateMixin {
  int _currentIndex = 0;
  int _previousIndex = 0;
  final _auth = AuthService();
  late final AnimationController _navAnimationController;
  late final List<Animation<double>> _tabAnimations;

  // Badge counts for each tab (can be updated from pages via callback)
  final List<int> _badgeCounts = [0, 0, 0, 0];

  late final List<Widget> _pages = [
    DevicesPage(
      onNavigateToTab: (i) => _switchTab(i),
      onBadgeUpdate: (count) => _updateBadge(0, count),
    ),
    SensorsPage(
      onNavigateToTab: (i) => _switchTab(i),
      onBadgeUpdate: (count) => _updateBadge(1, count),
    ),
    const SchedulesPage(),
    const RulesPage(),
  ];

  @override
  void initState() {
    super.initState();
    // Any API response with 401 (expired/invalid token) from any tab logs the
    // user out instead of leaving every page showing a generic failure.
    ApiService.onUnauthorized = _handleSessionExpired;

    _navAnimationController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );

    _tabAnimations = List.generate(4, (index) {
      return Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: _navAnimationController,
          curve: Interval(
            index * 0.1,
            0.5 + index * 0.1,
            curve: Curves.easeOutCubic,
          ),
        ),
      );
    });

    _navAnimationController.forward();
  }

  @override
  void dispose() {
    if (ApiService.onUnauthorized == _handleSessionExpired) {
      ApiService.onUnauthorized = null;
    }
    _navAnimationController.dispose();
    super.dispose();
  }

  void _switchTab(int index) {
    if (index == _currentIndex) return;
    _previousIndex = _currentIndex;
    setState(() {
      _currentIndex = index;
    });
    _navAnimationController.forward(from: 0);
    HapticFeedback.selectionClick();
  }

  void _updateBadge(int tabIndex, int count) {
    if (mounted && count != _badgeCounts[tabIndex]) {
      setState(() {
        _badgeCounts[tabIndex] = count.clamp(0, 99);
      });
    }
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
      bottomNavigationBar: _buildAnimatedNavBar(),
    );
  }

  Widget _buildAnimatedNavBar() {
    final colors = context.steesColors;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _navAnimationController,
      builder: (context, _) {
        return Container(
          height: 68,
          decoration: BoxDecoration(
            color: isDark ? colors.submerged : colors.submerged,
            boxShadow: [
              BoxShadow(
                color: isDark ? colors.shadow : colors.shadow.withValues(alpha: 0.15),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
              BoxShadow(
                color: isDark ? Colors.transparent : colors.shadow.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, -1),
              ),
            ],
            border: Border(
              top: BorderSide(
                color: isDark ? colors.border : colors.border.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            bottom: true,
            child: Row(
              children: List.generate(4, (index) {
                final isSelected = _currentIndex == index;
                final badgeCount = _badgeCounts[index];
                final animation = _tabAnimations[index];
                
                return Expanded(
                  child: AnimatedBuilder(
                    animation: animation,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(0, (1 - animation.value) * 8),
                        child: Opacity(
                          opacity: animation.value.clamp(0.0, 1.0),
                          child: _NavTab(
                            index: index,
                            isSelected: isSelected,
                            badgeCount: badgeCount,
                            onTap: () => _switchTab(index),
                            colors: colors,
                            isDark: isDark,
                          ),
                        ),
                      );
                    },
                  ),
                );
              }),
            ),
          ),
        );
      },
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
              boxShadow: [
                BoxShadow(color: colors.border, blurRadius: 8),
              ],
            ),
            child: Center(
              child: Text('S', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w700, color: colors.well)),
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