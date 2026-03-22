package com.example.my_camera

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import kotlinx.coroutines.delay
import nitro.mycamera_module.HybridMyCameraSpec
import nitro.mycamera_module.MyCameraJniBridge

class MyCameraImpl : HybridMyCameraSpec {
    override fun add(a: Double, b: Double): Double {
        return a + b
    }

    override suspend fun getGreeting(name: String): String {
        delay(1000) // Simulate a heavy asynchronous camera initialization frame processing pause
        return "Hello \$name, from Kotlin Coroutines!"
    }
}

class MyCameraPlugin: FlutterPlugin {
    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        // Register our implementation over the JNI bridge inside Nitrogen!
        MyCameraJniBridge.register(MyCameraImpl())
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        // Cleanup if needed
    }
}
