import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import '../services/api_service.dart';
import '../services/reverse_geocode.dart' as geo;
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';

const String kWeatherTimezone = 'Africa/Algiers';
const LatLng kAlgeriaFallback = LatLng(35.2, 4.18);

// Payload saved via PATCH /api/devices/:deviceId/location. Coordinates always
// come from the user-confirmed map point, never from phone GPS or guesses.
class LocationSaveRequest {
  final String deviceId;
  final String? farmName;
  final double lat;
  final double lon;
  final String timezone;

  const LocationSaveRequest({
    required this.deviceId,
    required this.farmName,
    required this.lat,
    required this.lon,
    required this.timezone,
  });
}

LocationSaveRequest buildLocationSave({
  required String deviceId,
  String? placeName,
  String? name,
  required double lat,
  required double lon,
}) {
  // Auto name only: place label drives farmName. `name` kept for legacy tests.
  final fromPlace = placeName?.split(',').first.trim();
  final trimmedPlace = fromPlace != null && fromPlace.isNotEmpty ? fromPlace : null;
  final trimmedName = name?.trim();
  final farm = (trimmedName != null && trimmedName.isNotEmpty) ? trimmedName : trimmedPlace;
  return LocationSaveRequest(
    deviceId: deviceId,
    farmName: farm,
    lat: lat,
    lon: lon,
    timezone: kWeatherTimezone,
  );
}

class WeatherLocationPickerPage extends StatefulWidget {
  final List<Map<String, dynamic>> devices;
  final String? initialDeviceId;
  final ApiService? api;
  final Future<String?> Function(double lat, double lon)? reverseGeocode;
  final Widget Function(LatLng? picked, ValueChanged<LatLng> onPick)? mapBuilder;

  const WeatherLocationPickerPage({
    super.key,
    required this.devices,
    this.initialDeviceId,
    this.api,
    this.reverseGeocode,
    this.mapBuilder,
  });

  @override
  State<WeatherLocationPickerPage> createState() =>
      _WeatherLocationPickerPageState();
}

