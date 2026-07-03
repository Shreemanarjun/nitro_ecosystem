#include "include/benchmark/benchmark_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "benchmark_plugin.h"

void BenchmarkPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  benchmark::BenchmarkPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
