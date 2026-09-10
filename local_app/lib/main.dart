import 'package:flutter/material.dart';
import 'app/home_shell.dart';
import 'connection/ap_connect_screen.dart';
import 'connection/session.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

void main() {
  runApp(const SteesLocalApp());
}

class SteesLocalApp extends StatefulWidget {
  const SteesLocalApp({super.key, SessionState? session, ThemeController? themes})
      : _session = session,
        _themes = themes;

  final SessionState? _session;
  final ThemeController? _themes;

  @override
  State<SteesLocalApp> createState() => _SteesLocalAppState();
}

class _SteesLocalAppState extends State<SteesLocalApp> {
  late final SessionState _session;
  late final ThemeController _themes;

  @override
  void initState() {
    super.initState();
    _session = widget._session ?? SessionState();
    _session.load();
    _themes = widget._themes ?? ThemeController();
    _themes.load();
  }

  Future<void> _forget() async {
    await _session.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themes,
      builder: (context, _) {
        return MaterialApp(
          title: 'STEES Local',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: _themes.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 350),
          themeAnimationCurve: Curves.easeInOut,
          home: ListenableBuilder(
            listenable: _session,
            builder: (context, _) {
              if (!_session.loaded) {
                return const Scaffold(body: Center(child: CircularProgressIndicator()));
              }
              final session = _session.session;
              if (session == null) {
                return ApConnectScreen(session: _session);
              }
              return HomeShell(
                key: ValueKey(session.mac),
                deviceId: session.mac,
                deviceName: session.name,
                password: session.password,
                themes: _themes,
                session: _session,
                onForget: _forget,
              );
            },
          ),
        );
      },
    );
  }
}
