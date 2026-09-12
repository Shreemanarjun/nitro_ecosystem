import 'hybrid_exception.dart';

/// A `@NitroEntryPoint` job failed: the entry threw, or the host could not
/// start an engine for it. [message] is the thrown error's `toString()`,
/// [stackTrace] the stack captured where it was thrown (a different isolate
/// or engine, so it is carried as text), [entry] the Dart function's name.
///
/// ```dart
/// try {
///   await runSyncPhotosInBackground(album);
/// } on NitroBackgroundException catch (e) {
///   log('${e.entry} failed: ${e.message}', stackTrace: e.stackTrace);
/// }
/// ```
class NitroBackgroundException extends HybridException {
  const NitroBackgroundException({
    required this.entry,
    required super.message,
    super.stackTrace,
    this.jobId = 0,
  }) : super(name: 'NitroBackgroundError');

  /// Name of the `@NitroEntryPoint` function that failed.
  final String entry;

  /// Job id the failure belongs to (0 when unknown).
  final int jobId;

  /// True when the entry never ran because no engine could be started.
  bool get isStartFailure => message.startsWith('background engine start failed');

  /// Builds the exception from what the job table posted: `[error, stack,
  /// entry]` on failure, or anything else for an unexpected message.
  factory NitroBackgroundException.fromPost(String entry, Object? raw, {int jobId = 0}) {
    if (raw is List && raw.isNotEmpty) {
      return NitroBackgroundException(
        entry: raw.length > 2 && raw[2] is String && (raw[2] as String).isNotEmpty ? raw[2] as String : entry,
        message: '${raw[0]}',
        stackTrace: raw.length > 1 && '${raw[1]}'.isNotEmpty ? '${raw[1]}' : null,
        jobId: jobId,
      );
    }
    return NitroBackgroundException(entry: entry, message: 'background job failed: $raw', jobId: jobId);
  }

  @override
  String toString() {
    final sb = StringBuffer('NitroBackgroundException($entry): $message');
    if (stackTrace != null) sb.write('\n$stackTrace');
    return sb.toString();
  }
}
