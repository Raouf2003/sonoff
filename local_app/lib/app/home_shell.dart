import 'package:flutter/material.dart';
import '../connection/session.dart';
import '../theme/theme_controller.dart';
import '../widgets/stees_nav_bar.dart';
import 'home_screen.dart';
import '../schedules/schedule_list_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.password,
    required this.themes,
    required this.session,
    required this.onForget,
  });

  final String deviceId;
  final String deviceName;
  final String? password;
  final ThemeController themes;
  final SessionState session;
  final Future<void> Function() onForget;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(
            deviceId: widget.deviceId,
            deviceName: widget.deviceName,
            password: widget.password,
            themes: widget.themes,
            session: widget.session,
            profileId: widget.session.session?.profileId,
          ),
          ScheduleListScreen(
            deviceId: widget.deviceId,
            password: widget.password,
          ),
          SettingsScreen(
            deviceId: widget.deviceId,
            deviceName: widget.deviceName,
            profileId: widget.session.session?.profileId,
            onForget: widget.onForget,
          ),
        ],
      ),
      bottomNavigationBar: SteesNavBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          SteesNavItem(icon: Icons.power_outlined, activeIcon: Icons.power, label: 'Relays'),
          SteesNavItem(icon: Icons.schedule_outlined, activeIcon: Icons.schedule, label: 'Schedules'),
          SteesNavItem(icon: Icons.settings_outlined, activeIcon: Icons.settings, label: 'Settings'),
        ],
      ),
    );
  }
}
