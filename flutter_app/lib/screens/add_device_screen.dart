import 'package:flutter/material.dart';
import '../services/api_service.dart';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _deviceIdController = TextEditingController();
  final _nameController = TextEditingController();
  final _api = ApiService();
  bool _loading = false;

  @override
  void dispose() {
    _deviceIdController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    final deviceId = _deviceIdController.text.trim();
    final name = _nameController.text.trim();

    if (deviceId.isEmpty || name.isEmpty) {
      _showError('Please fill in all fields');
      return;
    }

    setState(() => _loading = true);
    try {
      await _api.claimDevice(deviceId, name);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      _showError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent, behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Device'),
        backgroundColor: const Color(0xFF0D1117),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xFF0D1117), Color(0xFF161B22), Color(0xFF0D1117)],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C2333),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Text(
                      'Enter the Device ID printed on your device or configured in Tasmota.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _deviceIdController,
                      decoration: InputDecoration(
                        labelText: 'Device ID',
                        hintText: 'e.g. sonoff_8F9BC4',
                        prefixIcon: const Icon(Icons.devices),
                        filled: true, fillColor: const Color(0xFF0D1117),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: 'Device Name',
                        hintText: 'e.g. Garden Controller',
                        prefixIcon: const Icon(Icons.label_outline),
                        filled: true, fillColor: const Color(0xFF0D1117),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _claim(),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity, height: 50,
                      child: FilledButton(
                        onPressed: _loading ? null : _claim,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _loading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black))
                            : const Text('Claim Device', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
