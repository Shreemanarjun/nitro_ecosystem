package dev.shreeman.benchmark

import io.flutter.embedding.engine.plugins.FlutterPlugin
import nitro.benchmark_module.BenchmarkJniBridge

class BenchmarkPlugin : FlutterPlugin {

    companion object {
        init {
            System.loadLibrary("benchmark")
            System.loadLibrary("benchmark_cpp")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        BenchmarkJniBridge.register(
            BenchmarkImpl(binding.applicationContext)
        )

        val channel = io.flutter.plugin.common.MethodChannel(
            binding.binaryMessenger,
            "dev.shreeman.benchmark/method_channel"
        )
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "add" -> {
                        val a = call.argument<Double>("a") ?: 0.0
                        val b = call.argument<Double>("b") ?: 0.0
                        result.success(a + b)
                    }
                    "sendLargeBuffer" -> {
                        val buffer = call.arguments as? ByteArray
                        if (buffer != null) {
                            var sum = 0
                            for (i in buffer.indices step 4096) {
                                sum += buffer[i].toInt()
                            }
                        }
                        result.success(buffer?.size ?: 0)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                android.util.Log.e("NitroBenchmark", "MethodChannel Error: ${e.message}", e)
                result.error("ERR", e.message, null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}