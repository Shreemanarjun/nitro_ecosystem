import 'package:flutter/material.dart';

import '../../../harness/bench_harness.dart';

/// A group of related benchmark cases shown together with a shared baseline
/// so tiers can be compared apples-to-apples. Mirrors the categories in
/// `benchmark/RESULTS.md`.
class BenchCategory {
  final String title;
  final String subtitle;

  /// Case ids in display order (top → bottom).
  final List<String> caseIds;

  /// The reference tier every other row is expressed relative to.
  final String baselineId;

  /// Throughput categories rank higher-is-better and read MB/s; latency
  /// categories rank lower-is-better and read µs.
  final bool higherIsBetter;

  const BenchCategory({
    required this.title,
    required this.subtitle,
    required this.caseIds,
    required this.baselineId,
    this.higherIsBetter = false,
  });

  String get unit => higherIsBetter ? 'MB/s' : 'µs';

  /// The comparable value for [r] in this category's unit (median µs for
  /// latency, MB/s for throughput), or null when the case was skipped.
  double? valueOf(BenchResult r) =>
      higherIsBetter ? r.mbPerSec : r.stats?.medianUs;
}

/// The five categories, in the order they appear on the Compare screen.
const List<BenchCategory> kBenchCategories = [
  BenchCategory(
    title: 'Sync call latency',
    subtitle: 'Per-call bridge overhead — lower is better',
    baselineId: 'raw_ffi_add',
    caseIds: [
      'raw_ffi_add',
      'nitro_leaf_add',
      'nitro_cpp_add',
      'nitro_platform_add',
      'nitro_struct_roundtrip',
      'nitro_string_roundtrip',
      'method_channel_add',
    ],
  ),
  BenchCategory(
    title: 'Workload A · FNV-1a hash',
    subtitle: '1 KiB × 16 rounds — payload crosses the bridge each call',
    baselineId: 'raw_ffi_hash',
    caseIds: [
      'raw_ffi_hash',
      'nitro_cpp_hash',
      'nitro_platform_hash',
      'channel_hash',
    ],
  ),
  BenchCategory(
    title: 'Workload B · Sieve of Eratosthenes',
    subtitle: 'limit 4096 — pure language compute, ~zero marshalling',
    baselineId: 'raw_ffi_sieve',
    caseIds: [
      'dart_sieve',
      'raw_ffi_sieve',
      'nitro_cpp_sieve',
      'nitro_platform_sieve',
      'channel_sieve',
    ],
  ),
  BenchCategory(
    title: 'Async record round-trip',
    subtitle: 'Future returning a @HybridRecord — lower is better',
    baselineId: 'nitro_native_async_record',
    caseIds: ['nitro_native_async_record', 'nitro_async_record'],
  ),
  BenchCategory(
    title: 'Buffer throughput · 16 MiB',
    subtitle: 'Zero-copy vs channel copy — higher is better',
    baselineId: 'raw_ffi_buffer',
    higherIsBetter: true,
    caseIds: [
      'nitro_buffer_pinned',
      'raw_ffi_buffer',
      'channel_buffer',
    ],
  ),
];

/// Stable color per tier, keyed off the case-id prefix (the harness ids are
/// not [BridgeType]s, so we map by keyword).
Color colorForCaseId(String id) {
  if (id.startsWith('raw_ffi')) return Colors.green;
  if (id.startsWith('dart_')) return Colors.blueGrey;
  if (id.contains('platform')) return Colors.deepPurpleAccent;
  if (id.startsWith('method_channel') || id.startsWith('channel')) {
    return Colors.redAccent;
  }
  if (id.contains('leaf')) return Colors.orange;
  if (id.contains('string')) return Colors.tealAccent;
  if (id.contains('struct') || id.contains('buffer_pinned')) {
    return Colors.cyanAccent;
  }
  if (id.contains('native_async')) return Colors.lightBlueAccent;
  return Colors.cyan; // nitro C++ default
}
