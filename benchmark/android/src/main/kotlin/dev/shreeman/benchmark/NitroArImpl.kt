package dev.shreeman.benchmark

import java.nio.ByteBuffer
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asSharedFlow
import nitro.nitro_ar_module.*

/// Mock implementation of HybridNitroArSpec — mirrors the Swift
/// NitroArModuleImpl stub. The nitro_ar module exists in the benchmark
/// plugin to exercise multi-spec generation, not to do real AR.
class NitroArImpl : HybridNitroArSpec {

    override fun add(a: Double, b: Double): Double = a + b

    override suspend fun getGreeting(name: String): String = "Hello, $name!"

    override fun isDepthSupported(): Boolean = false

    override fun detectPackage(rect: BoundingBox): PackageDimensions =
        PackageDimensions(
            length = 0.0, width = 0.0, height = 0.0, confidence = 0.0,
            vector3 = Vector3(0.0, 0.0, 0.0),
            quaternion = Quaternion(0.0, 0.0, 0.0, 1.0),
        )

    override fun getRawDepthMap(): RawDepthMap =
        RawDepthMap(ByteBuffer.allocateDirect(0), 0L, 0L, 0L)

    override fun estimateVolume(anchor: String): Double = 0.0

    override suspend fun checkCameraPermission(): Boolean = false

    override suspend fun requestCameraPermission(): Boolean = false

    override suspend fun startSession() {}

    override suspend fun stopSession() {}

    override suspend fun pauseSession() {}

    override suspend fun resumeSession() {}

    override fun isTracking(): Boolean = false

    override fun enableFlashlight(enable: Boolean) {}

    override fun setDetectionOptions(threshold: Double, rotation: Long, useMock: Boolean) {}

    private val _detectedPackages = MutableSharedFlow<PackageBoxes>(extraBufferCapacity = 1)
    private val _liveTrackingUpdates = MutableSharedFlow<LiveTrackingUpdate>(extraBufferCapacity = 1)

    override val detectedPackages: Flow<PackageBoxes> = _detectedPackages.asSharedFlow()
    override val liveTrackingUpdates: Flow<LiveTrackingUpdate> = _liveTrackingUpdates.asSharedFlow()
}
