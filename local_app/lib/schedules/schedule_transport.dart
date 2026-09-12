import 'dart:async';
import 'dart:convert';
import '../transport/local_device_transport.dart';
import 'schedule_compiler.dart';

const Duration kScheduleBudget = Duration(seconds: 45);

class ScheduleSyncException implements Exception {
  const ScheduleSyncException(this.message, {this.slots = const []});
  final String message;
  final List<int> slots;
  @override
  String toString() => message;
}

class DeviceScheduleState {
  const DeviceScheduleState({required this.timers, required this.rule2, required this.rule2On});
  final Map<int, TimerConfig> timers;
  final String rule2;
  final bool rule2On;
}

class ScheduleTransport {
  ScheduleTransport({TasmotaCmFetcher? fetch}) : _fetch = fetch ?? defaultTasmotaCmFetcher;

  final TasmotaCmFetcher _fetch;

  Map<String, dynamic>? _objectFor(String body, String key) {
    try {
      final decoded = jsonDecode(body.trim());
      if (decoded is Map<String, dynamic>) {
        final inner = decoded[key];
        if (inner is Map<String, dynamic>) return inner;
        if (inner is Map) return inner.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  Future<DeviceScheduleState> readState(String address, {String? password}) async {
    Future<String> cm(String command) => _fetch(address, command, password: password);
    final timers = <int, TimerConfig>{};
    for (var i = 1; i <= kMaxTimers; i++) {
      final body = await cm('Timer$i');
      timers[i] = TimerConfig.fromDevice(_objectFor(body, 'Timer$i')) ?? TimerConfig.factoryDefault;
    }
    var rule2 = '';
    var rule2On = false;
    final ruleBody = await cm('Rule$kSteesRuleIndex');
    try {
      final decoded = jsonDecode(ruleBody.trim());
      if (decoded is String) {
        rule2 = decoded;
        rule2On = rule2.isNotEmpty;
      } else if (decoded is Map) {
        final inner = decoded['Rule$kSteesRuleIndex'];
        if (inner is String) {
          rule2 = inner;
          rule2On = rule2.isNotEmpty;
        } else if (inner is Map) {
          final map = inner is Map<String, dynamic> ? inner : const <String, dynamic>{};
          rule2 = '${map['Rules'] ?? ''}';
          rule2On = '${map['State'] ?? ''}'.toUpperCase() == 'ON';
        }
      }
    } catch (_) {}
    return DeviceScheduleState(timers: timers, rule2: rule2, rule2On: rule2On);
  }

  Future<void> applyPlan(
    String address,
    CompiledPlan plan, {
    String? password,
    Set<int> managedSlots = const {},
    bool ruleManaged = false,
  }) async {
    if (!plan.isValid) {
      throw ScheduleSyncException(
        'Cannot apply schedules:\n${plan.unsupportedReasons.join('\n')}',
      );
    }
    await _apply(address, plan, password: password, managedSlots: managedSlots, ruleManaged: ruleManaged)
        .timeout(kScheduleBudget);
  }

  Future<void> _apply(
    String address,
    CompiledPlan plan, {
    String? password,
    Set<int> managedSlots = const {},
    bool ruleManaged = false,
  }) async {
    Future<String> cm(String command) => _fetch(address, command, password: password);

    final desired = <int, TimerConfig>{};
    for (var i = 1; i <= kMaxTimers; i++) {
      desired[i] = TimerConfig.factoryDefault;
    }
    for (final t in plan.timers) {
      desired[t.index] = t.config;
    }

    final current = await readState(address, password: password);

    for (var i = 1; i <= kMaxTimers; i++) {
      if (desired[i] != current.timers[i] &&
          current.timers[i] != null &&
          !current.timers[i]!.isDefault &&
          !managedSlots.contains(i)) {
        throw ScheduleSyncException(
          'Timer$i holds configuration this app did not create. Clear it on the device console first.',
          slots: [i],
        );
      }
    }
    final ruleWanted = plan.ruleText;
    if (ruleWanted != current.rule2 && current.rule2.isNotEmpty && !ruleManaged) {
      throw const ScheduleSyncException(
        'Rule2 holds configuration this app did not create. Clear it on the device console first.',
      );
    }

    for (var i = 1; i <= kMaxTimers; i++) {
      if (desired[i] != current.timers[i]) {
        final payload = Uri.encodeComponent(desired[i]!.toPayload());
        final echo = await cm('Timer$i%20$payload');
        final written = TimerConfig.fromDevice(_objectFor(echo, 'Timer$i'));
        if (written != desired[i]) {
          throw ScheduleSyncException('Timer$i was not confirmed by the device.', slots: [i]);
        }
      }
    }

    if (ruleWanted != current.rule2) {
      if (ruleWanted.isEmpty) {
        await cm('Rule$kSteesRuleIndex%200');
      } else {
        await cm('Rule$kSteesRuleIndex%20${Uri.encodeComponent(ruleWanted)}');
        await cm('Rule$kSteesRuleIndex%201');
      }
    }

    await cm('Timers%201');

    var verify = await readState(address, password: password);
    for (var i = 1; i <= kMaxTimers; i++) {
      if (verify.timers[i] != desired[i]) {
        throw ScheduleSyncException('Timer$i read-back mismatch after sync.', slots: [i]);
      }
    }
    if (verify.rule2 != ruleWanted) {
      await Future<void>.delayed(const Duration(seconds: 2));
      verify = await readState(address, password: password);
    }
    if (verify.rule2 != ruleWanted) {
      throw ScheduleSyncException(
        'Rule2 read-back mismatch after sync.\nExpected: ${_clip(ruleWanted)}\nDevice: ${_clip(verify.rule2)}',
      );
    }
    if (ruleWanted.isNotEmpty && !verify.rule2On) {
      throw const ScheduleSyncException('Rule2 was written but is not active.');
    }
  }
}

String _clip(String value, [int max = 160]) {
  return value.length <= max ? value : '${value.substring(0, max)}…';
}
