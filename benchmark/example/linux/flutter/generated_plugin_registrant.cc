//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <benchmark/benchmark_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) benchmark_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "BenchmarkPlugin");
  benchmark_plugin_register_with_registrar(benchmark_registrar);
}
