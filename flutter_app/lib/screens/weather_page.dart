import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/weather.dart';
import '../services/api_service.dart';
import 'weather_location_picker_page.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../widgets/stees_widgets.dart';

class WeatherPage extends StatefulWidget {
  final void Function(int index)? onNavigateToTab;
  final ApiService? api;

  const WeatherPage({super.key, this.onNavigateToTab, this.api});

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
      setState(() {
        _devices = devices.cast<Map<String, dynamic>>();
        _loadingDevices = false;
        if (_devices.isNotEmpty) {
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.border),
      ),
      child: DropdownButtonHideUnderline(
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
                      child: Text(
                        '${d['name'] ?? d['deviceId']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.foam),
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
    );
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
        SteesError(
          title: 'Weather temporarily unavailable',
          subtitle:
              'STEES could not retrieve the weather forecast. Your irrigation schedules are unaffected.',
          onRetry: _loadWeather,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildScheduleSection(colors, w),
      ];
    }
    return [
      _buildLocationLine(colors, w),
      const SizedBox(height: AppSpacing.md),
      _buildCurrentSection(colors, w),
      const SizedBox(height: AppSpacing.md),
      _buildHourlySection(colors, w),
      const SizedBox(height: AppSpacing.md),
      _buildAdvisorySection(colors, w),
      const SizedBox(height: AppSpacing.md),
      _buildScheduleSection(colors, w),
      if (_retrievedAt != null || w.fetchedAt != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          _retrievedLabel(w),
          style: GoogleFonts.jetBrainsMono(
            fontSize: 10,
            color: colors.mist.withValues(alpha: 0.6),
          ),
        ),
      ],
    ];
  }

  String _retrievedLabel(WeatherToday w) {
    if (_retrievedAt == null) return 'Forecast · ${w.timezone}';
    final mins = DateTime.now().difference(_retrievedAt!).inMinutes;
    if (mins < 1) return 'Retrieved just now · ${w.timezone}';
    if (mins == 1) return 'Retrieved 1 minute ago · ${w.timezone}';
    return 'Retrieved $mins minutes ago · ${w.timezone}';
  }

  Widget _buildLocationLine(SteesColors colors, WeatherToday w) {
    final loc = w.farmName ?? 'Device ${w.deviceId}';
    final coords = w.lat != null && w.lon != null
        ? '${w.lat!.toStringAsFixed(2)}, ${w.lon!.toStringAsFixed(2)}'
        : w.timezone;
    return Row(
      children: [
        Icon(Icons.location_on_outlined, size: 14, color: colors.mist),
        const SizedBox(width: 6),
        Expanded(
          child: Text('$loc · $coords',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
        ),
        InkWell(
          onTap: _openLocationPicker,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.all(4),
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

  Widget _buildCurrentSection(SteesColors colors, WeatherToday w) {
    return SteesCard(
      active: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CURRENT',
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: colors.stream)),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              _Stat(
                  icon: Icons.thermostat_outlined,
                  label: 'Temp',
                  value: w.temperature == null
                      ? '—'
                      : '${w.temperature!.toStringAsFixed(0)}°C'),
              const SizedBox(width: AppSpacing.lg),
              _Stat(
                  icon: Icons.water_drop_outlined,
                  label: 'Rain',
                  value: '${w.precipitationMm.toStringAsFixed(1)} mm'),
              const SizedBox(width: AppSpacing.lg),
              _Stat(
                  icon: Icons.umbrella_outlined,
                  label: 'Chance',
                  value: '${w.rainProbability}%'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHourlySection(SteesColors colors, WeatherToday w) {
    final today = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    final prefix =
        '${today.year}-${pad(today.month)}-${pad(today.day)}';
    var hours = w.hoursForDate(prefix);
    hours = hours.isEmpty ? w.hourly.take(12).toList() : hours.take(24).toList();
    if (hours.isEmpty) return const SizedBox.shrink();
    return SteesCard(
      active: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('HOURLY',
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: colors.stream)),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: hours.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (_, i) => _HourCell(hour: hours[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvisorySection(SteesColors colors, WeatherToday w) {
    if (w.advisories.isEmpty) {
      return SteesCard(
        active: false,
        child: Row(
          children: [
            Icon(Icons.check_circle_outline,
                size: 18, color: colors.leaf),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text('No significant rain overlap.\nYour irrigation schedules have no significant forecast rain overlap today.',
                  style: GoogleFonts.inter(
                      fontSize: 12.5, height: 1.45, color: colors.mist)),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (final a in w.advisories) ...[
          SteesCard(
            active: a.isOverlap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                        a.isOverlap
                            ? Icons.warning_amber_rounded
                            : Icons.cloud_outlined,
                        size: 18,
                        color: a.isOverlap
                            ? colors.sunlight
                            : colors.stream),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        a.isOverlap
                            ? 'Rain overlaps irrigation'
                            : 'Rain near irrigation',
                        style: GoogleFonts.sora(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: colors.foam),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Schedule ${a.scheduleStart}–${a.scheduleEnd}'
                  '${a.scheduleName.isNotEmpty ? ' · ${a.scheduleName}' : ''}'
                  '${a.channels.isNotEmpty ? ' · CH${a.channels.join(', CH')}' : ''}\n'
                  'Rain ${a.rainStart}–${a.rainEnd} · ${a.precipitationMm.toStringAsFixed(1)} mm · ${a.probability}%\n'
                  'Consider reviewing today\'s irrigation schedule.',
                  style: GoogleFonts.inter(
                      fontSize: 12.5, height: 1.5, color: colors.mist),
                ),
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
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
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

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _Stat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: colors.mist),
              const SizedBox(width: 4),
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 10.5, color: colors.mist)),
            ],
          ),
          const SizedBox(height: 4),
          Text(value,
              style: GoogleFonts.sora(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: colors.foam)),
        ],
      ),
    );
  }
}

class _HourCell extends StatelessWidget {
  final WeatherHour hour;
  const _HourCell({required this.hour});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final rainy = hour.precipitationMm >= 0.5;
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: rainy
            ? colors.stream.withValues(alpha: 0.10)
            : colors.well,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(hour.hhmm,
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colors.mist)),
          const SizedBox(height: 2),
          Icon(rainy ? Icons.umbrella_outlined : Icons.wb_sunny_outlined,
              size: 15,
              color: rainy ? colors.stream : colors.sunlight),
          const SizedBox(height: 2),
          Text(
              hour.temperature == null
                  ? '—'
                  : '${hour.temperature!.toStringAsFixed(0)}°',
              style: GoogleFonts.sora(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colors.foam)),
          Text(
              '${hour.precipitationMm.toStringAsFixed(1)}mm · ${hour.precipitationProbability}%',
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 8.5, color: colors.mist)),
        ],
      ),
    );
  }
}
