//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import benchmark
import nitro
import package_info_plus
import wakelock_plus

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  BenchmarkPlugin.register(with: registry.registrar(forPlugin: "BenchmarkPlugin"))
  NitroPlugin.register(with: registry.registrar(forPlugin: "NitroPlugin"))
  FPPPackageInfoPlusPlugin.register(with: registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
  WakelockPlusMacosPlugin.register(with: registry.registrar(forPlugin: "WakelockPlusMacosPlugin"))
}