class _WeatherLocationPickerPageState
    extends State<WeatherLocationPickerPage> {
  late final ApiService _api = widget.api ?? ApiService();
  final MapController _mapController = MapController();
  final GlobalKey _mapKey = GlobalKey();

  String? _selectedDeviceId;
  LatLng? _picked;
  String? _placeName;
  bool _resolving = false;
  bool _saving = false;
  String? _error;
  int _resolveGen = 0;

  @override
  void initState() {
    super.initState();
    _selectedDeviceId = widget.initialDeviceId ??
        (widget.devices.isNotEmpty
            ? widget.devices.first['deviceId'] as String?
            : null);
    final device = _selectedDevice;
    if (device != null) _applyDevice(device);
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Map<String, dynamic>? get _selectedDevice {
    for (final d in widget.devices) {
      if (d['deviceId'] == _selectedDeviceId) return d;
    }
    return null;
  }

  // Device selector shows the device name only — never the farm/location
  // name and never the typed text.
  static String _deviceLabel(Map<String, dynamic> device) {
    return '${device['name'] ?? device['deviceId']}';
  }

  LatLng? _deviceLatLng(Map<String, dynamic> device) {
    final lat = (device['lat'] as num?)?.toDouble();
    final lon = (device['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return LatLng(lat, lon);
  }

  void _applyDevice(Map<String, dynamic> device) {
    final at = _deviceLatLng(device);
    _picked = at;
    _placeName = null;
    if (at != null) unawaited(_resolvePlace(at));
  }

  void _onPick(LatLng point) {
    setState(() {
      _picked = point;
      _placeName = null;
      _error = null;
    });
    unawaited(_resolvePlace(point));
  }

  Future<void> _resolvePlace(LatLng point) async {
    final gen = ++_resolveGen;
    setState(() => _resolving = true);
    try {
      final resolve = widget.reverseGeocode ?? geo.reverseGeocode;
      final name = await resolve(point.latitude, point.longitude);
      if (!mounted || gen != _resolveGen) return;
      setState(() {
        _placeName = name;
      });
    } finally {
      if (mounted && gen == _resolveGen) {
        setState(() => _resolving = false);
      }
    }
  }

  void _moveMarkerToGlobal(Offset globalPosition) {
    final box =
        _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    _onPick(_mapController.camera.screenOffsetToLatLng(local));
  }

  bool get _selectedHasLocation {
    final device = _selectedDevice;
    return device != null && _deviceLatLng(device) != null;
  }

  Future<void> _removeLocation() async {
    final deviceId = _selectedDeviceId;
    if (deviceId == null) return;
    final colors = context.steesColors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl)),
        title: Text('Remove location?',
            style: GoogleFonts.sora(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colors.foam)),
        content: Text(
            'Weather forecasts will be disabled for this device. Your irrigation schedules are unaffected.',
            style:
                GoogleFonts.inter(fontSize: 13, color: colors.mist)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Cancel',
                  style: GoogleFonts.inter(
                      fontSize: 13, color: colors.mist))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Remove',
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: colors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.clearDeviceLocation(deviceId: deviceId);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not remove location.';
        });
      }
    }
  }

  Future<void> _save() async {
    final picked = _picked;
    final deviceId = _selectedDeviceId;
    if (picked == null || deviceId == null) {
      setState(() => _error = 'Tap the map to choose a location first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final req = buildLocationSave(
        deviceId: deviceId,
        placeName: _placeName,
        lat: picked.latitude,
        lon: picked.longitude,
      );
      await _api.updateDeviceLocation(
        deviceId: req.deviceId,
        farmName: req.farmName,
        lat: req.lat,
        lon: req.lon,
        timezone: req.timezone,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save location.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final center = _picked ?? _mapCenterFallback;
    return Scaffold(
      appBar: AppBar(
        title: Text('Select weather location',
            style: GoogleFonts.sora(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colors.foam)),
        backgroundColor: colors.well,
        iconTheme: IconThemeData(color: colors.mist),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  _buildMap(center),
                  if (_selectedHasLocation)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Material(
                        color: colors.surface,
                        shape: const CircleBorder(),
                        elevation: 3,
                        child: IconButton(
                          onPressed: _saving ? null : _removeLocation,
                          icon: Icon(Icons.delete_outline,
                              size: 18, color: colors.danger),
                          tooltip: 'Remove location',
                          style: IconButton.styleFrom(
                            minimumSize: const Size(44, 44),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: Column(
                      children: [
                        _ZoomButton(
                            icon: Icons.add,
                            onTap: () => _mapController.move(
                                _mapController.camera.center,
                                _mapController.camera.zoom + 1)),
                        const SizedBox(height: 8),
                        _ZoomButton(
                            icon: Icons.remove,
                            onTap: () => _mapController.move(
                                _mapController.camera.center,
                                _mapController.camera.zoom - 1)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _buildSheet(colors),
          ],
        ),
      ),
    );
  }

  LatLng get _mapCenterFallback {
    final device = _selectedDevice;
    final at = device == null ? null : _deviceLatLng(device);
    return _picked ?? at ?? kAlgeriaFallback;
  }

  Widget _buildMap(LatLng center) {
    if (widget.mapBuilder != null) {
      return widget.mapBuilder!(_picked, _onPick);
    }
    return FlutterMap(
      key: _mapKey,
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: _picked != null ? 12 : 6,
        onTap: (_, point) => _onPick(point),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.smart_home_app',
        ),
        if (_picked != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _picked!,
                width: 48,
                height: 48,
                child: GestureDetector(
                  onPanStart: (_) {},
                  onPanUpdate: (d) =>
                      _moveMarkerToGlobal(d.globalPosition),
                  onPanEnd: (_) {},
                  child: const Icon(Icons.location_on,
                      size: 44, color: Colors.redAccent),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildSheet(SteesColors colors) {
    final picked = _picked;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.submerged,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.location_on_outlined,
                    size: 16, color: colors.stream),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _placeName ??
                        (picked == null
                            ? 'Tap the map to choose the farm location'
                            : _resolving
                                ? 'Resolving place…'
                                : 'Custom map point'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.foam),
                  ),
                ),
              ],
            ),
            if (picked != null) ...[
              const SizedBox(height: 2),
              Text(
                '${picked.latitude.toStringAsFixed(4)}, ${picked.longitude.toStringAsFixed(4)}',
                style: GoogleFonts.jetBrainsMono(
                    fontSize: 10.5, color: colors.mist),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: _selectedDeviceId,
              dropdownColor: colors.submerged,
              decoration:
                  const InputDecoration(labelText: 'Use for device'),
              items: [
                for (final d in widget.devices)
                  DropdownMenuItem<String>(
                    value: '${d['deviceId']}',
                    child: Text(_deviceLabel(d),
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                Map<String, dynamic>? device;
                for (final d in widget.devices) {
                  if ('${d['deviceId']}' == v) {
                    device = d;
                    break;
                  }
                }
                final selected = device;
                if (selected == null) return;
                setState(() {
                  _selectedDeviceId = v;
                  _applyDevice(selected);
                  _error = null;
                });
                final at = _deviceLatLng(selected);
                if (at != null && widget.mapBuilder == null) {
                  _mapController.move(at, 12);
                }
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!,
                  style: GoogleFonts.inter(
                      fontSize: 12, color: colors.danger)),
            ],
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed:
                    (_saving || picked == null || _selectedDeviceId == null)
                        ? null
                        : _save,
                icon: _saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: colors.well))
                    : const Icon(Icons.check, size: 18),
                label: Text(_saving ? 'Saving…' : 'Confirm Location',
                    style: GoogleFonts.sora(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.stream,
                  foregroundColor: colors.well,
                  shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppRadius.md)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ZoomButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Material(
      color: colors.submerged,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 20, color: colors.foam),
        ),
      ),
    );
  }
}
