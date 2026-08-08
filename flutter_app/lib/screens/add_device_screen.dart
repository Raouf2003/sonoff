import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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
  Future<void> _openWizard() async {
    final done = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ProvisionDeviceScreen()));
    if (done == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      appBar: AppBar(
        title: Text('Add Device', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam)),
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
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: colors.submerged,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.water_drop_outlined, size: 40, color: colors.stream.withValues(alpha: 0.5)),
                      const SizedBox(height: 12),
                      Text(
                        'Use the guided wizard to configure a new device. '
                        'The device ID is generated automatically — no manual entry needed.',
                        style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity, height: 50,
                        child: FilledButton.icon(
                          onPressed: _openWizard,
                          icon: const Icon(Icons.bolt_outlined, size: 18),
                          label: Text('Provision New Device', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                          style: FilledButton.styleFrom(
                            backgroundColor: colors.stream,
                            foregroundColor: colors.well,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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