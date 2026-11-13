import 'dart:async';
import 'sync_summary.dart';

/// Scoped handle for a running synchronization operation.
///
/// Implements [Future<SyncSummary>] so callers can directly `await` it:
/// ```dart
/// final summary = await orbit.sync(entity: 'orders');
/// ```
class SyncJob implements Future<SyncSummary> {
  final String syncId;
  final Completer<SyncSummary> _completer;

  SyncJob({
    required this.syncId,
    Completer<SyncSummary>? completer,
  }) : _completer = completer ?? Completer<SyncSummary>();

  void complete(SyncSummary summary) {
    if (!_completer.isCompleted) {
      _completer.complete(summary);
    }
  }

  void completeError(Object error, [StackTrace? stackTrace]) {
    if (!_completer.isCompleted) {
      _completer.completeError(error, stackTrace);
    }
  }

  @override
  Stream<SyncSummary> asStream() => _completer.future.asStream();

  @override
  Future<SyncSummary> catchError(Function onError, {bool Function(Object error)? test}) =>
      _completer.future.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(SyncSummary value) onValue, {Function? onError}) =>
      _completer.future.then(onValue, onError: onError);

  @override
  Future<SyncSummary> timeout(Duration timeLimit, {FutureOr<SyncSummary> Function()? onTimeout}) =>
      _completer.future.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<SyncSummary> whenComplete(FutureOr<void> Function() action) =>
      _completer.future.whenComplete(action);
}
