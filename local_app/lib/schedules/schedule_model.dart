import 'dart:convert';

class TimeRange {
  const TimeRange({required this.start, required this.end});
  final String start;
  final String end;

  Map<String, String> toJson() => {'start': start, 'end': end};

  factory TimeRange.fromJson(Map<String, dynamic> json) {
    return TimeRange(start: '${json['start']}', end: '${json['end']}');
  }
}

class LocalSchedule {
  const LocalSchedule({
    required this.id,
    required this.name,
    required this.channels,
    required this.recurrenceType,
    this.daysOfWeek = const [],
    required this.timeRanges,
    this.enabled = true,
  });

  final String id;
  final String name;
  final List<int> channels;
  final String recurrenceType;
  final List<int> daysOfWeek;
  final List<TimeRange> timeRanges;
  final bool enabled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'channels': channels,
        'recurrenceType': recurrenceType,
        'daysOfWeek': daysOfWeek,
        'timeRanges': [for (final r in timeRanges) r.toJson()],
        'enabled': enabled,
      };

  factory LocalSchedule.fromJson(Map<String, dynamic> json) {
    return LocalSchedule(
      id: '${json['id']}',
      name: '${json['name'] ?? ''}',
      channels: [for (final c in (json['channels'] as List? ?? [])) (c as num).toInt()],
      recurrenceType: '${json['recurrenceType'] ?? 'daily'}',
      daysOfWeek: [for (final d in (json['daysOfWeek'] as List? ?? [])) (d as num).toInt()],
      timeRanges: [
        for (final r in (json['timeRanges'] as List? ?? []))
          TimeRange.fromJson((r as Map).cast<String, dynamic>())
      ],
      enabled: json['enabled'] != false,
    );
  }

  String encode() => jsonEncode(toJson());

  static LocalSchedule? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return LocalSchedule.fromJson(decoded);
      if (decoded is Map) return LocalSchedule.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {}
    return null;
  }
}
