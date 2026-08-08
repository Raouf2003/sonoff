package com.example.smart_home_app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val wifiSettingsChannelName = "stees/wifi_settings"
    private val wifiBindChannelName = "stees/wifi_binding"

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
    }

    override fun onDestroy() {
        releaseWifiBinding(null)
        pendingScanResult?.error("ABORTED", "Activity destroyed before Wi-Fi scan finished.", null)
        pendingScanResult = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
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
}