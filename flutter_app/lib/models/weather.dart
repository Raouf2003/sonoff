class WeatherHour {
  final String localTime;
  final double? temperature;
  final double precipitationMm;
  final int precipitationProbability;

  const WeatherHour({
    required this.localTime,
    required this.temperature,
    required this.precipitationMm,
    required this.precipitationProbability,
  });

  String get hhmm {
    final m = RegExp(r'T(\d{2}):(\d{2})').firstMatch(localTime);
    return m == null ? localTime : '${m.group(1)}:${m.group(2)}';
  }

  String get date {
    return localTime.length >= 10 ? localTime.substring(0, 10) : localTime;
  }

  factory WeatherHour.fromJson(Map<String, dynamic> json) {
    return WeatherHour(
      localTime: '${json['localTime'] ?? ''}',
      temperature: (json['temperature'] as num?)?.toDouble(),
      precipitationMm: (json['precipitationMm'] as num?)?.toDouble() ?? 0,
      precipitationProbability:
          (json['precipitationProbability'] as num?)?.toInt() ?? 0,
    );
  }
}

class WeatherAdvisory {
  final String type;
  final String severity;
  final String scheduleId;
  final String scheduleName;
  final List<int> channels;
  final String scheduleStart;
  final String scheduleEnd;
  final String rainDate;
  final String rainStart;
  final String rainEnd;
  final double precipitationMm;
  final int probability;
  // Overlap detail already served by the API (may be absent on older
  // payloads); parsed for display only, never reinterpreted.
  final String? overlapStart;
  final String? overlapEnd;
  final int overlapMinutes;

  const WeatherAdvisory({
    required this.type,
    required this.severity,
    required this.scheduleId,
    required this.scheduleName,
    required this.channels,
    required this.scheduleStart,
    required this.scheduleEnd,
    required this.rainDate,
    required this.rainStart,
    required this.rainEnd,
    required this.precipitationMm,
    required this.probability,
    this.overlapStart,
    this.overlapEnd,
    this.overlapMinutes = 0,
  });

  bool get isOverlap => type == 'overlap';

  factory WeatherAdvisory.fromJson(Map<String, dynamic> json) {
    return WeatherAdvisory(
      type: '${json['type'] ?? 'overlap'}',
      severity: '${json['severity'] ?? 'HIGH'}',
      scheduleId: '${json['scheduleId'] ?? ''}',
      scheduleName: '${json['scheduleName'] ?? ''}',
      channels: [
        for (final c in (json['channels'] as List<dynamic>? ?? []))
          if (c is num) c.toInt() else int.tryParse('$c') ?? 0,
      ],
      scheduleStart: '${json['scheduleStart'] ?? '--:--'}',
      scheduleEnd: '${json['scheduleEnd'] ?? '--:--'}',
      rainDate: '${json['rainDate'] ?? ''}',
      rainStart: '${json['rainStart'] ?? '--:--'}',
      rainEnd: '${json['rainEnd'] ?? '--:--'}',
      precipitationMm:
          (json['precipitationMm'] as num?)?.toDouble() ?? 0,
      probability: (json['probability'] as num?)?.toInt() ?? 0,
      overlapStart: json['overlapStart'] as String?,
      overlapEnd: json['overlapEnd'] as String?,
      overlapMinutes: (json['overlapMinutes'] as num?)?.toInt() ?? 0,
    );
  }
}

class WeatherSchedule {
  final String scheduleId;
  final List<int> channels;
  final List<Map<String, String>> timeRanges;

  const WeatherSchedule({
    required this.scheduleId,
    required this.channels,
    required this.timeRanges,
  });

  String get window {
    if (timeRanges.isEmpty) return '--:--';
    final extra = timeRanges.length > 1 ? ' +${timeRanges.length - 1}' : '';
    return '${timeRanges.first['start'] ?? '--:--'}–${timeRanges.first['end'] ?? '--:--'}$extra';
  }

  factory WeatherSchedule.fromJson(Map<String, dynamic> json) {
    return WeatherSchedule(
      scheduleId: '${json['scheduleId'] ?? ''}',
      channels: [
        for (final c in (json['channels'] as List<dynamic>? ?? []))
          if (c is num) c.toInt() else int.tryParse('$c') ?? 0,
      ],
      timeRanges: [
        for (final r in (json['timeRanges'] as List<dynamic>? ?? []))
          if (r is Map)
            {
              'start': '${r['start'] ?? '--:--'}',
              'end': '${r['end'] ?? '--:--'}',
            },
      ],
    );
  }
}

class WeatherToday {
  final String deviceId;
  final String timezone;
  final String? farmName;
  final double? lat;
  final double? lon;
  final bool weatherDisabled;
  final bool weatherUnavailable;
  final double? temperature;
  final int rainProbability;
  final double precipitationMm;
  final String? fetchedAt;
  final List<WeatherHour> hourly;
  final List<WeatherSchedule> schedules;
  final List<WeatherAdvisory> advisories;

  const WeatherToday({
    required this.deviceId,
    required this.timezone,
    required this.farmName,
    required this.lat,
    required this.lon,
    required this.weatherDisabled,
    required this.weatherUnavailable,
    required this.temperature,
    required this.rainProbability,
    required this.precipitationMm,
    required this.fetchedAt,
    required this.hourly,
    required this.schedules,
    required this.advisories,
  });

  List<WeatherHour> hoursForDate(String date) =>
      hourly.where((h) => h.date == date).toList();

  factory WeatherToday.fromJson(Map<String, dynamic> json) {
    final loc = (json['location'] as Map?)?.cast<String, dynamic>() ?? {};
    final fc = (json['forecast'] as Map?)?.cast<String, dynamic>();
    return WeatherToday(
      deviceId: '${json['deviceId'] ?? ''}',
      timezone: '${json['timezone'] ?? 'Africa/Algiers'}',
      farmName: loc['farmName'] as String?,
      lat: (loc['lat'] as num?)?.toDouble(),
      lon: (loc['lon'] as num?)?.toDouble(),
      weatherDisabled: json['weatherDisabled'] == true,
      weatherUnavailable: json['weatherUnavailable'] == true,
      temperature: (fc?['temperature'] as num?)?.toDouble(),
      rainProbability: (fc?['rainProbability'] as num?)?.toInt() ?? 0,
      precipitationMm: (fc?['precipitationMm'] as num?)?.toDouble() ?? 0,
      fetchedAt: json['fetchedAt'] as String?,
      hourly: [
        for (final h in (json['hourly'] as List<dynamic>? ?? []))
          if (h is Map<String, dynamic>)
            WeatherHour.fromJson(h)
          else if (h is Map)
            WeatherHour.fromJson(h.cast<String, dynamic>()),
      ],
      schedules: [
        for (final s in (json['schedules'] as List<dynamic>? ?? []))
          if (s is Map<String, dynamic>)
            WeatherSchedule.fromJson(s)
          else if (s is Map)
            WeatherSchedule.fromJson(s.cast<String, dynamic>()),
      ],
      advisories: [
        for (final a in (json['advisories'] as List<dynamic>? ?? []))
          if (a is Map<String, dynamic>)
            WeatherAdvisory.fromJson(a)
          else if (a is Map)
            WeatherAdvisory.fromJson(a.cast<String, dynamic>()),
      ],
    );
  }
}
