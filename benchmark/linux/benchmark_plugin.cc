#include "include/benchmark/benchmark_plugin.h"

#include <flutter_linux/flutter_linux.h>

#include <cstdint>

#include "../src/nitro_workload.h"

#define BENCHMARK_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), benchmark_plugin_get_type(), \
                              BenchmarkPlugin))

struct _BenchmarkPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(BenchmarkPlugin, benchmark_plugin, g_object_get_type())

// MethodChannel baseline for the cross-bridge benchmark suite — same channel
// name and methods ('add', 'sendLargeBuffer') as the Kotlin, Swift, and
// Windows implementations.
static void benchmark_plugin_handle_method_call(BenchmarkPlugin* self,
                                                FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "add") == 0) {
    double a = 0.0, b = 0.0;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* av = fl_value_lookup_string(args, "a");
      FlValue* bv = fl_value_lookup_string(args, "b");
      if (av != nullptr && fl_value_get_type(av) == FL_VALUE_TYPE_FLOAT) {
        a = fl_value_get_float(av);
      }
      if (bv != nullptr && fl_value_get_type(bv) == FL_VALUE_TYPE_FLOAT) {
        b = fl_value_get_float(bv);
      }
    }
    g_autoptr(FlValue) result = fl_value_new_float(a + b);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "sendLargeBuffer") == 0) {
    if (args == nullptr ||
        fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("ERR", "Invalid buffer", nullptr));
    } else {
      const uint8_t* buffer = fl_value_get_uint8_list(args);
      const size_t length = fl_value_get_length(args);
      // 4 KiB stride walk — touch the copied memory so the transfer is real.
      volatile uint8_t sum = 0;
      for (size_t i = 0; i < length; i += 4096) {
        sum = static_cast<uint8_t>(sum + buffer[i]);
      }
      (void)sum;
      g_autoptr(FlValue) result =
          fl_value_new_int(static_cast<int64_t>(length));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (strcmp(method, "hashBuffer") == 0) {
    // Reference workload: FNV-1a 64-bit — literally the same C routine the
    // raw-FFI and Nitro tiers call (src/nitro_workload.h).
    const uint8_t* data = nullptr;
    size_t length = 0;
    int64_t rounds = 1;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* dv = fl_value_lookup_string(args, "data");
      FlValue* rv = fl_value_lookup_string(args, "rounds");
      if (dv != nullptr && fl_value_get_type(dv) == FL_VALUE_TYPE_UINT8_LIST) {
        data = fl_value_get_uint8_list(dv);
        length = fl_value_get_length(dv);
      }
      if (rv != nullptr && fl_value_get_type(rv) == FL_VALUE_TYPE_INT) {
        rounds = fl_value_get_int(rv);
      }
    }
    const uint64_t hash =
        nitro_bench_fnv1a(data, static_cast<int64_t>(length), rounds);
    g_autoptr(FlValue) result = fl_value_new_int(static_cast<int64_t>(hash));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void benchmark_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(benchmark_plugin_parent_class)->dispose(object);
}

static void benchmark_plugin_class_init(BenchmarkPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = benchmark_plugin_dispose;
}

static void benchmark_plugin_init(BenchmarkPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  BenchmarkPlugin* plugin = BENCHMARK_PLUGIN(user_data);
  benchmark_plugin_handle_method_call(plugin, method_call);
}

void benchmark_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  BenchmarkPlugin* plugin = BENCHMARK_PLUGIN(
      g_object_new(benchmark_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "dev.shreeman.benchmark/method_channel", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
