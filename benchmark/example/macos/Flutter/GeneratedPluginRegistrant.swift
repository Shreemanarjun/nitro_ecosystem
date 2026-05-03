//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import benchmark
import package_info_plus
import wakelock_plus

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  BenchmarkPlugin.register(with: registry.registrar(forPlugin: "BenchmarkPlugin"))
  FPPPackageInfoPlusPlugin.register(with: registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
  WakelockPlusMacosPlugin.register(with: registry.registrar(forPlugin: "WakelockPlusMacosPlugin"))
}
