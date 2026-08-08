package com.example.smart_home_app

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val wifiSettingsChannelName = "stees/wifi_settings"
    private val wifiBindChannelName = "stees/wifi_binding"

    private var boundNetwork: Network? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    private val pendingWifiResults = mutableListOf<MethodChannel.Result>()

    private val connectivityManager: ConnectivityManager
        get() = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wifiSettingsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openWifiSettings" -> {
                        startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wifiBindChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureBoundToWifi" -> ensureBoundToWifi(result)
                    "releaseWifiBinding" -> releaseWifiBinding(result)
                    "getNetworkInfo" -> getNetworkInfo(result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        releaseWifiBinding(null)
        super.onDestroy()
    }

    /**
     * Forces subsequent process-wide sockets (Dart http, etc.) onto the WiFi
     * interface the phone is joined to. Uses ConnectivityManager.requestNetwork
     * with TRANSPORT_WIFI + NET_CAPABILITY_NOT_VPN and WITHOUT
     * NET_CAPABILITY_INTERNET, because the Tasmota AP has no internet and
     * otherwise Android routes requests over cellular.
     */
    private fun ensureBoundToWifi(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.error(
                "UNSUPPORTED",
                "Process WiFi binding requires Android 6.0+ (API 23).",
                null,
            )
            return
        }

        val network = boundNetwork
        if (network != null) {
            result.success(true)
            return
        }

        pendingWifiResults.add(result)
        createCallbackIfNeeded()
        if (pendingWifiResults.size > 1) return

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()

        try {
            connectivityManager.requestNetwork(request, wifiCallback!!)
        } catch (e: SecurityException) {
            failPending("SECURITY", "Missing ACCESS_NETWORK_STATE permission.", null)
        } catch (e: Exception) {
            failPending("ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun createCallbackIfNeeded() {
        if (wifiCallback != null) return
        wifiCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                bindTo(network)
            }

            override fun onUnavailable() {
                failPending(
                    "WIFI_UNAVAILABLE",
                    "No Android WiFi network available. Connect to the device Wi-Fi first.",
                    null,
                )
            }

            override fun onLost(network: Network) {
                if (network == boundNetwork) {
                    boundNetwork = null
                }
            }
        }
    }

    /**
     * Returns the transport/capabilities of the bound network (or the active
     * default if none bound), so the wizard can diagnose whether the phone is
     * still on the device AP (no internet) or was auto-switched back to a
     * router with internet.
     */
    private fun getNetworkInfo(result: MethodChannel.Result) {
        val nw = boundNetwork ?: connectivityManager.activeNetwork
        val caps = nw?.let { connectivityManager.getNetworkCapabilities(it) }
        val isWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val hasInternet = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        val validated = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        result.success(
            mapOf(
                "bound" to (boundNetwork != null),
                "wifi" to isWifi,
                "internet" to hasInternet,
                "validated" to validated,
            )
        )
    }

    private fun bindTo(network: Network) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val bound = runCatching { connectivityManager.bindProcessToNetwork(network) }
                .getOrElse { false }
            if (bound) {
                boundNetwork = network
                succeedPending()
            } else {
                failPending("BIND_FAILED", "Could not bind traffic to the WiFi interface.", null)
            }
        } else {
            failPending("UNSUPPORTED", "Network binding requires Android 6.0+ (API 23).", null)
        }
    }

    private fun releaseWifiBinding(result: MethodChannel.Result?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            runCatching { connectivityManager.bindProcessToNetwork(null) }
        }
        boundNetwork = null
        wifiCallback?.let { runCatching { connectivityManager.unregisterNetworkCallback(it) } }
        wifiCallback = null
        pendingWifiResults.clear()
        result?.success(null)
    }

    private fun succeedPending() {
        val results = pendingWifiResults.toList()
        pendingWifiResults.clear()
        results.forEach { it.success(true) }
    }

    private fun failPending(code: String, message: String, details: Any?) {
        val results = pendingWifiResults.toList()
        pendingWifiResults.clear()
        results.forEach { it.error(code, message, details) }
    }
}