package com.example.smart_home_app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val wifiSettingsChannelName = "stees/wifi_settings"
    private val wifiBindChannelName = "stees/wifi_binding"
    private val apConnectChannelName = "stees/ap_connect"

    private var boundNetwork: Network? = null
    private var pendingScanResult: MethodChannel.Result? = null

    // ─────────────────────────────────────────────────────────────
    // Simple programmatic soft-AP join (Android only, API 29+): the user picks
    // the device AP from the in-app list, taps Continue, and we request exactly
    // that SSID via WifiNetworkSpecifier. No auto-discovery, no retry loop - a
    // single request, then the wizard's own 192.168.4.1 probe decides success.
    // The Tasmota factory AP (tasmota-XXXX) is open/unsecured, so no password
    // is set on the specifier. On API 24-28 the Dart side never calls this.
    // ─────────────────────────────────────────────────────────────
    private var apConnectCallback: ConnectivityManager.NetworkCallback? = null
    private var apConnectBoundNetwork: Network? = null
    private var apConnectRequestedAt: Long = 0
    private var apConnectAvailableAt: Long = 0
    private var apConnectStage: String = "idle" // idle|requesting|awaiting_system|available|unavailable|lost|failed|cancelled
    private var apConnectError: String? = null
    private var pendingApConnectResult: MethodChannel.Result? = null
    private var pendingApConnectSsid: String? = null
    private val apConnectPermissionRequestCode = 4712

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scanRequestCode = 4711

    private val connectivityManager: ConnectivityManager
        get() = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val wifiManager: WifiManager?
        get() = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wifiSettingsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openWifiSettings" -> {
                        startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                        result.success(null)
                    }
                    "openLocationSettings" -> openLocationSettings(result)
                    "openAppSettings" -> openAppSettings(result)
                    "scanWifi" -> scanWifi(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wifiBindChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureBoundToActiveWifi" -> {
                        val expected = call.argument<String>("expectedSsid").orEmpty()
                        ensureBoundToActiveWifi(expected, result)
                    }
                    "releaseWifiBinding" -> releaseWifiBinding(result)
                    "getNetworkInfo" -> getNetworkInfo(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, apConnectChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connectToAp" -> {
                        val ssid = call.argument<String>("ssid").orEmpty()
                        apConnectToAp(ssid, result)
                    }
                    "getState" -> apConnectGetState(result)
                    "cancel" -> {
                        apConnectDisconnect()
                        apConnectStage = "cancelled"
                        result.success(null)
                    }
                    "sdkInfo" -> {
                        result.success(
                            mapOf(
                                "sdkInt" to Build.VERSION.SDK_INT,
                                "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        releaseWifiBinding(null)
        apConnectDisconnect()
        pendingScanResult?.error("ABORTED", "Activity destroyed before Wi-Fi scan finished.", null)
        pendingScanResult = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == apConnectPermissionRequestCode) {
            val granted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            val result = pendingApConnectResult
            val ssid = pendingApConnectSsid
            pendingApConnectResult = null
            pendingApConnectSsid = null
            if (granted && ssid != null && result != null) {
                apConnectStart(ssid, result)
            } else {
                result?.error(
                    "PERMISSION_DENIED",
                    "NEARBY_WIFI_DEVICES was not granted; cannot request the AP.",
                    null,
                )
            }
            return
        }
        if (requestCode == scanRequestCode) {
            val granted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (granted) {
                startWifiScan()
            } else {
                val result = pendingScanResult
                pendingScanResult = null
                result?.success(
                    mapOf(
                        "available" to false,
                        "networks" to emptyList<String>(),
                        "reason" to "permission denied",
                    )
                )
            }
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    /**
     * Scans for nearby Wi-Fi SSIDs WITHOUT disconnecting the phone from the
     * Tasmota AP the user is currently on. This is a passive read of the
     * radio-side scan results — connecting happens only via the system Wi-Fi
     * settings, never here. Requires location permission on Android 6.1+;
     * if it is missing we request it at runtime. On any failure we degrade
     * gracefully (Dart keeps "Enter network manually").
     */
    /**
     * Android 10+ hides Wi-Fi scan results from apps entirely when the
     * system Location service is OFF — even with location permission
     * granted. This is the #1 cause of "networks visible in Settings but
     * not in the app". Surface it so the UI can guide the user.
     */
    private fun isLocationServiceEnabled(): Boolean {
        val lm = applicationContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        return runCatching {
            lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
                lm?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
        }.getOrDefault(true)
    }

    private fun openLocationSettings(result: MethodChannel.Result) {
        startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
        result.success(null)
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:$packageName"),
        )
        startActivity(intent)
        result.success(null)
    }

    private fun scanWifi(result: MethodChannel.Result) {
        val permission = requiredScanPermission()
        if (permission != null && checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && permission != null) {
                if (pendingScanResult != null) {
                    result.success(
                        mapOf(
                            "available" to false,
                            "networks" to emptyList<String>(),
                            "reason" to "scan in progress",
                        )
                    )
                    return
                }
                pendingScanResult = result
                requestPermissions(arrayOf(permission), scanRequestCode)
                return
            }
            result.success(
                mapOf(
                    "available" to false,
                    "networks" to emptyList<String>(),
                    "reason" to "permission missing",
                )
            )
            return
        }
        // Permission already granted: still store the result so startWifiScan()
        // can complete the Dart call. Without this the pending result stays
        // null, startWifiScan() returns early and the sheet spins forever.
        pendingScanResult = result
        startWifiScan()
    }

    private fun startWifiScan() {
        val result = pendingScanResult ?: return
        pendingScanResult = null
        val wm = wifiManager
        val enabled = runCatching { wm?.isWifiEnabled }.getOrDefault(false)
        if (wm == null || enabled != true) {
            result.success(
                mapOf(
                    "available" to false,
                    "networks" to emptyList<String>(),
                    "reason" to "Wi-Fi off or unavailable",
                )
            )
            return
        }
        val wifi: WifiManager = wm
        val locationOn = isLocationServiceEnabled()
        val started = runCatching { wifi.startScan() }.getOrDefault(false)
        // Scan results arrive asynchronously; read them shortly after startScan().
        mainHandler.postDelayed({
            val scanned: List<android.net.wifi.ScanResult> =
                runCatching { wifi.scanResults }.getOrDefault(emptyList())
            // Dedupe by SSID keeping the STRONGEST radio (same SSID can be
            // broadcast by several BSSIDs); carry RSSI + BSSID so the UI can
            // surface signal strength and disambiguate multiple device APs.
            data class Entry(val rssi: Int, val bssid: String?)
            val best = LinkedHashMap<String, Entry>()
            for (sr in scanned) {
                val name = sr.SSID?.trim()?.removeSurrounding("\"")
                if (name.isNullOrBlank() || name == "<unknown ssid>") continue
                val cur = best[name]
                if (cur == null || sr.level > cur.rssi) {
                    best[name] = Entry(sr.level, sr.BSSID)
                }
            }
            val networks = best.map { (name, e) ->
                mapOf("name" to name, "rssi" to e.rssi, "bssid" to e.bssid)
            }
            result.success(
                mapOf(
                    "available" to true,
                    "locationEnabled" to locationOn,
                    "networks" to networks,
                    "reason" to if (started) {
                        when {
                            networks.isNotEmpty() -> null
                            !locationOn -> "location services off"
                            else -> "no networks found"
                        }
                    } else "scan rejected",
                )
            )
        }, 1200)
    }

    private fun requiredScanPermission(): String? {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> android.Manifest.permission.ACCESS_FINE_LOCATION
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> android.Manifest.permission.ACCESS_FINE_LOCATION
            else -> null
        }
    }

    /**
     * Binds the process sockets to the CURRENTLY ACTIVE Android Wi-Fi network.
     *
     * We deliberately do NOT use ConnectivityManager.requestNetwork(): that call
     * asks Android to pick "the best" qualifying network, and when the user is
     * inside the Tasmota AP range Android will happily select the router WiFi
     * (internet/validated) over the AP, which has neither. Instead the user
     * manually selects the Tasmota AP in Wi-Fi settings; by the time they come
     * back the selection is the ACTIVE network, so we bind to exactly that.
     *
     * SSID (when readable) is used to sanity-check the match. The AP never has
     * internet/validated, so those flags are diagnostics only — never used to
     * identify the Tasmota network.
     */
    private fun ensureBoundToActiveWifi(expectedSsid: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.error(
                "UNSUPPORTED",
                "Process WiFi binding requires Android 6.0+ (API 23).",
                null,
            )
            return
        }

        val active = connectivityManager.activeNetwork
        val caps = active?.let { connectivityManager.getNetworkCapabilities(it) }
        val isWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val ssid = readSsid()

        if (active == null || !isWifi) {
            Log.d("SteesProvision", 
                "[PROVISION] expected SSID: $expectedSsid / active SSID: ${ssid ?: "<unknown>"} / not on Wi-Fi"
            )
            result.success(
                mapOf(
                    "matched" to false,
                    "bound" to false,
                    "wifi" to isWifi,
                    "internet" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true),
                    "validated" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
                    "activeSsid" to ssid,
                )
            )
            return
        }

        val matched = ssidMatches(expectedSsid, ssid)
        Log.d("SteesProvision", "[provision] expected SSID: $expectedSsid")
        Log.d("SteesProvision", "[provision] active SSID: ${ssid ?: "<unknown>"}")
        if (!matched) {
            Log.d("SteesProvision", "[provision] wrong Wi-Fi network")
            result.success(
                mapOf(
                    "matched" to false,
                    "bound" to false,
                    "wifi" to true,
                    "internet" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true),
                    "validated" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
                    "activeSsid" to ssid,
                )
            )
            return
        }

        Log.d("SteesProvision", "[provision] active Wi-Fi network matched")
        val bound = runCatching { connectivityManager.bindProcessToNetwork(active) }
            .getOrElse { false }
        if (bound) {
            boundNetwork = active
            Log.d("SteesProvision", "[provision] process bound to active Wi-Fi")
        } else {
            Log.d("SteesProvision", "[provision] bindProcessToNetwork failed for active Wi-Fi")
        }
        result.success(
            mapOf(
                "matched" to true,
                "bound" to bound,
                "wifi" to true,
                "internet" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true),
                "validated" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
                "activeSsid" to ssid,
            )
        )
    }

    /**
     * Best-effort read of the current Wi-Fi SSID.
     *
     * On Android 10+ (API 29+) the SSID is only exposed to apps holding the
     * ACCESS_FINE_LOCATION runtime permission (and with location services on);
     * on Android 12+ (API 31+) WifiManager.getConnectionInfo() returns opaque
     * fake data without it. This app does not request location, so in those
     * cases we log the limitation and return null — the caller proceeds with
     * the binding to the active network (the user-selected AP) and lets the
     * probe on 192.168.4.1 be the authoritative test.
     */
    private fun readSsid(): String? {
        val wm = wifiManager ?: return null
        return try {
            val info = wm.connectionInfo
            info.ssid?.trim()?.removeSurrounding("\"")?.takeIf { it.isNotBlank() && it != "<unknown ssid>" }
        } catch (e: SecurityException) {
            Log.d("SteesProvision", "[provision] cannot read SSID (no location permission on this Android version): ${e.message}")
            null
        }
    }

    /**
     * Matches the expected SSID against the active SSID.
     * - If the wizard still shows the placeholder "tasmota-XXXX" the expected
     *   value is used as a prefix wildcard ("tasmota-"), matching any device AP.
     * - Otherwise an exact, case-insensitive comparison is required.
     * - A bare 12-hex-digit active SSID is always accepted as a device AP:
     *   Tasmota names its fallback AP after Hostname, and devices configured
     *   before (Topic/Hostname = canonical MAC) re-enter setup mode under
     *   their MAC-looking name instead of "tasmota-XXXXXX". The probe on
     *   192.168.4.1 stays the authoritative reachability test.
     * - If the active SSID could not be read (permission restricted), we cannot
     *   prove a match. Call the binding anyway so the probe on 192.168.4.1 is
     *   the authoritative reachability test, and log the limitation.
     */
    private val macSsidRe = Regex("^[0-9A-Fa-f]{12}$")

    private fun ssidMatches(expected: String, active: String?): Boolean {
        if (active == null) {
            Log.d("SteesProvision", "[probe] SSID unavailable; relying on the active-network probe instead")
            return true
        }
        val exp = expected.trim().removeSurrounding("\"")
        val act = active.trim()
        if (exp.lowercase().endsWith("xxxx")) {
            val prefix = exp.dropLast(4).lowercase()
            if (prefix.isNotEmpty() && act.lowercase().startsWith(prefix)) return true
        } else if (exp.equals(act, ignoreCase = true)) {
            return true
        }
        if (macSsidRe.matches(act)) {
            Log.d("SteesProvision", "[probe] active SSID is a MAC-shaped device AP; accepting for bind")
            return true
        }
        return false
    }

    private fun getNetworkInfo(result: MethodChannel.Result) {
        val nw = boundNetwork ?: connectivityManager.activeNetwork
        val caps = nw?.let { connectivityManager.getNetworkCapabilities(it) }
        result.success(
            mapOf(
                "bound" to (boundNetwork != null),
                "wifi" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
                "internet" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true),
                "validated" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
            )
        )
    }

    private fun releaseWifiBinding(result: MethodChannel.Result?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            runCatching { connectivityManager.bindProcessToNetwork(null) }
        }
        boundNetwork = null
        result?.success(null)
    }

    // ─────────────────────────────────────────────────────────────
    // Simple programmatic soft-AP join via WifiNetworkSpecifier.
    //
    // Joins the exact SSID the user picked in the in-app list. The Tasmota
    // factory AP is open (no password), so no WifiNetworkSpecifier password is
    // set. We request ONLY `TRANSPORT_WIFI` + `TRUSTED` and never
    // `NET_CAPABILITY_INTERNET`/`VALIDATED`, so Android has no cause to show a
    // captive-portal / "sign in" prompt. The wizard decides reachability with
    // its own 192.168.4.1 probe; this channel only requests, binds and reports.
    // ─────────────────────────────────────────────────────────────
    private fun apConnectToAp(ssid: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "UNSUPPORTED",
                "WifiNetworkSpecifier requires Android 10+ (API 29); this device is API ${Build.VERSION.SDK_INT}.",
                null,
            )
            return
        }
        if (ssid.isBlank()) {
            result.error("BAD_SSID", "SSID must not be empty.", null)
            return
        }
        // Android 13+ (API 33+) requires NEARBY_WIFI_DEVICES at runtime before
        // a specifier request can be issued. Denial is reported as
        // PERMISSION_DENIED so Dart falls back to the manual settings flow.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.NEARBY_WIFI_DEVICES)
                != PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingApConnectResult != null) {
                result.error("BUSY", "A permission request is already pending.", null)
                return
            }
            pendingApConnectResult = result
            pendingApConnectSsid = ssid
            requestPermissions(arrayOf(android.Manifest.permission.NEARBY_WIFI_DEVICES), apConnectPermissionRequestCode)
            return
        }
        apConnectStart(ssid, result)
    }

    private fun apConnectStart(ssid: String, result: MethodChannel.Result) {
        apConnectDisconnect()
        apConnectRequestedAt = SystemClock.elapsedRealtime()
        apConnectAvailableAt = 0
        apConnectError = null
        apConnectStage = "requesting"

        // Resolve the ORIGINAL Dart call exactly once on the first terminal
        // event (or a 20 s guard) instead of letting Dart poll getState. A
        // dedicated runnable is used so cancelling the timeout never touches
        // the shared handler's other delayed work.
        var settled = false
        var timeoutRunnable: Runnable? = null
        val settle = { stage: String ->
            if (!settled) {
                settled = true
                timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                result.success(mapOf("stage" to stage))
            }
            Unit
        }
        timeoutRunnable = Runnable {
            apConnectStage = "timeout"
            apConnectError = "Specifier request timed out after 20s."
            settle("timeout")
        }

        val specifier = WifiNetworkSpecifier.Builder().setSsid(ssid).build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
            .setNetworkSpecifier(specifier)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                apConnectAvailableAt = SystemClock.elapsedRealtime()
                apConnectBoundNetwork = network
                apConnectStage = "available"
                Log.d(
                    "SteesProvision",
                    "[ap_connect] onAvailable network=$network elapsed=${apConnectAvailableAt - apConnectRequestedAt}ms",
                )
                val bound =
                    runCatching { connectivityManager.bindProcessToNetwork(network) }.getOrDefault(false)
                Log.d("SteesProvision", "[ap_connect] bindProcessToNetwork=$bound")
                if (bound) {
                    settle("available")
                } else {
                    apConnectStage = "failed"
                    apConnectError = "bindProcessToNetwork failed; cannot route the probe to the AP."
                    settle("bindFailed")
                }
            }

            override fun onUnavailable() {
                apConnectStage = "unavailable"
                apConnectError = "onUnavailable: no matching AP found or request rejected by the system."
                Log.d("SteesProvision", "[ap_connect] onUnavailable")
                settle("unavailable")
            }

            override fun onLost(network: Network) {
                apConnectStage = "lost"
                apConnectError = "onLost: the connection to the AP was dropped."
                Log.d("SteesProvision", "[ap_connect] onLost network=$network")
                settle("lost")
            }
        }
        apConnectCallback = cb
        connectivityManager.requestNetwork(request, cb)
        apConnectStage = "awaiting_system"
        mainHandler.postDelayed(timeoutRunnable, 20_000L)
    }

    private fun apConnectDisconnect() {
        apConnectCallback?.let {
            runCatching { connectivityManager.unregisterNetworkCallback(it) }
        }
        apConnectCallback = null
        apConnectBoundNetwork = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            runCatching { connectivityManager.bindProcessToNetwork(null) }
        }
    }

    private fun apConnectGetState(result: MethodChannel.Result) {
        result.success(
            mapOf(
                "sdkInt" to Build.VERSION.SDK_INT,
                "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
                "stage" to apConnectStage,
                "bound" to (apConnectBoundNetwork != null),
                "elapsedToAvailableMs" to if (apConnectAvailableAt != 0L) (apConnectAvailableAt - apConnectRequestedAt) else -1L,
                "error" to apConnectError,
            )
        )
    }
}