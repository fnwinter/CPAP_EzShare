package com.fnwinter.cpap_ezshare

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cpap_ezshare/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindWifi" -> result.success(bindToWifi())
                    "unbind" -> {
                        connectivity().bindProcessToNetwork(null)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun connectivity() =
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    /**
     * EzShare WiFi 는 인터넷이 없어서 Android 가 기본 경로를 모바일 데이터로 잡는다.
     * 앱 프로세스의 소켓을 WiFi 네트워크로 고정해 ezshare.card 에 접근할 수 있게 한다.
     */
    @Suppress("DEPRECATION")
    private fun bindToWifi(): Boolean {
        val cm = connectivity()
        val wifi = cm.allNetworks.firstOrNull { n ->
            cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
        if (wifi == null) {
            cm.bindProcessToNetwork(null)
            return false
        }
        return cm.bindProcessToNetwork(wifi)
    }
}
