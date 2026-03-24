package com.example.my_camera

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import nitro.my_camera_module.HybridMyCameraSpec
import nitro.my_camera_module.MyCameraJniBridge
import nitro.my_camera_module.CameraFrame
import nitro.my_camera_module.CameraDevice
import nitro.my_camera_module.Resolution
import nitro.complex_module.HybridComplexModuleSpec
import nitro.complex_module.ComplexModuleJniBridge
import nitro.complex_module.DeviceStatus
import nitro.complex_module.SensorData
import nitro.complex_module.Packet
import nitro.verification_module.VerificationModuleJniBridge

class MyCameraImpl : HybridMyCameraSpec {
    override fun add(a: Double, b: Double): Double {
        return a + b
    }

    override suspend fun getGreeting(name: String): String {
        delay(1000)
        return "Hello $name, from Kotlin Coroutines!"
    }

    override suspend fun getAvailableDevices(): List<CameraDevice> {
        return listOf(
            CameraDevice("cam-001", "Ultra Wide Back Camera", listOf(Resolution(3840, 2160), Resolution(1920, 1080)), false),
            CameraDevice("cam-002", "Selfie Camera", listOf(Resolution(1280, 720)), true)
        )
    }

    override val frames: Flow<CameraFrame> = flow {
        val width = 1280L
        val height = 720L
        val bytesPerPixel = 4L
        val stride = width * bytesPerPixel
        val buffer = java.nio.ByteBuffer.allocateDirect((stride * height).toInt())
        while (true) {
            val tsNs = System.nanoTime()
            emit(CameraFrame(buffer, width, height, stride, tsNs))
            delay(33)
        }
    }

    override val coloredFrames: Flow<CameraFrame> = flow {
        val width = 640L
        val height = 480L
        val bytesPerPixel = 4L
        val stride = width * bytesPerPixel
        val buffer = java.nio.ByteBuffer.allocateDirect((stride * height).toInt())
        var frameCount = 0
        while (true) {
            val r = ((frameCount * 2) % 256).toByte()
            val g = ((frameCount * 5) % 256).toByte()
            val b = ((frameCount * 10) % 256).toByte()
            val a = 255.toByte()

            buffer.rewind()
            for (i in 0 until (width * height).toInt()) {
                buffer.put(r)
                buffer.put(g)
                buffer.put(b)
                buffer.put(a)
            }
            
            val tsNs = System.nanoTime()
            emit(CameraFrame(buffer, width, height, stride, tsNs))
            frameCount++
            delay(33)
        }
    }
}

class ComplexModuleImpl : HybridComplexModuleSpec {
    override val batteryLevel: Double = 0.85
    override var config: String = "{}"

    override fun calculate(seed: Long, factor: Double, enabled: Boolean): Long {
        return if (enabled) (seed * factor).toLong() else seed
    }

    override suspend fun fetchMetadata(url: String): String {
        return "Metadata for $url"
    }

    override fun getStatus(): DeviceStatus {
        return DeviceStatus.IDLE
    }

    override fun updateSensors(data: SensorData) {
        println("Updating sensors: temp=${data.temperature} humidity=${data.humidity}")
    }

    override suspend fun generatePacket(type: Long): Packet {
        val buf = java.nio.ByteBuffer.allocateDirect(100)
        return Packet(sequence = type, buffer = buf, size = 100L)
    }

    override val sensorStream: Flow<SensorData> = flow {
        while (true) {
            emit(SensorData(temperature = Math.random() * 40, humidity = Math.random(), lastUpdate = System.currentTimeMillis()))
            delay(100)
        }
    }

    override val dataStream: Flow<Packet> = flow {
        var seq = 0L
        while (true) {
            val buf = java.nio.ByteBuffer.allocateDirect(64)
            emit(Packet(sequence = seq++, buffer = buf, size = 64L))
            delay(200)
        }
    }
}

class MyCameraPlugin: FlutterPlugin {
    companion object {
        init {
            System.loadLibrary("my_camera")
            System.loadLibrary("verification")
            System.loadLibrary("complex")
        }
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        MyCameraJniBridge.register(MyCameraImpl())
        ComplexModuleJniBridge.register(ComplexModuleImpl())
        VerificationModuleJniBridge.register(VerificationModuleImpl())
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    }
}
