package com.stees.stees_local

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

class MainActivity : FlutterActivity() {

    private val wifiSettingsChannelName = "stees/wifi_settings"
    private val wifiBindChannelName = "stees/wifi_binding"
    private val apConnectChannelName = "stees/ap_connect"

    private var boundNetwork: Network? = null

    private var apConnectCallback: ConnectivityManager.NetworkCallback? = null
    private var apConnectBoundNetwork: Network? = null
    private var apConnectRequestedAt: Long = 0
    private var apConnectAvailableAt: Long = 0
    private var apConnectStage: String = "idle"
    private var apConnectError: String? = null
    private val apConnectPermissionRequestCode = 4712

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingScanResult: MethodChannel.Result? = null
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
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == apConnectPermissionRequestCode) {
            val granted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (!granted) {
                apConnectStage = "failed"
                apConnectError = "NEARBY_WIFI_DEVICES was not granted; cannot request the AP."
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

    private fun scanWifi(result: MethodChannel.Result) {
        val permission = requiredScanPermission()
        if (permission != null && checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
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
        mainHandler.postDelayed({
            val scanned: List<android.net.wifi.ScanResult> =
                runCatching { wifi.scanResults }.getOrDefault(emptyList())
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
                    "networks" to networks,
                    "reason" to if (started) {
                        when {
                            networks.isNotEmpty() -> null
                            else -> "no networks found"
                        }
                    } else "scan rejected",
                )
            )
        }, 1200)
    }

    private fun requiredScanPermission(): String? {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> android.Manifest.permission.ACCESS_FINE_LOCATION
            else -> null
        }
    }

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
        if (!matched) {
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

        val bound = runCatching { connectivityManager.bindProcessToNetwork(active) }
            .getOrElse { false }
        if (bound) {
            boundNetwork = active
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

    private fun readSsid(): String? {
        val wm = wifiManager ?: return null
        return try {
            val info = wm.connectionInfo
            info.ssid?.trim()?.removeSurrounding("\"")?.takeIf { it.isNotBlank() && it != "<unknown ssid>" }
        } catch (e: SecurityException) {
            Log.d("SteesLocal", "[ap] cannot read SSID: ${e.message}")
            null
        }
    }

    private val macSsidRe = Regex("^[0-9A-Fa-f]{12}$")

    private fun ssidMatches(expected: String, active: String?): Boolean {
        if (active == null) {
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
            return true
        }
        val lower = act.lowercase()
        if (lower.startsWith("tasmota") || lower.startsWith("trelay") || lower.startsWith("t-relay")) {
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.NEARBY_WIFI_DEVICES)
                != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.NEARBY_WIFI_DEVICES), apConnectPermissionRequestCode)
            result.error(
                "PERMISSION_DENIED",
                "NEARBY_WIFI_DEVICES was not granted; use system Wi-Fi settings instead.",
                null,
            )
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
                val bound =
                    runCatching { connectivityManager.bindProcessToNetwork(network) }.getOrDefault(false)
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
                settle("unavailable")
            }

            override fun onLost(network: Network) {
                apConnectStage = "lost"
                apConnectError = "onLost: the connection to the AP was dropped."
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
