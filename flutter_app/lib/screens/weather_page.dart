import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:location/location.dart' as loc;
import '../models/weather.dart';
import '../l10n/gen/app_localizations.dart';
import '../l10n/l10n_helpers.dart';
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
  // Raw failure cause, resolved to a localized message in build() via
  // friendlyError(). Never resolved here: loaders also run from initState,
  // where Localizations cannot be read.
  Object? _errorCause;
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
      _errorCause = null;
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
        _errorCause = e;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDevices = false;
        _loadError = _devices.isEmpty;
        _errorCause = e;
      });
    }
  }

  Future<void> _loadWeather() async {
    final deviceId = _selectedDeviceId;
    if (deviceId == null) return;
    setState(() {
      _loadingWeather = true;
      _errorCause = null;
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
        _errorCause = e;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingWeather = false;
        _errorCause = e;
      });
    }
  }

  Future<void> _openLocationPicker() async {
    // Native Android prompt when Location is disabled — requested on the
    // existing Set Location action, not on picker init. Uses the maintained
    // `location` plugin which on Android delegates to Google Play Services
    // SettingsClient / LocationSettingsRequest / ResolvableApiException and
    // shows the native system resolution dialog ("Turn on location?") without
    // leaving the app. If the dialog is unavailable, falls back to allowing
    // the picker to open with its safe fallback behavior.
    if (!kIsWeb) {
      try {
        final loc.Location locService = loc.Location();
        bool serviceEnabled = await locService.serviceEnabled();
        if (!serviceEnabled) {
          // This shows the native Android system dialog when supported
          // (in-app window, not an external settings page).
          final requested = await locService.requestService();
          // Re-check after user interaction; if still disabled, continue
          // to picker with fallback — do not save or change location.
          if (!requested) {
            serviceEnabled = await locService.serviceEnabled();
          } else {
            serviceEnabled = true;
          }
          // If native dialog unavailable, `requestService` returns false
          // but does not throw — picker will open with fallback and remain
          // usable. No external settings page is opened as normal flow.
        }
      } catch (_) {
        // Plugin unavailable / no Play Services — graceful fallback: open
        // picker with safe fallback center.
      }
    }
    if (!mounted) return;
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
    final l10n = AppLocalizations.of(context)!;
    if (_loadingDevices) return const SteesLoading();
    if (_loadError && _devices.isEmpty) {
      return SteesError(
        title: l10n.devLoadFailed,
        subtitle: _errorCause == null
            ? l10n.sharedCheckConnection
            : friendlyError(_errorCause!, l10n),
        onRetry: _loadDevices,
      );
    }
    if (_devices.isEmpty) {
      return SteesEmpty(
        icon: Icons.cloud_outlined,
        title: l10n.sharedNoDevices,
        subtitle: l10n.wNoDevicesHint,
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
          else if (_errorCause != null && _weather == null)
            SteesError(
              title: l10n.wLoadTitle,
              subtitle: friendlyError(_errorCause!, l10n),
              onRetry: _loadWeather,
            )
          else if (_weather != null)
            ..._buildWeatherBody(colors),
        ],
      ),
    );
  }

  Widget _buildPageTitle(SteesColors colors) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xs, AppSpacing.sm, AppSpacing.xs, AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.wSection,
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
            tooltip: l10n.wRefresh,
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
        SteesCard(
          active: false,
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.stream.withValues(alpha: 0.12),
                  border: Border.all(
                      color: colors.stream.withValues(alpha: 0.22), width: 1.2),
                ),
                child: Icon(Icons.location_off_outlined,
                    size: 30, color: colors.stream),
              ),
              const SizedBox(height: 16),
              Text(AppLocalizations.of(context)!.wNoLocation,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.sora(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      color: colors.foam)),
              const SizedBox(height: 8),
              Text(
                  AppLocalizations.of(context)!.wNoLocationHint,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 13, height: 1.5, color: colors.mist)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  color: colors.well.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: colors.border.withValues(alpha: 0.6)),
                ),
                child: Row(
                  children: [
                    _WeatherEmptyFeature(
                        icon: Icons.cloud_outlined,
                        label: AppLocalizations.of(context)!.wFeatForecast,
                        colors: colors),
                    Container(
                        width: 1,
                        height: 32,
                        color: colors.border.withValues(alpha: 0.7)),
                    _WeatherEmptyFeature(
                        icon: Icons.umbrella_outlined,
                        label: AppLocalizations.of(context)!.wFeatAdvisories,
                        colors: colors),
                    Container(
                        width: 1,
                        height: 32,
                        color: colors.border.withValues(alpha: 0.7)),
                    _WeatherEmptyFeature(
                        icon: Icons.schedule_outlined,
                        label: AppLocalizations.of(context)!.wFeatUnaffected,
                        colors: colors),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _openLocationPicker,
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(AppLocalizations.of(context)!.wSetLocation,
                      style: GoogleFonts.sora(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.stream,
                    foregroundColor: colors.well,
                    elevation: 2,
                    shadowColor: colors.stream.withValues(alpha: 0.3),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(AppLocalizations.of(context)!.wPinDefaults(kWeatherTimezone),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.jetBrainsMono(
                      fontSize: 9.5,
                      color: colors.mist.withValues(alpha: 0.65))),
            ],
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
    final l10n = AppLocalizations.of(context)!;
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
                    Text(l10n.wForecastUnavailable,
                        style: GoogleFonts.sora(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: colors.foam)),
                    const SizedBox(height: 2),
                    Text(
                        l10n.wForecastHint,
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
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: _loadingWeather ? null : _loadWeather,
              icon: Icon(Icons.refresh, size: 15, color: colors.stream),
              label: Text(l10n.sharedRetry,
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
    // Coordinates at 1m precision (5 decimals) so the badge matches the
    // picker's 5-decimal display and the saved PATCH payload.
    final coords = w.lat != null && w.lon != null
        ? '${w.lat!.toStringAsFixed(5)}, ${w.lon!.toStringAsFixed(5)}'
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
                Text(AppLocalizations.of(context)!.sharedEdit,
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
    final l10n = AppLocalizations.of(context)!;
    final updated = _retrievedAt ?? (w.fetchedAt != null ? DateTime.tryParse(w.fetchedAt!) : null);
    String updatedLabel = w.timezone;
    if (updated != null) {
      String pad(int n) => n.toString().padLeft(2, '0');
      updatedLabel = l10n.wUpdated('${pad(updated.hour)}:${pad(updated.minute)}', w.timezone);
    }
    final precipLabel = l10n.wPrecipitation;
    final precipSubtitle = l10n.wLastHour;
    return SteesCard(
      active: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.wCurrent,
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
              Text(l10n.wTemperature,
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
                    Text('${w.precipitationMm.toStringAsFixed(1)} ${l10n.unitMm}',
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
            Text(AppLocalizations.of(context)!.wNoHourly,
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
          Text(AppLocalizations.of(context)!.wSignificantRain,
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
        Text(AppLocalizations.of(context)!.wForecast,
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

  String _dayLabel(String rainDate) {
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();
    String fmt(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final today = fmt(now);
    final tomorrow = fmt(now.add(const Duration(days: 1)));
    if (rainDate == today) return l10n.sharedToday;
    if (rainDate == tomorrow) return l10n.sharedTomorrow;
    try {
      final parts = rainDate.split('-');
      if (parts.length == 3) {
        final m = int.parse(parts[1]);
        final d = int.parse(parts[2]);
        if (m >= 1 && m <= 12) {
          return '${monthLabel(m, l10n.localeName)} $d';
        }
      }
    } catch (_) {}
    return rainDate;
  }

  /// Day-pill labels: Today / Tomorrow / real date (never "Day +2").
  String _pillLabel(int index) {
    final l10n = AppLocalizations.of(context)!;
    if (index == 0) return l10n.sharedToday;
    if (index == 1) return l10n.sharedTomorrow;
    final d = DateTime.now().add(const Duration(days: 2));
    return '${monthLabel(d.month, l10n.localeName)} ${d.day}';
  }

  /// Per-conflict detail cards. Grouping/dedup logic is unchanged; only the
  /// presentation is irrigation-first: irrigation window, rain window (amount
  /// always paired with its time range), and the overlap duration the API
  /// already provides. Advisory-only wording throughout.
  List<Widget> _buildAdvisoryCards(SteesColors colors, WeatherToday w) {
    final l10n = AppLocalizations.of(context)!;
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
                            ? l10n.wRainDuring
                            : l10n.wRainNear,
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
                Text(l10n.wIrrigation,
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
                Text(l10n.wRain,
                    style: GoogleFonts.jetBrainsMono(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: colors.mist)),
                const SizedBox(height: 2),
                Text(
                  '${primary.rainStart}–${primary.rainEnd} · ${primary.precipitationMm.toStringAsFixed(1)} ${l10n.unitMm} · ${primary.probability}%',
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
                            ? l10n.wDirectOverlapWith(
                                _overlapLabel(primary.overlapMinutes))
                            : l10n.wDirectOverlap)
                        : l10n.wCloseToWindow,
                    style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: accent),
                  ),
                ),
                if (nears.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.wAlsoNear(nears.map((n) => '${n.rainStart}–${n.rainEnd}').join(', ')),
                    style: GoogleFonts.inter(
                        fontSize: 11, color: colors.mist.withValues(alpha: 0.7)),
                  ),
                ],
                if (overlaps.length > 1) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.wMoreOverlaps(overlaps.length - 1),
                    style: GoogleFonts.inter(
                        fontSize: 11, color: colors.mist.withValues(alpha: 0.7)),
                  ),
                ],
                if (widget.onNavigateToTab != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: () => widget.onNavigateToTab!(2),
                      icon: Icon(Icons.schedule_outlined,
                          size: 15, color: colors.stream),
                      label: Text(l10n.wReviewSchedule,
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
    final l10n = AppLocalizations.of(context)!;
    if (minutes < 60) return l10n.wDurationMin(minutes);
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? l10n.wDurationHour(h) : l10n.wDurationHourMin(h, m);
  }

  Widget _buildScheduleSection(SteesColors colors, WeatherToday w) {
    final l10n = AppLocalizations.of(context)!;
    if (w.schedules.isEmpty) {
      return SteesCard(
        active: false,
        child: Text(l10n.wNoSchedules,
            style: GoogleFonts.inter(fontSize: 12.5, color: colors.mist)),
      );
    }
    return SteesCard(
      active: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.wTodayIrrigation,
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

class _WeatherEmptyFeature extends StatelessWidget {
  final IconData icon;
  final String label;
  final SteesColors colors;
  const _WeatherEmptyFeature(
      {required this.icon, required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colors.stream),
          const SizedBox(height: 4),
          Text(label,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: colors.foam)),
        ],
      ),
    );
  }
}

class _HourCell extends StatelessWidget {
  final WeatherHour hour;
  const _HourCell({required this.hour});

  /// Localized "now" marker for the current-hour cell.
  static String _nowLabel(BuildContext context) =>
      AppLocalizations.of(context)!.hourNow;

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
              Text(_nowLabel(context),
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
            Text('${hour.precipitationMm.toStringAsFixed(1)} ${AppLocalizations.of(context)!.unitMm}',
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
