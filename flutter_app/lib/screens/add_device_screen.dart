import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../l10n/gen/app_localizations.dart';
import '../theme/app_theme.dart';
import 'provision_device_screen.dart';

/// Entry point for adding a new device. The old manual Device ID entry form is
/// gone — Device IDs are generated automatically by the provisioning wizard.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  static const _wifiChannel = MethodChannel('stees/wifi_settings');

  Future<void> _openWizard() async {
    var wifiOff = false;
    try {
      final pre = await _wifiChannel
          .invokeMethod<Map<dynamic, dynamic>>('wifiPreflight');
      if (pre != null &&
          pre.containsKey('wifiEnabled') &&
          pre['wifiEnabled'] == false) {
        wifiOff = true;
      }
    } catch (_) {
      // Preflight unavailable (iOS / tests): proceed to wizard.
    }
    if (!mounted) return;

    if (wifiOff) {
      final colors = context.steesColors;
      final l10n = AppLocalizations.of(context)!;
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(l10n.adWifiOff,
              style: GoogleFonts.sora(
                  fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam)),
          content: Text(
            l10n.adWifiOffHint,
            style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.sharedCancel,
                  style: GoogleFonts.inter(fontSize: 13, color: colors.mist)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.adTurnOn,
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: colors.stream)),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (open == true) {
        try {
          await _wifiChannel.invokeMethod<void>('openInternetPanel');
        } catch (_) {
          try {
            await _wifiChannel.invokeMethod<void>('openWifiSettings');
          } catch (_) {}
        }
      }
      return;
    }

    final done = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ProvisionDeviceScreen()));
    if (done == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.adTitle, style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam)),
        backgroundColor: colors.well,
        iconTheme: IconThemeData(color: colors.mist),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [colors.well, Theme.of(context).colorScheme.surfaceContainerHighest, colors.well],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: colors.submerged,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: colors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              color: colors.well,
                              border: Border.all(color: colors.border),
                            ),
                            child: Icon(Icons.water_drop_outlined,
                                size: 20, color: colors.stream),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.adHeading,
                                  style: GoogleFonts.sora(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: colors.foam),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  l10n.adGuided,
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.6,
                                    color: colors.mist.withValues(alpha: 0.55),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        l10n.adWizardHint,
                        style: GoogleFonts.inter(
                            fontSize: 12.5, height: 1.5, color: colors.mist),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      SizedBox(
                        width: double.infinity, height: 50,
                        child: FilledButton.icon(
                          onPressed: _openWizard,
                          icon: const Icon(Icons.bolt_outlined, size: 18),
                          label: Text(l10n.adProvision, style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                          style: FilledButton.styleFrom(
                            backgroundColor: colors.stream,
                            foregroundColor: colors.well,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
