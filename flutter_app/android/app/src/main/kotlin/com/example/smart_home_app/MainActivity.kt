package com.example.smart_home_app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
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
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : FlutterActivity() {

    private val wifiSettingsChannelName = "stees/wifi_settings"
    private val wifiBindChannelName = "stees/wifi_binding"

    // ─────────────────────────────────────────────────────────────
    // EXPERIMENTAL POC (Android only, API 29+): programmatic soft-AP
    // connect via WifiNetworkSpecifier. Isolated from the real
    // provisioning flow — do NOT wire this into production.
    // ─────────────────────────────────────────────────────────────
    private val apPocChannelName = "stees/ap_connect_poc"

    private var apPocCallback: ConnectivityManager.NetworkCallback? = null
    private var apPocBoundNetwork: Network? = null
    private var apPocRequestedAt: Long = 0
    private var apPocAvailableAt: Long = 0
    private var apPocHttpGetAt: Long = 0
    private var apPocHttpGetStatus: Int = -1
    private var apPocHttpGetOk: Boolean = false
    private var apPocError: String? = null
    private var apPocStage: String = "idle" // idle|requesting|awaiting_system|available|http_ok|http_failed|unavailable|lost|failed|cancelled
    private var pendingApPocResult: MethodChannel.Result? = null
    private var pendingApPocSsid: String? = null
    private var pendingApPocUrl: String? = null
    private val apPocPermissionRequestCode = 4712

    private var boundNetwork: Network? = null
    private var pendingScanResult: MethodChannel.Result? = null

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

        // ─────────────────────────────────────────────────────────────
        // EXPERIMENTAL POC channel — WifiNetworkSpecifier soft-AP connect.
        // Android only, API 29+. Isolated from the real provisioning flow.
        // ─────────────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, apPocChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connectToAp" -> {
                        val ssid = call.argument<String>("ssid").orEmpty()
                        val url = call.argument<String>("gatewayUrl")
                        apPocConnectToAp(ssid, url, result)
                    }
                    "getState" -> apPocGetState(result)
                    "cancel" -> {
                        apPocDisconnect()
                        apPocStage = "cancelled"
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
        apPocDisconnect()
        pendingScanResult?.error("ABORTED", "Activity destroyed before Wi-Fi scan finished.", null)
        pendingScanResult = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == apPocPermissionRequestCode) {
            val granted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            val result = pendingApPocResult
            val ssid = pendingApPocSsid
            val url = pendingApPocUrl
            pendingApPocResult = null
            pendingApPocSsid = null
            pendingApPocUrl = null
            if (granted && ssid != null && result != null) {
                apPocStart(ssid, url, result)
            } else {
                result?.error("PERMISSION_DENIED", "NEARBY_WIFI_DEVICES was not granted; cannot request the AP.", null)
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
        val started = runCatching { wifi.startScan() }.getOrDefault(false)
        // Scan results arrive asynchronously; read them shortly after startScan().
        mainHandler.postDelayed({
            val scanned: List<android.net.wifi.ScanResult> =
                runCatching { wifi.scanResults }.getOrDefault(emptyList())
            val names: MutableList<String> = mutableListOf()
            for (sr in scanned) {
                val name = sr.SSID?.trim()?.removeSurrounding("\"")
                if (!name.isNullOrBlank() && name != "<unknown ssid>" && !names.contains(name)) {
                    names.add(name)
                }
            }
            names.sort()
            if (names.isEmpty()) {
                result.success(
                    mapOf(
                        "available" to true,
                        "networks" to emptyList<String>(),
                        "reason" to if (started) "no networks found" else "scan rejected",
                    )
                )
            } else {
                result.success(
                    mapOf(
                        "available" to true,
                        "networks" to names,
                        "reason" to null,
                    )
                )
            }
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
     * - If the active SSID could not be read (permission restricted), we cannot
     *   prove a match. Call the binding anyway so the probe on 192.168.4.1 is
     *   the authoritative reachability test, and log the limitation.
     */
    private fun ssidMatches(expected: String, active: String?): Boolean {
        if (active == null) {
            Log.d("SteesProvision", "[probe] SSID unavailable; relying on the active-network probe instead")
            return true
        }
        val exp = expected.trim().removeSurrounding("\"")
        val act = active.trim()
        if (exp.lowercase().endsWith("xxxx")) {
            val prefix = exp.dropLast(4).lowercase()
            return prefix.isNotEmpty() && act.lowercase().startsWith(prefix)
        }
        return exp.equals(act, ignoreCase = true)
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
    // EXPERIMENTAL POC: WifiNetworkSpecifier soft-AP connect.
    //
    // QUESTION UNDER TEST: does a programmatic specifier join connect
    // to the Tasmota soft-AP WITHOUT the OS kicking the user into the
    // captive-portal / "sign in" browser or settings UI?
    //
    // We deliberately request ONLY `TRANSPORT_WIFI` + `TRUSTED` and do
    // NOT ask for `NET_CAPABILITY_INTERNET`/`VALIDATED`, so the system
    // has no cause to run its captive-portal verification flow on this
    // network. Observed dialog behavior must still be confirmed by eye.
    //
    // API gate: WifiNetworkSpecifier requires API 29+. minSdk stays 24.
    // ─────────────────────────────────────────────────────────────
    private fun apPocConnectToAp(ssid: String, gatewayUrl: String?, result: MethodChannel.Result) {
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
        // Android 13+ (API 33+) requires NEARBY_WIFI_DEVICES to be granted
        // at runtime before a specifier request can be issued.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.NEARBY_WIFI_DEVICES)
                != PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingApPocResult != null) {
                result.error("BUSY", "A POC permission request is already pending.", null)
                return
            }
            pendingApPocResult = result
            pendingApPocSsid = ssid
            pendingApPocUrl = gatewayUrl
            requestPermissions(arrayOf(android.Manifest.permission.NEARBY_WIFI_DEVICES), apPocPermissionRequestCode)
            return
        }
        apPocStart(ssid, gatewayUrl, result)
    }

    private fun apPocStart(ssid: String, gatewayUrl: String?, result: MethodChannel.Result) {
        apPocDisconnect()
        val gateway = gatewayUrl.takeIf { !it.isNullOrBlank() } ?: "http://192.168.4.1/"
        apPocRequestedAt = SystemClock.elapsedRealtime()
        apPocAvailableAt = 0
        apPocHttpGetAt = 0
        apPocHttpGetStatus = -1
        apPocHttpGetOk = false
        apPocError = null
        apPocStage = "requesting"

        val specifier = WifiNetworkSpecifier.Builder().setSsid(ssid).build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
            .setNetworkSpecifier(specifier)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                apPocAvailableAt = SystemClock.elapsedRealtime()
                apPocBoundNetwork = network
                apPocStage = "available"
                Log.d("ApConnectPoc", "[POC] onAvailable network=$network elapsed=${apPocAvailableAt - apPocRequestedAt}ms")
                val bound = runCatching { connectivityManager.bindProcessToNetwork(network) }.getOrDefault(false)
                Log.d("ApConnectPoc", "[POC] bindProcessToNetwork=$bound")
                // GET the Tasmota gateway over THAT network specifically.
                Thread {
                    apPocHttpGet(network, gateway)
                }.start()
            }

            override fun onUnavailable() {
                apPocStage = "unavailable"
                apPocError = "onUnavailable: no matching AP found or request rejected by the system."
                Log.d("ApConnectPoc", "[POC] onUnavailable")
            }

            override fun onLost(network: Network) {
                apPocStage = "lost"
                apPocError = "onLost: the connection to the AP was dropped."
                Log.d("ApConnectPoc", "[POC] onLost network=$network")
            }
        }
        apPocCallback = cb
        connectivityManager.requestNetwork(request, cb)
        apPocStage = "awaiting_system"
        result.success(null)
    }

    private fun apPocHttpGet(network: Network, url: String) {
        var status = -1
        var ok = false
        var err: String? = null
        try {
            val conn = network.openConnection(URL(url)) as HttpURLConnection
            conn.connectTimeout = 3000
            conn.readTimeout = 3000
            conn.instanceFollowRedirects = false
            conn.requestMethod = "GET"
            status = conn.responseCode
            // Tasmota serves its web UI with 200; any 2xx/3xx counts as reachable.
            ok = status in 200..399
            conn.disconnect()
        } catch (e: Exception) {
            err = e.toString()
        }
        apPocHttpGetStatus = status
        apPocHttpGetOk = ok
        apPocHttpGetAt = SystemClock.elapsedRealtime()
        apPocStage = if (ok) "http_ok" else "http_failed"
        apPocError = err
        Log.d("ApConnectPoc", "[POC] GET $url => status=$status ok=$ok elapsed=${apPocHttpGetAt - apPocRequestedAt}ms err=$err")
    }

    private fun apPocDisconnect() {
        apPocCallback?.let {
            runCatching { connectivityManager.unregisterNetworkCallback(it) }
        }
        apPocCallback = null
        apPocBoundNetwork = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            runCatching { connectivityManager.bindProcessToNetwork(null) }
        }
    }

    private fun apPocGetState(result: MethodChannel.Result) {
        val now = SystemClock.elapsedRealtime()
        result.success(
            mapOf(
                "sdkInt" to Build.VERSION.SDK_INT,
                "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
                "stage" to apPocStage,
                "requestedAt" to apPocRequestedAt,
                "availableAt" to apPocAvailableAt,
                "httpGetAt" to apPocHttpGetAt,
                "httpStatus" to apPocHttpGetStatus,
                "httpOk" to apPocHttpGetOk,
                "elapsedToAvailableMs" to if (apPocAvailableAt != 0L) (apPocAvailableAt - apPocRequestedAt) else -1L,
                "elapsedToHttpGetMs" to if (apPocHttpGetAt != 0L) (apPocHttpGetAt - apPocRequestedAt) else -1L,
                "bound" to (apPocBoundNetwork != null),
                "error" to apPocError,
            )
        )
    }
}