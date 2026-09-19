import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../l10n/gen/app_localizations.dart';
import '../l10n/locale_controller.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/weather_notification_service.dart';
import 'devices_page.dart';
import 'sensors_page.dart';
import 'schedules_page.dart';
import 'rules_page.dart';
import 'weather_page.dart';
import 'login_screen.dart';
import '../widgets/stees_nav_bar.dart';
import '../widgets/stees_header_logo.dart';


class MainShell extends StatefulWidget {
  final dynamic themeController;
  final LocaleController? localeController;
  const MainShell({super.key, this.themeController, this.localeController});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final _auth = AuthService();
  final _api = ApiService();
  final _weatherNotifs = WeatherNotificationService();
  final _schedulesKey = GlobalKey<SchedulesPageState>();

  late final List<Widget> _pages = [
    DevicesPage(onNavigateToTab: (i) => _switchTab(i)),
    SensorsPage(onNavigateToTab: (i) => _switchTab(i)),
    SchedulesPage(key: _schedulesKey),
    const RulesPage(),
    WeatherPage(onNavigateToTab: (i) => _switchTab(i)),
  ];

  @override
  void initState() {
    super.initState();
    // Any API response with 401 (expired/invalid token) from any tab logs the
    // user out instead of leaving every page showing a generic failure.
    ApiService.onUnauthorized = _handleSessionExpired;
    _initWeatherNotifs();
  }

  Future<void> _initWeatherNotifs() async {
    try {
      // NOTE: locale strings are synced in build() (_syncNotifLocale), never
      // here — Localizations cannot be read in initState.
      await _weatherNotifs.init(api: _api, onTap: (deviceId) {
        if (!mounted) return;
        setState(() => _currentIndex = 4);
        // WeatherPage will pick up pendingDeviceId via service
      });
      await _weatherNotifs.requestPermissionAndRegister(_api);
      final pending = _weatherNotifs.pendingDeviceId;
      if (pending != null && pending.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _currentIndex = 4);
        });
      }
    } catch (_) {}
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
    if (index == 2) {
      // Schedules tab became visible: refresh weather chips in parallel
      _schedulesKey.currentState?.refreshWeather();
    }
  }

  void _routeToLogin() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, _, _) =>
            LoginScreen(localeController: widget.localeController),
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
    try {
      await _weatherNotifs.unregister(_api);
    } catch (_) {}
    await _auth.clear();
    if (mounted) _routeToLogin();
  }

  void _openAppearance() {
    final tc = widget.themeController;
    if (tc == null) return;
    setState(() {});
    tc.toggle();
  }

  /// Keeps foreground notification strings in the current app language.
  /// Cheap (string assignment only) so it runs on every build.
  void _syncNotifLocale() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _weatherNotifs.updateLocaleStrings(
      channelName: l10n.ntChannel,
      channelDescription: l10n.ntChannelDesc,
      fallbackTitle: l10n.ntRainExpected,
      fallbackBody: l10n.ntCheckSchedule,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    _syncNotifLocale();
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
                  index: _currentIndex.clamp(0, _pages.length - 1),
                  children: _pages,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SteesNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          setState(() => _currentIndex = i);
          if (i == 2) _schedulesKey.currentState?.refreshWeather();
        },
        items: [
          SteesNavItem(
            icon: Icons.developer_board_outlined,
            activeIcon: Icons.developer_board,
            label: l10n.navDevices,
          ),
          SteesNavItem(
            icon: Icons.speed_outlined,
            activeIcon: Icons.speed,
            label: l10n.navSensors,
          ),
          SteesNavItem(
            icon: Icons.update_outlined,
            activeIcon: Icons.update,
            label: l10n.navSchedules,
          ),
          SteesNavItem(
            icon: Icons.schema_outlined,
            activeIcon: Icons.schema,
            label: l10n.navRules,
          ),
          SteesNavItem(
            icon: Icons.cloud_outlined,
            activeIcon: Icons.cloud,
            label: l10n.navWeather,
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final colors = context.steesColors;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SteesHeaderLogo(),
          const SizedBox(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.appTitle,
                  style: GoogleFonts.sora(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: colors.foam,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  l10n.appTagline,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: colors.mist.withValues(alpha: 0.7),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          _buildLanguageButton(colors, l10n),
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
            tooltip: l10n.actionToggleTheme,
          ),
          IconButton(
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded, size: 20),
            tooltip: l10n.actionLogout,
          ),
        ],
      ),
    );
  }

  /// Language selector: shows the current language code and offers
  /// English / العربية / Français. Switching updates [LocaleController] —
  /// the single source of truth — which rebuilds the whole app in place
  /// (route, tab and form state are preserved).
  Widget _buildLanguageButton(SteesColors colors, AppLocalizations l10n) {
    final controller = widget.localeController;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = controller.locale.languageCode;
        return PopupMenuButton<String>(
          icon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language_outlined, size: 20),
              const SizedBox(width: 2),
              Text(
                current.toUpperCase(),
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: colors.mist,
                ),
              ),
            ],
          ),
          tooltip: l10n.actionLanguage,
          color: colors.submerged,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: BorderSide(color: colors.border),
          ),
          onSelected: (value) => controller.setLocale(Locale(value)),
          itemBuilder: (_) => [
            _languageItem(colors, l10n, 'en', l10n.languageEnglish, current),
            _languageItem(colors, l10n, 'ar', l10n.languageArabic, current),
            _languageItem(colors, l10n, 'fr', l10n.languageFrench, current),
          ],
        );
      },
    );
  }

  PopupMenuItem<String> _languageItem(
    SteesColors colors,
    AppLocalizations l10n,
    String value,
    String label,
    String current,
  ) {
    final selected = value == current;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? colors.stream : colors.foam,
              ),
            ),
          ),
          if (selected)
            Icon(Icons.check_rounded, size: 16, color: colors.stream),
        ],
      ),
    );
  }
}