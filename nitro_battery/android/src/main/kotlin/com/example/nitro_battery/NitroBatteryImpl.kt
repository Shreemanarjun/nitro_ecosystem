package com.example.nitro_battery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import nitro.nitro_battery_module.BatteryInfo
import nitro.nitro_battery_module.ChargingState
import nitro.nitro_battery_module.HybridNitroBatterySpec

class NitroBatteryImpl(private val context: Context) : HybridNitroBatterySpec {

    // ── Synchronous ──────────────────────────────────────────────────────────

    override fun getBatteryLevel(): Long {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        return bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).toLong()
    }

    override fun isCharging(): Boolean {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
               status == BatteryManager.BATTERY_STATUS_FULL
    }

    override fun getChargingState(): ChargingState {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return when (intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
            BatteryManager.BATTERY_STATUS_CHARGING  -> ChargingState.CHARGING
            BatteryManager.BATTERY_STATUS_FULL      -> ChargingState.FULL
            BatteryManager.BATTERY_STATUS_DISCHARGING,
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> ChargingState.DISCHARGING
            else -> ChargingState.UNKNOWN
        }
    }

    // ── Async ────────────────────────────────────────────────────────────────

    override suspend fun getBatteryInfo(): BatteryInfo {
        delay(10) // yield to background thread
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager

        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).toLong()
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val state = when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING    -> ChargingState.CHARGING
            BatteryManager.BATTERY_STATUS_FULL        -> ChargingState.FULL
            BatteryManager.BATTERY_STATUS_DISCHARGING,
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> ChargingState.DISCHARGING
            else -> ChargingState.UNKNOWN
        }
        val voltageMilliV = intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0) ?: 0
        val tempTenths    = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0

        return BatteryInfo(
            level          = level,
            chargingState  = state.nativeValue,
            voltage        = voltageMilliV / 1000.0,
            temperature    = tempTenths / 10.0
        )
    }

    // ── Stream ───────────────────────────────────────────────────────────────

    override val batteryLevelChanges: Flow<Long> = callbackFlow {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).toLong()
                trySend(level)
            }
        }
        context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        awaitClose { context.unregisterReceiver(receiver) }
    }

    // ── Properties ───────────────────────────────────────────────────────────

    override var lowPowerThreshold: Long = 20L
}
