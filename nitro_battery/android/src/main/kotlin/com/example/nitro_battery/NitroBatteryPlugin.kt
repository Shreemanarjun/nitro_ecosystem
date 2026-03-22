package com.example.nitro_battery

import io.flutter.embedding.engine.plugins.FlutterPlugin
import nitro.nitro_battery_module.NitroBatteryJniBridge

class NitroBatteryPlugin : FlutterPlugin {

    companion object {
        init {
            System.loadLibrary("nitro_battery")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NitroBatteryJniBridge.register(
            NitroBatteryImpl(binding.applicationContext)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
