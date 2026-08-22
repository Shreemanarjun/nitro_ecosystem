// C++ implementation of the WebEcho e2e module. Compiled with em++ by
// tool/build_wasm.sh; the same file would compile for any native platform.
//
// Web constraint honored throughout: no threads, no blocking — nativeAsync
// completes by posting from within the call (the Dart side still sees an
// asynchronous completion because delivery is microtask-deferred).
#include <cstring>
#include <string>

#include "../lib/src/generated/cpp/web_echo.native.g.h"

#ifdef __EMSCRIPTEN__
#include "nitro_wasm_compat.h"
#else
#include "dart_api_dl.h"
#endif

class HybridWebEchoImpl final : public HybridWebEcho {
 public:
  double addDouble(double a, double b) override { return a + b; }

  int64_t addInt(int64_t a, int64_t b) override { return a + b; }

  bool negate(bool v) override { return !v; }

  std::string concat(const std::string& a, const std::string& b) override {
    return a + b;
  }

  std::optional<int64_t> echoNullableInt(std::optional<int64_t> v) override {
    return v;
  }

  EchoLevel echoEnum(EchoLevel v) override { return v; }

  NitroCppBuffer echoBytes(const uint8_t* data, size_t data_length) override {
    // @zeroCopy: return a malloc'd copy with every byte incremented — proves
    // the payload actually crossed both ways.
    uint8_t* out = (uint8_t*)::malloc(data_length ? data_length : 1);
    for (size_t i = 0; i < data_length; i++) out[i] = (uint8_t)(data[i] + 1);
    return {out, data_length};
  }

  NitroCppBuffer echoInt32s(const int32_t* data, size_t data_length) override {
    // data_length is ELEMENTS; NitroCppBuffer.size is BYTES.
    size_t bytes = data_length * sizeof(int32_t);
    int32_t* out = (int32_t*)::malloc(bytes ? bytes : 1);
    for (size_t i = 0; i < data_length; i++) out[i] = data[i] + 1;
    return {(uint8_t*)out, bytes};
  }

  NitroCppBuffer echoStat(NitroCppBuffer v) override {
    // Decode the record payload, tweak every field, re-encode.
    NitroRecordReader r(v);
    int64_t count = r.readInt();
    double mean = r.readDouble();
    std::string label = r.readString();
    bool ok = r.readBool();

    NitroRecordWriter w;
    w.writeInt(count + 1);
    w.writeDouble(mean * 2.0);
    w.writeString(label + "!");
    w.writeBool(!ok);
    return w.toNativeBuffer();
  }

  NitroCppBuffer incrementValues(NitroCppBuffer m) override {
    // Wire (string-key map): [4B count][per entry: [4B key_len][key][1B tag][8B int64]]
    NitroRecordReader r(m);
    int32_t count = r.readInt32();
    NitroRecordWriter w;
    w.writeInt32(count);
    for (int32_t i = 0; i < count; i++) {
      std::string key = r.readString();
      int8_t tag = r.readInt8();
      int64_t value = r.readInt();
      w.writeString(key);
      w.writeInt8(tag);
      w.writeInt(value + 1);
    }
    return w.toNativeBuffer();
  }

  // List<@HybridRecord>: indexed in BOTH directions. Written the way a plugin
  // author would — with the generated readIndexedList/writeIndexedList helpers
  // rather than hand-rolled offset arithmetic.
  NitroCppBuffer echoStats(NitroCppBuffer v) override {
    NitroRecordReader r(v);
    std::vector<EchoStat> stats =
        r.readIndexedList<EchoStat>([](NitroRecordReader& rr) { return EchoStat::fromReader(rr); });

    NitroRecordWriter w;
    w.writeIndexedList<EchoStat>(stats, [](NitroRecordWriter& ww, const EchoStat& s) {
      EchoStat out = s;
      out.count = s.count + 1;
      out.mean = s.mean * 2.0;
      out.label = s.label + "!";
      out.ok = !s.ok;
      out.encodeInto(ww);
    });
    return w.toNativeBuffer();
  }

  // Primitive list: the ARGUMENT carries an offset table, the RETURN does not.
  // Reading it as a plain list (or writing the return as indexed) is exactly
  // the asymmetry this case exists to pin down.
  NitroCppBuffer echoInts(NitroCppBuffer v) override {
    NitroRecordReader r(v);
    std::vector<int64_t> values =
        r.readIndexedList<int64_t>([](NitroRecordReader& rr) { return rr.readInt(); });

    NitroRecordWriter w;
    w.writeInt32(static_cast<int32_t>(values.size()));
    for (int64_t e : values) w.writeInt(e + 10);
    return w.toNativeBuffer();
  }

  // Nullable list: an absent list arrives as an empty buffer and goes back as
  // a null pointer, which Dart decodes to null.
  NitroCppBuffer echoMaybeStats(NitroCppBuffer v) override {
    if (v.data == nullptr || v.size == 0) return { nullptr, 0 };
    NitroRecordReader r(v);
    std::vector<EchoStat> stats =
        r.readIndexedList<EchoStat>([](NitroRecordReader& rr) { return EchoStat::fromReader(rr); });
    NitroRecordWriter w;
    w.writeIndexedList<EchoStat>(stats, [](NitroRecordWriter& ww, const EchoStat& s) {
      EchoStat out = s;
      out.count = s.count + 100;
      out.encodeInto(ww);
    });
    return w.toNativeBuffer();
  }

  // Record with a NULLABLE list field — the generated codec reads/writes the
  // 1-byte null tag; `after` proves the tag was consumed at the right offset.
  NitroCppBuffer echoBag(NitroCppBuffer v) override {
    EchoBag bag = EchoBag::fromNative(v);
    if (bag.tags.has_value()) {
      for (auto& t : *bag.tags) t += 1;
    }
    bag.after += 1;
    return bag.toNativeBuffer();
  }

  void alwaysThrows() override {
    throw std::runtime_error("boom from wasm");
  }

  int64_t sumTo(int64_t n) override {
    int64_t sum = 0;
    for (int64_t i = 0; i < n; i++) sum += i;
    return sum;
  }

  void nativeAsyncEcho(int64_t value, NitroError* _nitro_err,
                       int64_t dartPort) override {
    (void)_nitro_err;
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = value * 2;
    Dart_PostCObject_DL(dartPort, &obj);
  }

  void emitTicks(int64_t count) override {
    for (int64_t i = 0; i < count; i++) {
      emit_ticks(i);
    }
  }

  int64_t get_counter() const override { return counter_; }
  void set_counter(int64_t value) override { counter_ = value; }

 private:
  int64_t counter_ = 0;
};

// Multi-instance factory registration: runs during module instantiation
// (__wasm_call_ctors), before any Dart call reaches the bridge.
namespace {
struct _Register {
  _Register() {
    web_echo_register_factory_typed(
        [](const std::string& key) -> std::shared_ptr<HybridWebEcho> {
          (void)key;
          return std::make_shared<HybridWebEchoImpl>();
        });
  }
} _register;
}  // namespace
