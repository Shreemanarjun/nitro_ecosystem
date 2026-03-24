package com.example.my_camera

import nitro.verification_module.HybridVerificationModuleSpec
import kotlinx.coroutines.delay

class VerificationModuleImpl : HybridVerificationModuleSpec {
    override fun multiply(a: Double, b: Double): Double {
        return a * b
    }

    override fun ping(message: String): String {
        return "Pong: $message"
    }

    override suspend fun pingAsync(message: String): String {
        delay(500)
        return "Async Pong: $message"
    }

    override fun throwError(message: String) {
        throw RuntimeException(message)
    }

    override fun processFloats(inputs: java.nio.ByteBuffer): nitro.verification_module.FloatBuffer {
        inputs.order(java.nio.ByteOrder.nativeOrder())
        val floatBuf = inputs.asFloatBuffer()
        val size = floatBuf.remaining()
        val result = FloatArray(size) { floatBuf.get(it) * 2f }
        
        val outBuf = java.nio.ByteBuffer.allocateDirect(size * 4).order(java.nio.ByteOrder.nativeOrder())
        outBuf.asFloatBuffer().put(result)
        return nitro.verification_module.FloatBuffer(outBuf, size.toLong())
    }
}
