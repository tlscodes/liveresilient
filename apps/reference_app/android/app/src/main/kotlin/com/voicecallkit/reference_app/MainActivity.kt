package com.voicecallkit.reference_app

import android.content.Context
import android.net.ConnectivityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_DNS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "firstResolver") {
                    result.success(firstResolver())
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * This device's own DNS resolver: the first `dnsServers` entry of the
     * active link, as a numeric host — the address Android itself sends this
     * connection's queries to. A read of link configuration only (needs
     * ACCESS_NETWORK_STATE, a normal permission); nothing is probed. Null
     * when there is no active network, it names no server, or anything
     * throws. An IPv6 scope suffix (`%wlan0`) is dropped.
     */
    private fun firstResolver(): String? = try {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val link = manager.activeNetwork?.let { manager.getLinkProperties(it) }
        link?.dnsServers?.firstOrNull()?.hostAddress?.substringBefore('%')
    } catch (e: Exception) {
        null
    }

    private companion object {
        /** Must match `SystemDns.channelName` in system_dns.dart. */
        const val SYSTEM_DNS_CHANNEL = "com.tlscodes.reference_app/system_dns"
    }
}
