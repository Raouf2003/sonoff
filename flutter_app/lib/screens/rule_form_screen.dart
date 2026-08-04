import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';

class RuleFormScreen extends StatefulWidget {
  final String sensorId;
  final String sensorName;
  final int maxChannel;
  final Map<String, dynamic>? existing;
  const RuleFormScreen({super.key, required this.sensorId, required this.sensorName, this.maxChannel = 4, this.existing});

  @override
  State<RuleFormScreen> createState() => _RuleFormScreenState();
}

class _RuleFormScreenState extends State<RuleFormScreen> {
  final _nameCtl = TextEditingController();
  final _thresholdCtl = TextEditingController();
  final _api = ApiService();

  Set<int> _channels = {1};
  String _condition = 'below';
  String _action = 'ON';
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) _prefill(e);
  }

  void _prefill(Map<String, dynamic> rule) {
    _nameCtl.text = (rule['name'] as String?) ?? '';
    final rawThreshold = rule['threshold'];
    if (rawThreshold is num) {
      _thresholdCtl.text = rawThreshold == rawThreshold.roundToDouble()
          ? rawThreshold.toInt().toString()
          : rawThreshold.toString();
    }
    _condition = (rule['condition'] as String?) ?? 'below';
    _action = (rule['action'] as String?) ?? 'ON';

    final rawChannels = rule['channels'];
    _channels = {};
    if (rawChannels is List) {
      for (final c in rawChannels) {
        if (c is int) _channels.add(c);
      }
    } else if (rawChannels is int) {
      _channels.add(rawChannels);
    }
    if (_channels.isEmpty) _channels = {1};
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _thresholdCtl.dispose();
    super.dispose();
  }

  String get _oppositeAction => _action == 'ON' ? 'OFF' : 'ON';

  String get _logicSummary {
    final chs = _channels.toList()..sort();
    final chLabel = chs.map((c) => 'CH$c').join(' + ');
    final condLabel = _condition == 'above' ? 'above' : 'below';
    final t = _thresholdCtl.text.trim();
    final threshold = t.isEmpty ? '...' : t;
    if (chLabel.isEmpty || t.isEmpty) return '';
    return 'When soil $condLabel $threshold → $chLabel → $_action\nOtherwise → $chLabel → $_oppositeAction';
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    final threshold = double.tryParse(_thresholdCtl.text.trim());
    if (name.isEmpty) { _err('Enter a rule name'); return; }
    if (_channels.isEmpty) { _err('Select at least one channel'); return; }
    if (threshold == null) { _err('Enter a numeric threshold'); return; }

    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await _api.updateRule(
          widget.existing!['_id'] as String,
          name: name,
          channels: _channels.toList()..sort(),
          condition: _condition,
          threshold: threshold,
          action: _action,
        );
      } else {
        await _api.createRule(
          name: name,
          sensorId: widget.sensorId,
          channels: _channels.toList()..sort(),
          condition: _condition,
          threshold: threshold,
          action: _action,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _err(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _err(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: Colors.redAccent.shade200,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Rule' : 'New Rule', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
        backgroundColor: AppColors.well,
        iconTheme: const IconThemeData(color: AppColors.mist),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [AppColors.well, Color(0xFF0F2332), AppColors.well],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SensorBanner(sensorName: widget.sensorName, sensorId: widget.sensorId),
                const SizedBox(height: 20),

                _SectionCard(
                  eyebrow: 'IDENTITY',
                  child: TextField(
                    controller: _nameCtl,
                    style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
                    textInputAction: TextInputAction.next,
                    decoration: _inputDec('Rule name', 'e.g. Auto-water when dry', Icons.label_outline),
                  ),
                ),
                const SizedBox(height: 14),

                _SectionCard(
                  eyebrow: 'CHANNELS',
                  description: 'Pick every relay this rule should control.',
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [for (int i = 1; i <= widget.maxChannel; i++) _ChannelChip(
                      label: 'CH$i',
                      selected: _channels.contains(i),
                      color: AppColors.stream,
                      onTap: () {
                        setState(() {
                          if (_channels.contains(i)) {
                            _channels.remove(i);
                          } else {
                            _channels.add(i);
                          }
                        });
                      },
                    )],
                  ),
                ),
                const SizedBox(height: 14),

                _SectionCard(
                  eyebrow: 'CONDITION',
                  description: 'The sensor reading that triggers the rule.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'below', label: Text('Below', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                          ButtonSegment(value: 'above', label: Text('Above', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                        ],
                        selected: {_condition},
                        style: SegmentedButton.styleFrom(
                          backgroundColor: AppColors.well,
                          selectedBackgroundColor: AppColors.stream,
                          selectedForegroundColor: AppColors.well,
                          foregroundColor: AppColors.mist,
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        onSelectionChanged: (s) => setState(() => _condition = s.first),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _thresholdCtl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
                        onChanged: (_) => setState(() {}),
                        decoration: _inputDec('Threshold value', 'e.g. 30', Icons.pin_outlined),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                _SectionCard(
                  eyebrow: 'ACTION',
                  description: 'What happens when the condition is true.',
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'ON', label: Text('Turn ON', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                      ButtonSegment(value: 'OFF', label: Text('Turn OFF', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                    ],
                    selected: {_action},
                    style: SegmentedButton.styleFrom(
                      backgroundColor: AppColors.well,
                      selectedBackgroundColor: _action == 'ON' ? AppColors.leaf : AppColors.sunlight,
                      selectedForegroundColor: AppColors.well,
                      foregroundColor: AppColors.mist,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    onSelectionChanged: (s) => setState(() => _action = s.first),
                  ),
                ),
                const SizedBox(height: 18),

                if (_logicSummary.isNotEmpty)
                  _LogicPreview(
                    condition: _condition,
                    action: _action,
                    opposite: _oppositeAction,
                    channels: _channels.toList()..sort(),
                    threshold: _thresholdCtl.text.trim(),
                  ),
                if (_logicSummary.isNotEmpty) const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity, height: 52,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.stream,
                      foregroundColor: AppColors.well,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _saving
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.well))
                        : Text(_isEdit ? 'Save Changes' : 'Create Rule', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDec(String hint, String helper, IconData icon) {
    return InputDecoration(
      hintText: hint,
      helperText: helper,
      helperStyle: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.5)),
      hintStyle: GoogleFonts.inter(fontSize: 14, color: AppColors.mist.withValues(alpha: 0.6)),
      prefixIcon: Icon(icon, size: 18, color: AppColors.mist),
      filled: true,
      fillColor: AppColors.well,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.stream, width: 1.5),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Sensor Banner
// ──────────────────────────────────────────────────────────────

class _SensorBanner extends StatelessWidget {
  final String sensorName;
  final String sensorId;
  const _SensorBanner({required this.sensorName, required this.sensorId});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.stream.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.stream.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.stream.withValues(alpha: 0.15),
            ),
            child: const Icon(Icons.sensors, size: 20, color: AppColors.stream),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sensorName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
                const SizedBox(height: 2),
                Text(sensorId, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Section Card (matches schedule form pattern)
// ──────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String eyebrow;
  final String? description;
  final Widget child;
  const _SectionCard({required this.eyebrow, required this.child, this.description});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.submerged,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 20, height: 2, decoration: BoxDecoration(color: AppColors.stream, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Text(eyebrow, style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.8, color: AppColors.stream)),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(description!, style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.7))),
            ),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Channel Chip (animated, matches schedule form)
// ──────────────────────────────────────────────────────────────

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _ChannelChip({required this.label, required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? color : AppColors.well,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? color : Colors.white.withValues(alpha: 0.1),
            width: selected ? 0 : 1,
          ),
          boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 8)] : null,
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? AppColors.well : AppColors.foam),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Logic Preview — the signature element
// ──────────────────────────────────────────────────────────────

class _LogicPreview extends StatelessWidget {
  final String condition;
  final String action;
  final String opposite;
  final List<int> channels;
  final String threshold;
  const _LogicPreview({
    required this.condition,
    required this.action,
    required this.opposite,
    required this.channels,
    required this.threshold,
  });

  @override
  Widget build(BuildContext context) {
    final chLabel = channels.map((c) => 'CH$c').join(' + ');
    final condWord = condition == 'above' ? 'above' : 'below';
    final actionColor = action == 'ON' ? AppColors.leaf : AppColors.sunlight;
    final oppositeColor = opposite == 'ON' ? AppColors.leaf : AppColors.sunlight;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.submerged,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.stream.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.preview, size: 16, color: AppColors.stream.withValues(alpha: 0.7)),
              const SizedBox(width: 6),
              Text('LOGIC', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.8, color: AppColors.stream)),
            ],
          ),
          const SizedBox(height: 14),
          _LogicRow(
            icon: Icons.check_circle_outline,
            color: actionColor,
            label: 'IF soil $condWord $threshold',
            detail: '$chLabel → $action',
          ),
          const SizedBox(height: 8),
          _LogicRow(
            icon: Icons.cancel_outlined,
            color: oppositeColor,
            label: 'OTHERWISE',
            detail: '$chLabel → $opposite',
          ),
        ],
      ),
    );
  }
}

class _LogicRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String detail;
  const _LogicRow({required this.icon, required this.color, required this.label, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(text: '$label  ', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.foam)),
                TextSpan(text: detail, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
