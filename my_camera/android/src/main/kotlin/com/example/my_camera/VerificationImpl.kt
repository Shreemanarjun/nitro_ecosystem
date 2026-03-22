package com.example.my_camera

import nitro.verification_module.HybridVerificationModuleSpec
import kotlinx.coroutines.delay

class VerificationImpl : HybridVerificationModuleSpec {
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
}
