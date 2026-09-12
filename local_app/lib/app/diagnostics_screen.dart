import 'package:flutter/material.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key, required this.entries});
  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: entries.isEmpty
          ? const Center(child: Text('No local activity yet.'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: entries.length,
              itemBuilder: (_, i) => SelectableText(
                entries[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
    );
  }
}
