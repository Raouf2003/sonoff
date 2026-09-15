import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';import '../models/weather.dart';
import '../services/api_service.dart';
import '../services/weather_notification_service.dart';
import 'weather_location_picker_page.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../widgets/stees_widgets.dart';

class WeatherPage extends StatefulWidget {
  final void Function(int index)? onNavigateToTab;
  final ApiService? api;

  const WeatherPage({super.key, this.onNavigateToTab, this.api});

  /// Test-only override for the notification-tap device handoff. The real
  /// reader touches Firebase (unavailable in widget tests); when set, it is
  /// used exclusively. Null in production — behavior unchanged.
  @visibleForTesting
  static String? Function()? pendingDeviceReader;

  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  late final ApiService _api = widget.api ?? ApiService();
  List<Map<String, dynamic>> _devices = [];
  String? _selectedDeviceId;
  WeatherToday? _weather;
  bool _loadingDevices = true;
  bool _loadingWeather = false;
  bool _loadError = false;
  String? _errorMessage;
  DateTime? _retrievedAt;
  int _hourlyDay = 0;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loadingDevices = true;
      _loadError = false;
      _errorMessage = null;
    });
    try {
      final devices = await _api.getDevices();
      if (!mounted) return;
      // If launched from notification, pre-select that device
      final pending = WeatherPage.pendingDeviceReader != null
          ? WeatherPage.pendingDeviceReader!()
          : WeatherNotificationService().pendingDeviceId;
      final hasPending = pending != null && devices.any((d) => d['deviceId'] == pending);
      setState(() {
        _devices = devices.cast<Map<String, dynamic>>();
        _loadingDevices = false;
        if (hasPending) {
          _selectedDeviceId = pending;
          WeatherNotificationService().consumePending();
        } else if (_devices.isNotEmpty) {
          _selectedDeviceId ??= _devices.first['deviceId'] as String?;
        }
      });
      if (_selectedDeviceId != null) await _loadWeather();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDevices = false;
        _loadError = _devices.isEmpty;
        _errorMessage = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingDevices = false;
        _loadError = _devices.isEmpty;
      });
    }
  }

  Future<void> _loadWeather() async {
    final deviceId = _selectedDeviceId;
    if (deviceId == null) return;
    setState(() {
      _loadingWeather = true;
      _errorMessage = null;
    });
    try {
      final res = await _api.getWeatherToday(deviceId);
      if (!mounted) return;
      setState(() {
        _weather = WeatherToday.fromJson(res);
        _loadingWeather = false;
        _retrievedAt = DateTime.now();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingWeather = false;
        _errorMessage = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingWeather = false;
        _errorMessage = 'Could not load weather.';
      });
    }
  }

  Future<void> _openLocationPicker() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WeatherLocationPickerPage(
          devices: _devices,
          initialDeviceId: _selectedDeviceId,
          api: _api,
        ),
      ),
    );
    if (saved == true) {
      await _loadDevices();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    if (_loadingDevices) return const SteesLoading();
    if (_loadError && _devices.isEmpty) {
      return SteesError(
        title: 'Could not load devices',
        subtitle: _errorMessage ?? 'Check your connection and try again.',
        onRetry: _loadDevices,
      );
    }
    if (_devices.isEmpty) {
      return const SteesEmpty(
        icon: Icons.cloud_outlined,
        title: 'No devices yet',
        subtitle: 'Claim a device to enable weather forecasts.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadWeather,
      color: colors.stream,
      child: ListView(
        physics:
            const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xxxl),
        children: [
          _buildPageTitle(colors),
          _buildDeviceSelector(colors),
          const SizedBox(height: AppSpacing.md),
          if (_loadingWeather && _weather == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: SteesLoading(),
            )
          else if (_errorMessage != null && _weather == null)
            SteesError(
              title: 'Could not load weather',
              subtitle: _errorMessage!,
              onRetry: _loadWeather,
            )
          else if (_weather != null)
            ..._buildWeatherBody(colors),
        ],
      ),
    );
  }

  Widget _buildPageTitle(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xs, AppSpacing.sm, AppSpacing.xs, AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'WEATHER',
              style: GoogleFonts.sora(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.8,
                color: colors.mist,
              ),
            ),
          ),
          IconButton(
            onPressed: _loadingWeather ? null : _loadWeather,
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSelector(SteesColors colors) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedDeviceId,
              isExpanded: true,
              dropdownColor: colors.submerged,
              icon: Icon(Icons.keyboard_arrow_down, color: colors.mist),
              items: [
                for (final d in _devices)
                  DropdownMenuItem<String>(
                    value: '${d['deviceId']}',
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${d['farmName'] ?? d['name'] ?? d['deviceId']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: colors.foam),
                              ),
                              Text(
                                _deviceSubline(d),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.jetBrainsMono(
                                    fontSize: 10, color: colors.mist),
                              ),
                            ],
                          ),
                        ),
                        if (d['lat'] == null || d['lon'] == null)
                          Icon(Icons.location_off_outlined,
                              size: 14,
                              color: colors.mist.withValues(alpha: 0.6))
                        else
                          Icon(Icons.cloud_outlined,
                              size: 14,
                              color: colors.stream.withValues(alpha: 0.7)),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null || v == _selectedDeviceId) return;
                setState(() {
                  _selectedDeviceId = v;
                  _weather = null;
                });
                _loadWeather();
              },
            ),
          ),
          if (_weather != null && !_weather!.weatherDisabled) ...[
            Divider(color: colors.border, height: AppSpacing.lg),
            _buildLocationLine(colors, _weather!),
          ],
        ],
      ),
    );
  }

  /// Second selector line: device name + id, unless the name is already shown
  /// as the primary (farm) line.
  String _deviceSubline(Map<String, dynamic> d) {
    final id = '${d['deviceId']}';
    final name = d['name'] != null ? '${d['name']}' : null;
    final primary = '${d['farmName'] ?? d['name'] ?? id}';
    if (name == null || name.isEmpty || name == primary) return id;
    return '$name · $id';
  }

  List<Widget> _buildWeatherBody(SteesColors colors) {
    final w = _weather!;
    if (w.weatherDisabled) {
      return [
        SteesEmpty(
          icon: Icons.location_off_outlined,
          title: 'Weather location not configured',
          subtitle:
              'This device does not have a farm location yet. Select a location on the map to enable weather for this device.',
          action: FilledButton.tonalIcon(
            onPressed: _openLocationPicker,
            icon: const Icon(Icons.location_on_outlined, size: 18),
            label: Text('Set Location',
                style: GoogleFonts.sora(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ];
    }
    if (w.weatherUnavailable) {
      return [
        _buildUnavailableCard(colors),
        const SizedBox(height: AppSpacing.md),
        _buildScheduleSection(colors, w),
      ];
    }
    // Hierarchy: CURRENT CONDITIONS → RAIN FORECAST → IRRIGATION IMPACT.
    // Keeps the page irrigation-first: what is happening → what is
    // expected → will it affect irrigation → today's schedule list.
    return [
      _buildNowSection(colors, w),
      const SizedBox(height: AppSpacing.md),
      _buildHourlySection(colors, w),
      const SizedBox(height: AppSpacing.md),
      ..._buildAdvisoryCards(colors, w),
      _buildScheduleSection(colors, w),
    ];
  }

  /// Compact unavailable notice (the only verdict-style card kept): the
  /// forecast failed, schedules are unaffected, retry is one tap away.
  Widget _buildUnavailableCard(SteesColors colors) {
    return SteesCard(
      active: false,
      borderColor: colors.mist.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_off_outlined, size: 22, color: colors.mist),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Forecast unavailable',
                        style: GoogleFonts.sora(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: colors.foam)),
                    const SizedBox(height: 2),
                    Text(
                        'Your irrigation schedules are unaffected and will run as programmed.',
                        style: GoogleFonts.inter(
                            fontSize: 12.5,
                            height: 1.45,
                            color: colors.mist)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _loadingWeather ? null : _loadWeather,
              icon: Icon(Icons.refresh, size: 15, color: colors.stream),
              label: Text('Retry',
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.stream)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationLine(SteesColors colors, WeatherToday w) {
    // Coordinates only: the farm/device name already heads the selector
    // above, so repeating it here duplicated the same name twice.
    final coords = w.lat != null && w.lon != null
        ? '${w.lat!.toStringAsFixed(2)}, ${w.lon!.toStringAsFixed(2)}'
        : w.timezone;
    return Row(
      children: [
        Icon(Icons.location_on_outlined, size: 14, color: colors.mist),
        const SizedBox(width: 6),
        Expanded(
          child: Text(coords,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
        ),
        InkWell(
          onTap: _openLocationPicker,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_outlined, size: 13, color: colors.stream),
                const SizedBox(width: 2),
                Text('Edit',
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colors.stream)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Current conditions: temperature dominant, precipitation secondary with
  /// honest forecast wording. Probability is intentionally omitted here —
  /// it belongs to future forecast cells only. Open-Meteo hourly
  /// precipitation is an accumulated hourly amount, so wording is
  /// "Precipitation · Last hour" rather than an instantaneous sensor claim.
  Widget _buildNowSection(SteesColors colors, WeatherToday w) {
    // Updated line uses the existing fetched/retrieved timestamps already on
    // the model — no new data source, just surfaced in-card as spec requests.
    final updated = _retrievedAt ?? (w.fetchedAt != null ? DateTime.tryParse(w.fetchedAt!) : null);
    String updatedLabel = w.timezone;
    if (updated != null) {
      String pad(int n) => n.toString().padLeft(2, '0');
      updatedLabel = 'Updated ${pad(updated.hour)}:${pad(updated.minute)} · ${w.timezone}';
    }
    final precipLabel = w.precipitationMm > 0 ? 'Precipitation' : 'Precipitation';
    final precipSubtitle = 'Last hour';
    return SteesCard(
      active: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CURRENT CONDITIONS',
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: colors.stream)),
          const SizedBox(height: AppSpacing.md),
          // Temperature: dominant numeric value.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                  w.temperature == null
                      ? '—'
                      : '${w.temperature!.toStringAsFixed(0)}°',
                  style: GoogleFonts.sora(
                      fontSize: 42,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      color: colors.foam)),
              const SizedBox(width: AppSpacing.sm),
              Text('Temperature',
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.mist)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Precipitation: second most important, with honest period wording.
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.stream.withValues(alpha: 0.10),
                  border: Border.all(color: colors.stream.withValues(alpha: 0.22)),
                ),
                child: Icon(Icons.water_drop_outlined, size: 18, color: colors.stream),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${w.precipitationMm.toStringAsFixed(1)} mm',
                        style: GoogleFonts.sora(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: colors.foam)),
                    Text('$precipLabel · $precipSubtitle',
                        style: GoogleFonts.inter(fontSize: 11.5, color: colors.mist)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(updatedLabel,
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 9.5, color: colors.mist.withValues(alpha: 0.7))),
        ],
      ),
    );
  }

  Widget _buildHourlySection(SteesColors colors, WeatherToday w) {
    final base = DateTime.now().add(Duration(days: _hourlyDay));
    String pad(int n) => n.toString().padLeft(2, '0');
    final prefix = '${base.year}-${pad(base.month)}-${pad(base.day)}';
    var hours = w.hoursForDate(prefix);
    if (_hourlyDay == 0 && hours.isEmpty) {
      hours = w.hourly.take(12).toList();
    } else {
      hours = hours.take(24).toList();
    }
    if (hours.isEmpty) {
      return SteesCard(
        active: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHourlyHeader(colors),
            const SizedBox(height: AppSpacing.sm),
            Text('No hourly data for this day.',
                style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
          ],
        ),
      );
    }
    return SteesCard(
      active: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHourlyHeader(colors),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 98,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: hours.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (_, i) => _HourCell(hour: hours[i]),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Significant rain: ≥2 mm with ≥50% chance',
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 9.5,
                  color: colors.mist.withValues(alpha: 0.7))),
        ],
      ),
    );
  }

  Widget _buildHourlyHeader(SteesColors colors) {
    return Row(
      children: [
        Text('FORECAST',
            style: GoogleFonts.jetBrainsMono(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
                color: colors.stream)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  _DayPill(
                    label: _pillLabel(i),
                    selected: _hourlyDay == i,
                    onTap: () => setState(() => _hourlyDay = i),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String _dayLabel(String rainDate) {
    final now = DateTime.now();
    String fmt(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final today = fmt(now);
    final tomorrow = fmt(now.add(const Duration(days: 1)));
    if (rainDate == today) return 'Today';
    if (rainDate == tomorrow) return 'Tomorrow';
    try {
      final parts = rainDate.split('-');
      if (parts.length == 3) {
        final m = int.parse(parts[1]);
        final d = int.parse(parts[2]);
        if (m >= 1 && m <= 12) return '${_months[m - 1]} $d';
      }
    } catch (_) {}
    return rainDate;
  }

  /// Day-pill labels: Today / Tomorrow / real date (never "Day +2").
  String _pillLabel(int index) {
    if (index == 0) return 'Today';
    if (index == 1) return 'Tomorrow';
    final d = DateTime.now().add(const Duration(days: 2));
    return '${_months[d.month - 1]} ${d.day}';
  }

  /// Per-conflict detail cards. Grouping/dedup logic is unchanged; only the
  /// presentation is irrigation-first: irrigation window, rain window (amount
  /// always paired with its time range), and the overlap duration the API
  /// already provides. Advisory-only wording throughout.
  List<Widget> _buildAdvisoryCards(SteesColors colors, WeatherToday w) {
    // Always render ALL deduped advisories for all 3 days — never filter by _hourlyDay.
    final seen = <String, WeatherAdvisory>{};
    for (final a in w.advisories) {
      final key = '${a.scheduleId}|${a.rainDate}|${a.rainStart}|${a.rainEnd}|${a.type}';
      seen[key] ??= a;
    }
    // Group by schedule+date: keep HIGH overlap as primary, keep MEDIUM near as subtle secondary hint
    final byScheduleDate = <String, List<WeatherAdvisory>>{};
    for (final a in seen.values) {
      final k = '${a.scheduleId}|${a.rainDate}';
      (byScheduleDate[k] ??= []).add(a);
    }
    final groups = byScheduleDate.values.toList();
    if (groups.isEmpty) return [];
    return [
      for (final group in groups) ...[
        Builder(builder: (_) {
          final overlaps = group.where((a) => a.isOverlap).toList();
          final nears = group.where((a) => !a.isOverlap).toList();
          final primary = overlaps.isNotEmpty ? overlaps.first : group.first;
          final accent =
              primary.isOverlap ? colors.danger : colors.sunlight;
          final channels = primary.channels.isEmpty
              ? ''
              : ' · CH${primary.channels.join(' · CH')}';
          // Auto-named schedules repeat the window as their name — show the
          // name only when it genuinely differs from the irrigation window.
          final window =
              '${primary.scheduleStart}–${primary.scheduleEnd}';
          final showName = primary.scheduleName.isNotEmpty &&
              primary.scheduleName != window;
          return SteesCard(
            active: false,
            borderColor: accent.withValues(alpha: 0.45),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                        primary.isOverlap
                            ? Icons.warning_amber_rounded
                            : Icons.cloud_outlined,
                        size: 18,
                        color: accent),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        primary.isOverlap
                            ? 'Rain during irrigation'
                            : 'Rain near irrigation',
                        style: GoogleFonts.sora(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: colors.foam),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: colors.stream.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: colors.stream.withValues(alpha: 0.25)),
                      ),
                      child: Text(
                        _dayLabel(primary.rainDate),
                        style: GoogleFonts.jetBrainsMono(
                            fontSize: 10, fontWeight: FontWeight.w700, color: colors.stream),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Irrigation',
                    style: GoogleFonts.jetBrainsMono(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: colors.mist)),
                const SizedBox(height: 2),
                Text('$window$channels',
                    style: GoogleFonts.sora(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: colors.foam)),
                if (showName) ...[
                  const SizedBox(height: 2),
                  Text(primary.scheduleName,
                      style: GoogleFonts.inter(
                          fontSize: 12, height: 1.4, color: colors.mist)),
                ],
                const SizedBox(height: AppSpacing.sm),
                Text('Rain',
                    style: GoogleFonts.jetBrainsMono(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: colors.mist)),
                const SizedBox(height: 2),
                Text(
                  '${primary.rainStart}–${primary.rainEnd} · ${primary.precipitationMm.toStringAsFixed(1)} mm · ${primary.probability}%',
                  style: GoogleFonts.sora(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.foam),
                ),
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: accent.withValues(alpha: 0.28)),
                  ),
                  child: Text(
                    primary.isOverlap
                        ? (primary.overlapMinutes > 0
                            ? 'Direct overlap · ${_overlapLabel(primary.overlapMinutes)}'
                            : 'Direct overlap')
                        : 'Close to irrigation window',
                    style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: accent),
                  ),
                ),
                if (nears.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Also near: ${nears.map((n) => '${n.rainStart}–${n.rainEnd}').join(', ')}',
                    style: GoogleFonts.inter(
                        fontSize: 11, color: colors.mist.withValues(alpha: 0.7)),
                  ),
                ],
                if (overlaps.length > 1) ...[
                  const SizedBox(height: 6),
                  Text(
                    '+${overlaps.length - 1} more overlap${overlaps.length - 1 == 1 ? '' : 's'} same day',
                    style: GoogleFonts.inter(
                        fontSize: 11, color: colors.mist.withValues(alpha: 0.7)),
                  ),
                ],
                if (widget.onNavigateToTab != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => widget.onNavigateToTab!(2),
                      icon: Icon(Icons.schedule_outlined,
                          size: 15, color: colors.stream),
                      label: Text('Review Schedule',
                          style: GoogleFonts.inter(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: colors.stream)),
                    ),
                  ),
                ],
              ],
            ),
          );
        }),
        const SizedBox(height: AppSpacing.sm),
      ],
    ];
  }

  /// Display form for the overlap duration the API already provides.
  String _overlapLabel(int minutes) {
    if (minutes < 60) return '~$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '~$h h' : '~$h h $m min';
  }

  Widget _buildScheduleSection(SteesColors colors, WeatherToday w) {
    if (w.schedules.isEmpty) {
      return SteesCard(
        active: false,
        child: Text('No irrigation schedules for this device.',
            style: GoogleFonts.inter(fontSize: 12.5, color: colors.mist)),
      );
    }
    return SteesCard(
      active: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TODAY\u2019S IRRIGATION',
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: colors.stream)),
          const SizedBox(height: AppSpacing.sm),
          for (final s in w.schedules) ...[
            Row(
              children: [
                Expanded(
                  child: Text(s.window,
                      style: GoogleFonts.jetBrainsMono(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colors.foam)),
                ),
                Text(
                  s.channels.isEmpty
                      ? ''
                      : 'CH${s.channels.join(', CH')}',
                  style: GoogleFonts.jetBrainsMono(
                      fontSize: 10.5, color: colors.mist),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

class _HourCell extends StatelessWidget {
  final WeatherHour hour;
  const _HourCell({required this.hour});

  /// Backend significance rule, mirrored for display only (never redefined):
  /// precipitationMm >= 2 AND rainProbability >= 50.
  static bool isSignificant(WeatherHour h) =>
      h.precipitationMm >= 2 && h.precipitationProbability >= 50;

  static bool _isCurrentHour(WeatherHour h) {
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    if (h.date != '${now.year}-${pad(now.month)}-${pad(now.day)}') {
      return false;
    }
    final m = RegExp(r'T(\d{2}):').firstMatch(h.localTime);
    return m != null && int.parse(m.group(1)!) == now.hour;
  }

  static bool _isPastHour(WeatherHour h) {
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    if (h.date != '${now.year}-${pad(now.month)}-${pad(now.day)}') {
      return false;
    }
    final m = RegExp(r'T(\d{2}):').firstMatch(h.localTime);
    return m != null && int.parse(m.group(1)!) < now.hour;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final significant = isSignificant(hour);
    final trace = !significant && hour.precipitationMm > 0;
    final now = _isCurrentHour(hour);
    final past = !now && _isPastHour(hour);
    final isFuture = !now && !past;
    final border = significant || now ? colors.stream : colors.border;
    // Probability is a forecast field: show only for future hours; current
    // and past are dimmed/observation-oriented and omit it entirely.
    final showProbability = isFuture;
    return Opacity(
      opacity: past ? 0.42 : 1,
      child: Container(
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: significant
              ? colors.stream.withValues(alpha: 0.10)
              : colors.well,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: border, width: significant || now ? 1.5 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (now)
              Text('NOW',
                  style: GoogleFonts.jetBrainsMono(
                      fontSize: 7,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: colors.stream))
            else
              Text(hour.hhmm,
                  style: GoogleFonts.jetBrainsMono(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: colors.mist)),
            if (now)
              Text(hour.hhmm,
                  style: GoogleFonts.jetBrainsMono(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: colors.stream)),
            const SizedBox(height: 1),
            Icon(
                significant || trace
                    ? Icons.umbrella_outlined
                    : Icons.wb_sunny_outlined,
                size: 13,
                color: significant
                    ? colors.stream
                    : trace
                        ? colors.mist
                        : colors.sunlight),
            const SizedBox(height: 1),
            // Rain-first: mm is primary; probability is a forecast qualifier
            // shown only for future hours directly beneath it.
            Text('${hour.precipitationMm.toStringAsFixed(1)} mm',
                style: GoogleFonts.sora(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: colors.foam)),
            if (showProbability)
              Text('${hour.precipitationProbability}%',
                  style: GoogleFonts.jetBrainsMono(
                      fontSize: 8, color: colors.mist)),
            Text(
                hour.temperature == null
                    ? '—'
                    : '${hour.temperature!.toStringAsFixed(0)}°',
                style: GoogleFonts.jetBrainsMono(
                    fontSize: 8, color: colors.mist)),
          ],
        ),
      ),
    );
  }
}

class _DayPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DayPill({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? colors.stream : colors.well,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: selected ? colors.stream : colors.border),
        ),
        child: Text(label,
            style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? colors.well : colors.mist)),
      ),
    );
  }
}
