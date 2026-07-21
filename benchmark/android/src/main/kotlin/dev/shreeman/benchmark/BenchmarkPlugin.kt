package dev.shreeman.benchmark

import io.flutter.embedding.engine.plugins.FlutterPlugin
import nitro.benchmark_module.BenchmarkJniBridge
import nitro.nitro_ar_module.NitroArJniBridge

class BenchmarkPlugin : FlutterPlugin {

    companion object {
        init {
            System.loadLibrary("benchmark")
            System.loadLibrary("benchmark_cpp")
            // Required before NitroArJniBridge.registerFactory — its JNI
            // initialize() lives in libnitro_ar.so; without this the load
            // fails with UnsatisfiedLinkError inside onAttachedToEngine,
            // which also kills the MethodChannel registration below it.
            System.loadLibrary("nitro_ar")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // registerFactory: one impl per Dart-side instance (multi-instance
        // registry) — the old register(impl) API no longer exists.
        BenchmarkJniBridge.registerFactory({ BenchmarkImpl(binding.applicationContext) }, binding.applicationContext)
        NitroArJniBridge.registerFactory({ NitroArImpl() }, binding.applicationContext)

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
                    "deviceInfo" -> {
                        // Hardware identity for the benchmark report — a
                        // number without the machine it ran on is not
                        // comparable to anything.
                        result.success(mapOf(
                            "model" to android.os.Build.MODEL,
                            "manufacturer" to android.os.Build.MANUFACTURER,
                            "device" to android.os.Build.DEVICE,
                            "socOs" to "Android ${android.os.Build.VERSION.RELEASE} (SDK ${android.os.Build.VERSION.SDK_INT})",
                        ))
                    }
                    "sievePrimes" -> {
                        // Second reference workload: sieve of Eratosthenes —
                        // identical to src/nitro_workload.h; every tier must
                        // return the same prime count.
                        val limit = call.argument<Int>("limit") ?: 0
                        if (limit < 2) {
                            result.success(0L)
                        } else {
                            val composite = BooleanArray(limit)
                            var count = 0L
                            var i = 2
                            while (i < limit) {
                                if (!composite[i]) {
                                    count++
                                    var j = i.toLong() * i
                                    while (j < limit) {
                                        composite[j.toInt()] = true
                                        j += i
                                    }
                                }
                                i++
                            }
                            result.success(count)
                        }
                    }
                    "hashBuffer" -> {
                        // Reference workload: FNV-1a 64-bit — identical to
                        // src/nitro_workload.h; Long multiplication wraps
                        // mod 2^64, matching C uint64_t bit-for-bit.
                        val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                        val rounds = call.argument<Int>("rounds") ?: 1
                        var hash = -3750763034362895579L // 0xcbf29ce484222325
                        for (r in 0 until rounds) {
                            for (b in data) {
                                hash = hash xor (b.toLong() and 0xFF)
                                hash *= 1099511628211L // 0x100000001b3
                            }
                        }
                        result.success(hash)
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