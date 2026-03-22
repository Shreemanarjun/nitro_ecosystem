package com.example.my_camera

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import nitro.my_camera_module.HybridMyCameraSpec
import nitro.my_camera_module.MyCameraJniBridge
import nitro.my_camera_module.CameraFrame
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
}

class ComplexImpl : HybridComplexModuleSpec {
    override var batteryLevel: Double = 0.85
    override var config: String = "{}"
    
    override suspend fun fetchMetadata(url: String): String {
        return "Metadata for $url"
    }
    
    override fun getStatus(): DeviceStatus {
        return DeviceStatus.CONNECTED
    }
    
    override fun updateSensors(data: SensorData) {
        println("Updating sensors with ${data.value}")
    }
    
    override suspend fun generatePacket(type: Long): Packet {
        return Packet("Type $type", java.nio.ByteBuffer.allocateDirect(100))
    }
    
    override val dataStream: Flow<SensorData> = flow {
        while(true) {
            emit(SensorData(Math.random(), System.currentTimeMillis()))
            delay(100)
        }
    }
}

class MyCameraPlugin: FlutterPlugin {
    companion object {
        init {
            System.loadLibrary("my_camera")
        }
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        MyCameraJniBridge.register(MyCameraImpl())
        ComplexModuleJniBridge.register(ComplexImpl())
        VerificationModuleJniBridge.register(VerificationImpl())
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    }
}
