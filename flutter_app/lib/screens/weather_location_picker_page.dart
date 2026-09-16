import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import '../services/api_service.dart';
import '../services/reverse_geocode.dart' as geo;
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';

const String kWeatherTimezone = 'Africa/Algiers';
const LatLng kAlgeriaFallback = LatLng(35.2, 4.18);

/// OpenFreeMap vector style (no API key, no card, no billing).
/// Liberty is the most actively maintained of the OFM styles and keeps
/// good visual parity between road/label languages, borders and POIs.
/// Bright is a close alternative; Positron is too low-contrast for the
/// STEES pin on light tiles. The public instance is stated as "no limits
/// on the number of map views or requests, no registration, no API keys,
/// no cookies" at https://openfreemap.org (commercial usage allowed,
/// attribution auto-shown by MapLibre from the style JSON).
const String _kOpenFreeMapStyle = 'https://tiles.openfreemap.org/styles/liberty';

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
  // MapLibre controller. Null until onMapCreated and in widget tests (where
  // mapBuilder stubs the map) it stays null so camera calls are safe no-ops.
  ml.MapLibreMapController? _mapController;
  ml.Symbol? _markerSymbol;
  Uint8List? _markerBytes;
  Color? _markerBytesColor;
  bool _markerBytesGenerating = false;
  bool _markerImageAdded = false;
  bool _styleLoaded = false;

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
    if (_mapController != null) {
      try {
        _mapController!.onFeatureDrag.remove(_onFeatureDrag);
      } catch (_) {}
      _mapController = null;
    }
    _markerSymbol = null;
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
    // Defer marker sync until after the frame so _picked is committed.
    // If the map is already loaded, sync immediately as well.
    if (_styleLoaded) unawaited(_syncMarker());
  }

  void _onPick(LatLng point) {
    setState(() {
      _picked = point;
      _placeName = null;
      _error = null;
    });
    unawaited(_resolvePlace(point));
    unawaited(_syncMarker());
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
      backgroundColor: colors.well,
      appBar: AppBar(
        title: Text('Select weather location',
            style: GoogleFonts.sora(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colors.foam)),
        backgroundColor: colors.well,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: colors.mist),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: colors.border.withValues(alpha: 0.6)),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _buildMap(center, colors),
                // Subtle top gradient so controls stay legible over bright tiles
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.center,
                          colors: [
                            Colors.black.withValues(alpha: 0.06),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (_selectedHasLocation)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Material(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(24),
                      elevation: 4,
                      shadowColor: Colors.black.withValues(alpha: 0.18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: _saving ? null : _removeLocation,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.delete_outline,
                                  size: 16, color: colors.danger),
                              const SizedBox(width: 6),
                              Text('Remove',
                                  style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: colors.danger)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 12,
                  bottom: 14,
                  child: _MapZoomCluster(
                    onZoomIn: () => _zoomBy(1),
                    onZoomOut: () => _zoomBy(-1),
                  ),
                ),
                // Hint pill when nothing picked yet
                if (_picked == null)
                  Positioned(
                    left: 12,
                    bottom: 14,
                    child: Material(
                      color: colors.submerged.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                      elevation: 3,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.touch_app_outlined,
                                size: 14, color: colors.stream),
                            const SizedBox(width: 6),
                            Text('Tap map or drag pin',
                                style: GoogleFonts.inter(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: colors.foam)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _buildSheet(colors),
        ],
      ),
    );
  }

  LatLng get _mapCenterFallback {
    final device = _selectedDevice;
    final at = device == null ? null : _deviceLatLng(device);
    return _picked ?? at ?? kAlgeriaFallback;
  }

  Widget _buildMap(LatLng center, SteesColors colors) {
    if (widget.mapBuilder != null) {
      return widget.mapBuilder!(_picked, _onPick);
    }
    _ensureMarkerBytes(colors);
    return ml.MapLibreMap(
      styleString: _kOpenFreeMapStyle,
      initialCameraPosition: ml.CameraPosition(
        target: ml.LatLng(center.latitude, center.longitude),
        zoom: _picked != null ? 12 : 6,
      ),
      onMapCreated: _onMapCreated,
      onStyleLoadedCallback: _onStyleLoaded,
      onMapClick: (point, latLng) =>
          _onPick(LatLng(latLng.latitude, latLng.longitude)),
      // Attribution is baked into the OpenFreeMap style JSON and rendered
      // automatically by MapLibre; no extra widget needed.
      compassEnabled: false,
      myLocationEnabled: false,
    );
  }

  void _onMapCreated(ml.MapLibreMapController controller) {
    _mapController = controller;
    _mapController!.onFeatureDrag.add(_onFeatureDrag);
    // If style already loaded before this callback ordering edge, sync now.
    if (_styleLoaded) unawaited(_syncMarker());
  }

  void _onStyleLoaded() {
    _styleLoaded = true;
    _markerImageAdded = false;
    // Image must be registered after the style is loaded; then the marker
    // can be added. This runs once per style load (also after recreation).
    unawaited(_addMarkerImageAndSync());
  }

  void _onFeatureDrag(
    math.Point<double> point,
    ml.LatLng origin,
    ml.LatLng current,
    ml.LatLng delta,
    String id,
    ml.Annotation? annotation,
    ml.DragEventType eventType,
  ) {
    // MapLibre fires drag continuously; only the drop should drive
    // reverseGeocode() to avoid a storm. The annotation is already at
    // `current` on the map; we just commit it to STEES state on end.
    if (eventType != ml.DragEventType.end) return;
    // id is the annotation id string; verify it belongs to our pick marker.
    final markerId = _markerSymbol?.id;
    if (markerId != null && id.toString() != markerId) return;
    _onPick(LatLng(current.latitude, current.longitude));
  }

  Future<void> _zoomBy(double delta) async {
    final c = _mapController;
    if (c == null) return;
    try {
      if (delta > 0) {
        await c.animateCamera(ml.CameraUpdate.zoomIn());
      } else {
        await c.animateCamera(ml.CameraUpdate.zoomOut());
      }
    } catch (_) {}
  }

  // --- STEES marker (MapLibre) --------------------------------------------

  /// Ensures the STEES marker PNG bytes exist for this [colors.stream] value.
  /// Cached per color; rebuilds/camera moves reuse it.
  void _ensureMarkerBytes(SteesColors colors) {
    if (_markerBytes != null && _markerBytesColor == colors.stream) return;
    if (_markerBytesGenerating) return;
    _markerBytesGenerating = true;
    unawaited(_buildSteesMarkerBytes(colors.stream).then((bytes) async {
      if (!mounted) return;
      _markerBytes = bytes;
      _markerBytesColor = colors.stream;
      _markerBytesGenerating = false;
      // If the style is already loaded, register the image now; otherwise
      // _onStyleLoaded will pick it up.
      if (_styleLoaded && _mapController != null) {
        await _addMarkerImageAndSync();
        if (mounted) setState(() {});
      } else {
        if (mounted) setState(() {});
      }
    }).catchError((_) {
      _markerBytesGenerating = false;
    }));
  }

  Future<void> _addMarkerImageAndSync() async {
    final ctrl = _mapController;
    final bytes = _markerBytes;
    if (ctrl == null || bytes == null || !_styleLoaded) return;
    if (_markerImageAdded) {
      await _syncMarker();
      return;
    }
    try {
      await ctrl.addImage('stees-marker', bytes);
      _markerImageAdded = true;
    } catch (_) {
      // Image may already exist after a style reload or a race; treat as
      // added and continue to symbol sync.
      _markerImageAdded = true;
    }
    await _syncMarker();
  }

  Future<void> _syncMarker() async {
    final ctrl = _mapController;
    if (ctrl == null || !_styleLoaded) return;
    final picked = _picked;
    if (picked == null) {
      if (_markerSymbol != null) {
        try {
          await ctrl.removeSymbol(_markerSymbol!);
        } catch (_) {}
        _markerSymbol = null;
      }
      return;
    }
    if (!_markerImageAdded || _markerBytes == null) {
      // Defer until the image is registered (handled by _addMarkerImageAndSync).
      return;
    }
    final mlTarget = ml.LatLng(picked.latitude, picked.longitude);
    if (_markerSymbol == null) {
      try {
        _markerSymbol = await ctrl.addSymbol(
          ml.SymbolOptions(
            geometry: mlTarget,
            iconImage: 'stees-marker',
            // 220px base at 0.50 ≈ 110px on screen — ~1.9× the previous
            // 168px@0.34 (≈57px). Clearly bigger without covering farms.
            iconSize: 0.50,
            iconAnchor: 'center',
            draggable: true,
          ),
        );
      } catch (_) {}
    } else {
      try {
        await ctrl.updateSymbol(
          _markerSymbol!,
          ml.SymbolOptions(geometry: mlTarget),
        );
      } catch (_) {
        // Style recreation can invalidate the old symbol id; recreate.
        _markerSymbol = null;
        await _syncMarker();
      }
    }
  }

  /// STEES pin: bigger teal disc + white border + white map-pin glyph with
  /// soft shadow. Drawn with canvas (no font dependency) so it stays crisp
  /// at any density and survives glyph-server outages. Returns PNG bytes for
  /// MapLibre's addImage. Base size 220px keeps the disc ~2× previous.
  static Future<Uint8List> _buildSteesMarkerBytes(Color stream) async {
    const size = 220.0;
    const center = Offset(size / 2, size / 2);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Soft ground shadow — helps the pin pop on both liberty light and
    // satellite-like tiles without an extra widget layer.
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(size / 2, size / 2 + 52), width: 78, height: 18),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    // White outer border for contrast on any background
    canvas.drawCircle(center, 70, Paint()..color = const Color(0xFFFFFFFF));
    // Main teal disc
    canvas.drawCircle(center, 62, Paint()..color = stream);
    // Subtle highlight — makes the disc feel less flat
    canvas.drawCircle(
      Offset(size / 2 - 16, size / 2 - 18),
      12,
      Paint()..color = const Color(0x1FFFFFFF),
    );
    final pinPaint = Paint()..color = const Color(0xFFFFFFFF);
    // Bigger pin glyph — balanced for the larger disc
    canvas.drawCircle(const Offset(size / 2, 94), 22, pinPaint);
    canvas.drawPath(
      ui.Path()
        ..moveTo(size / 2 - 20, 107)
        ..lineTo(size / 2 + 20, 107)
        ..lineTo(size / 2, 142)
        ..close(),
      pinPaint,
    );
    // Stream-colored hole so pin reads at distance
    canvas.drawCircle(const Offset(size / 2, 94), 9, Paint()..color = stream);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('marker rasterization failed');
    return bytes.buffer.asUint8List();
  }

  Widget _buildSheet(SteesColors colors) {
    final picked = _picked;
    final canSave =
        !(_saving || picked == null || _selectedDeviceId == null);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, 8, AppSpacing.lg, 10 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: colors.submerged,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Compact header — no card, minimal height, stable so
          // "Resolving place…" never shifts the dropdown.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.location_on_outlined,
                    size: 14, color: colors.stream),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 18,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _placeName ??
                              (picked == null
                                  ? 'Tap the map to choose the farm location'
                                  : _resolving
                                      ? 'Resolving place…'
                                      : 'Custom map point'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: colors.foam,
                              height: 1.1),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 12,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: picked == null
                            ? const SizedBox.shrink()
                            : Text(
                                '${picked.latitude.toStringAsFixed(4)}, ${picked.longitude.toStringAsFixed(4)}',
                                style: GoogleFonts.jetBrainsMono(
                                    fontSize: 10, color: colors.mist),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_resolving)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 3),
                  child: SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: colors.stream,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _selectedDeviceId,
            dropdownColor: colors.submerged,
            isDense: true,
            decoration: InputDecoration(
              labelText: 'Use for device',
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: colors.stream, width: 1.3),
              ),
            ),
            style: GoogleFonts.inter(fontSize: 12.5, color: colors.foam),
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
                unawaited(_mapController?.animateCamera(
                  ml.CameraUpdate.newLatLngZoom(
                    ml.LatLng(at.latitude, at.longitude),
                    12,
                  ),
                ));
              }
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!,
                style: GoogleFonts.inter(
                    fontSize: 11, color: colors.danger)),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: FilledButton.icon(
              onPressed: canSave ? _save : null,
              icon: _saving
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: colors.well))
                  : const Icon(Icons.check, size: 16),
              label: Text(_saving ? 'Saving…' : 'Confirm Location',
                  style: GoogleFonts.sora(
                      fontSize: 13.5, fontWeight: FontWeight.w700)),
              style: FilledButton.styleFrom(
                backgroundColor: colors.stream,
                foregroundColor: colors.well,
                disabledBackgroundColor: colors.stream.withValues(alpha: 0.45),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapZoomCluster extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  const _MapZoomCluster(
      {required this.onZoomIn, required this.onZoomOut});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Material(
      color: colors.submerged,
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(14)),
            onTap: onZoomIn,
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              child: Icon(Icons.add, size: 18, color: colors.foam),
            ),
          ),
          Container(height: 1, width: 28, color: colors.border.withValues(alpha: 0.7)),
          InkWell(
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(14)),
            onTap: onZoomOut,
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              child: Icon(Icons.remove, size: 18, color: colors.foam),
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
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
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.16),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colors.border.withValues(alpha: 0.8)),
          ),
          child: Icon(icon, size: 18, color: colors.foam),
        ),
      ),
    );
  }
}
