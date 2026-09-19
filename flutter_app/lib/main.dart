import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'l10n/gen/app_localizations.dart';
import 'l10n/locale_controller.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'services/auth_service.dart';
import 'services/weather_notification_service.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';

const String kServerIp = 'sonoff-3na2.onrender.com';
const String kProtocol = 'https';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // intl weekday/month names used across schedules + weather need explicit
  // symbol data for Arabic and French (English is built in).
  try {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('fr');
  } catch (_) {}
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  // Background/killed FCM handler. MUST be registered before runApp() and
  // MUST stay a top-level function (see weather_notification_service.dart).
  // Without this, data-only messages arriving while backgrounded render no UI.
  try {
    FirebaseMessaging.onBackgroundMessage(weatherBackgroundMessageHandler);
  } catch (_) {}
  runApp(const SteesApp());
}

class SteesApp extends StatefulWidget {
  const SteesApp({super.key});

  @override
  State<SteesApp> createState() => _SteesAppState();
}

class _SteesAppState extends State<SteesApp> {
  final ThemeController _themeController = ThemeController();
  final LocaleController _localeController = LocaleController();

  @override
  void initState() {
    super.initState();
    _themeController.load();
    _localeController.load();
  }

  @override
  void dispose() {
    _themeController.dispose();
    _localeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeController,
      builder: (context, _) {
        return ListenableBuilder(
          listenable: _localeController,
          builder: (context, _) {
            return MaterialApp(
              title: 'STEES',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: _themeController.themeMode,
              themeAnimationDuration: const Duration(milliseconds: 350),
              themeAnimationCurve: Curves.easeInOut,
              locale: _localeController.locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: AuthGate(
                themeController: _themeController,
                localeController: _localeController,
              ),
              routes: {
                '/home': (_) => AuthGate(
                      themeController: _themeController,
                      localeController: _localeController,
                    ),
              },
            );
          },
        );
      },
    );
  }
}

class AuthGate extends StatefulWidget {
  final ThemeController themeController;
  final LocaleController localeController;
  const AuthGate(
      {super.key, required this.themeController, required this.localeController});

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
        ? MainShell(
            themeController: widget.themeController,
            localeController: widget.localeController,
          )
        : LoginScreen(
            themeController: widget.themeController,
            localeController: widget.localeController,
          );
  }
}

class _SteesLogo extends StatelessWidget {
  final double size;
  const _SteesLogo({this.size = 56});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        'assets/logo.png',
        fit: BoxFit.contain,
        semanticLabel: 'STEES logo',
      ),
    );
  }
}

class ChannelConfig {  final String name;
  final IconData icon;
  final Color color;
  final String subtitle;
  const ChannelConfig(this.name, this.icon, this.color, this.subtitle);
}

/// Per-locale channel palette: same icons/colors for every locale, with zone
/// names and codes from [AppLocalizations]. Extra relays fall back to a
/// generated entry so a device claimed with more channels never breaks.
List<ChannelConfig> localizedChannels(AppLocalizations l10n, int count) {
  return [
    for (var i = 0; i < count; i++)
      ChannelConfig(
        l10n.zoneName(i + 1),
        Icons.water_drop,
        const Color(0xFF0F766E),
        l10n.channelCode(i + 1),
      ),
  ];
}