import 'package:flutter/material.dart';
import '../devices/device_profile.dart';
import '../theme/app_theme.dart';
import '../widgets/stees_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.profileId,
    required this.onForget,
  });

  final String deviceId;
  final String deviceName;
  final String? profileId;
  final Future<void> Function() onForget;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          SteesSectionHeader(title: 'Device', count: 1),
          SteesCard(
            child: Column(
              children: [
                SteesInfoRow(icon: Icons.router_outlined, label: 'Name', value: Text(widget.deviceName)),
                const SizedBox(height: AppSpacing.sm),
                SteesInfoRow(icon: Icons.fingerprint_outlined, label: 'Identity', value: Text(widget.deviceId)),
                const SizedBox(height: AppSpacing.sm),
                SteesInfoRow(
                  icon: Icons.memory_outlined,
                  label: 'Hardware',
                  value: Text(DeviceProfile.fromId(widget.profileId).displayName),
                ),
                const SizedBox(height: AppSpacing.sm),
                const SteesInfoRow(icon: Icons.wifi_outlined, label: 'Link', value: Text('192.168.4.1 · local')),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: Text(
              'STEES Local v0.3 · 1s live sync',
              style: TextStyle(fontSize: 11, color: context.steesColors.mist),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SteesCard(
            borderColor: context.steesColors.danger,
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: context.steesColors.danger),
                onPressed: () => widget.onForget(),
                child: const Text('Forget device'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
