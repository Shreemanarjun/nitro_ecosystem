#pragma once
#include "../lib/src/generated/cpp/math.g.hpp"

namespace nitro {

/**
 * Concrete C++ implementation of MathModule.
 *
 * This class implements nitro::HybridMathModule, which is auto-generated
 * from lib/src/math.native.dart when NativeImpl.cpp is configured.
 *
 * Register it at app startup via:
 *   nitro::MathModuleRegistry::registerImpl(std::make_shared<nitro::MathImpl>());
 */
class MathImpl : public HybridMathModule {
public:
  double add(double a, double b) override { return a + b; }

  double subtract(double a, double b) override { return a - b; }
};

} // namespace nitro
