part of '../spec_validator.dart';

// Rules for streams: item types and backpressure modes.

extension _StreamRules on _Rules {
  void streams() {
    // ── Streams ────────────────────────────────────────────────────────────
    for (final stream in spec.streams) {
      final streamNullableMap = _nullableMapValueIssue(stream.itemType, '${spec.dartClassName}.${stream.dartName} stream item');
      if (streamNullableMap != null) issues.add(streamNullableMap);
      // E009 removed: nullable stream item types are now fully supported.
      // Native posts Dart_CObject_kNull when the item is null; Dart's unpack
      // lambda checks `message == null` before decoding the value.
      // Supported nullable types: int?, double?, bool?, String?, @HybridEnum?,
      // @HybridStruct?, @HybridRecord?  (TypedData? remains unsupported — E012).

      final iName = bareTypeName(stream.itemType.name);
      if (!_isKnownType(iName, knownTypes) && !_isKnownType(stream.itemType.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E011',
            message: '${spec.dartClassName}.${stream.dartName} — unknown stream item type "$iName".',
            hint:
                'If "$iName" is a struct, annotate it with @HybridStruct. '
                'If it is an enum, annotate it with @HybridEnum. '
                'If it is a complex/nested type, annotate it with @HybridRecord.',
          ),
        );
      }

      if (!seenSymbols.add(stream.registerSymbol)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'DUPLICATE_SYMBOL',
            message: '${spec.dartClassName}: duplicate C symbol "${stream.registerSymbol}".',
          ),
        );
      }

      // W004: Stream<T> declared without @NitroStream annotation — backpressure
      // defaults silently to dropLatest which may not be the intended behaviour.
      if (!stream.isAnnotated) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W004',
            message:
                '${spec.dartClassName}.${stream.dartName} — Stream<T> declared without @NitroStream annotation. '
                'Backpressure defaults to dropLatest silently.',
            hint:
                'Add @NitroStream(backpressure: Backpressure.dropLatest) (or your preferred mode) '
                'to explicitly configure stream backpressure.',
          ),
        );
      }

      // Backpressure.batch: every item kind coalesces through the bridge batcher
      // (E005 used to restrict the item type; it no longer applies).
      if (stream.isBatch) {
        // E006: batchMaxSize must be a positive integer.
        if (stream.batchMaxSize <= 0) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E006',
              message: '${spec.dartClassName}.${stream.dartName} — batchMaxSize must be > 0, got ${stream.batchMaxSize}.',
              hint: 'Set batchMaxSize to a positive integer (e.g. 64).',
            ),
          );
        }

        // W005: Warn when @HybridRecord appears as a Map value type — Kotlin generates
        // Any? for the map value, so runtime type checks are not enforced on Android.
        // The map works but is not type-safe in the JVM layer.
      }

      // W005: Map<String, @HybridRecord> on Android generates Any? for values.
      // The binary map encoder/decoder is typed only on the Dart side; Kotlin passes Any?.
      if (iName == 'Map' && stream.itemType.isMap) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W005',
            message:
                '${spec.dartClassName}.${stream.dartName} — Map<String, @HybridRecord> stream item type is not type-safe on Android. '
                'Kotlin generates Any? for the map value.',
            hint: 'This works at runtime but bypasses Kotlin type-checking. Consider using @HybridRecord directly.',
          ),
        );
      }
    }
  }
}
