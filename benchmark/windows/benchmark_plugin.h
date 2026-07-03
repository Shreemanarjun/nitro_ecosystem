#ifndef FLUTTER_PLUGIN_BENCHMARK_PLUGIN_H_
#define FLUTTER_PLUGIN_BENCHMARK_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace benchmark {

class BenchmarkPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  BenchmarkPlugin();
  virtual ~BenchmarkPlugin();

  // Disallow copy and assign.
  BenchmarkPlugin(const BenchmarkPlugin &) = delete;
  BenchmarkPlugin &operator=(const BenchmarkPlugin &) = delete;

  // MethodChannel baseline for the cross-bridge benchmark suite — same
  // channel name and methods ('add', 'sendLargeBuffer') as the Kotlin,
  // Swift, and GTK implementations.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace benchmark

#endif  // FLUTTER_PLUGIN_BENCHMARK_PLUGIN_H_
