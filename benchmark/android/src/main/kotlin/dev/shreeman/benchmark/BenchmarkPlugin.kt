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
            if (call.method == "add") {
                val a = call.argument<Double>("a") ?: 0.0
                val b = call.argument<Double>("b") ?: 0.0
                result.success(a + b)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}