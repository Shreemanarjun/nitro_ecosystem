#include "benchmark_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>

#include "../src/nitro_workload.h"

namespace benchmark {

// static
void BenchmarkPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "dev.shreeman.benchmark/method_channel",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<BenchmarkPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

BenchmarkPlugin::BenchmarkPlugin() {}

BenchmarkPlugin::~BenchmarkPlugin() {}

void BenchmarkPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "add") {
    const auto *args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    double a = 0.0, b = 0.0;
    if (args) {
      const auto ita = args->find(flutter::EncodableValue("a"));
      const auto itb = args->find(flutter::EncodableValue("b"));
      if (ita != args->end()) {
        if (const auto *v = std::get_if<double>(&ita->second)) a = *v;
      }
      if (itb != args->end()) {
        if (const auto *v = std::get_if<double>(&itb->second)) b = *v;
      }
    }
    result->Success(flutter::EncodableValue(a + b));
  } else if (method_call.method_name() == "sendLargeBuffer") {
    const auto *buffer =
        std::get_if<std::vector<uint8_t>>(method_call.arguments());
    if (!buffer) {
      result->Error("ERR", "Invalid buffer");
      return;
    }
    // 4 KiB stride walk — touch the copied memory so the transfer is real.
    volatile uint8_t sum = 0;
    for (size_t i = 0; i < buffer->size(); i += 4096) {
      sum = static_cast<uint8_t>(sum + (*buffer)[i]);
    }
    (void)sum;
    result->Success(
        flutter::EncodableValue(static_cast<int64_t>(buffer->size())));
  } else if (method_call.method_name() == "hashBuffer") {
    // Reference workload: FNV-1a 64-bit — literally the same C routine the
    // raw-FFI and Nitro tiers call (src/nitro_workload.h).
    const auto *args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    const std::vector<uint8_t> *data = nullptr;
    int64_t rounds = 1;
    if (args) {
      const auto itd = args->find(flutter::EncodableValue("data"));
      const auto itr = args->find(flutter::EncodableValue("rounds"));
      if (itd != args->end()) {
        data = std::get_if<std::vector<uint8_t>>(&itd->second);
      }
      if (itr != args->end()) {
        if (const auto *v = std::get_if<int32_t>(&itr->second)) rounds = *v;
        if (const auto *v = std::get_if<int64_t>(&itr->second)) rounds = *v;
      }
    }
    const uint64_t hash = nitro_bench_fnv1a(
        data ? data->data() : nullptr,
        data ? static_cast<int64_t>(data->size()) : 0, rounds);
    result->Success(flutter::EncodableValue(static_cast<int64_t>(hash)));
  } else {
    result->NotImplemented();
  }
}

}  // namespace benchmark
