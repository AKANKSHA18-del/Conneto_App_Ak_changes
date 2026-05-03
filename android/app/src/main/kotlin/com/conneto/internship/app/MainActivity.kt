package com.conneto.internship.app

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SESSION_CHANNEL = "conneto/session"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SESSION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "flushCookies" -> {
                    try {
                        val cookieManager = CookieManager.getInstance()
                        cookieManager.setAcceptCookie(true)
                        cookieManager.flush()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("COOKIE_FLUSH_FAILED", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
