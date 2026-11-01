package com.octosnap.octosnap_booth

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val usbThread = Executors.newSingleThreadExecutor()
    private var dslr: CanonPtpCamera? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "octosnap/dslr").setMethodCallHandler { call, result ->
            // All USB I/O runs on one background thread, so PTP transactions never overlap.
            usbThread.execute {
                try {
                    val value: Any? = when (call.method) {
                        "connect" -> {
                            dslr?.close()
                            val cam = CanonPtpCamera.open(this)
                            dslr = cam
                            cam.name
                        }
                        "startLiveView" -> { cam().startLiveView(); null }
                        "liveFrame" -> cam().liveViewFrame()
                        "capture" -> cam().capture()
                        "close" -> { dslr?.close(); dslr = null; null }
                        "isConnected" -> dslr?.isAttached() == true
                        else -> throw UnsupportedOperationException(call.method)
                    }
                    runOnUiThread { result.success(value) }
                } catch (e: Exception) {
                    if (call.method != "liveFrame" && call.method != "connect") {
                        // a failed transaction usually means the cable was pulled
                        if (dslr?.isAttached() != true) { dslr?.close(); dslr = null }
                    }
                    runOnUiThread { result.error("DSLR", e.message ?: e.toString(), null) }
                }
            }
        }
    }

    private fun cam(): CanonPtpCamera = dslr ?: throw IllegalStateException("DSLR not connected")

    override fun onDestroy() {
        usbThread.execute { dslr?.close() }
        super.onDestroy()
    }
}
