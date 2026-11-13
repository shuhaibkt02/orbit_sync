import 'dart:async';

/// Stream extension providing leading-immediate debounce behavior.
///
/// Emits the very first event immediately (0ms latency for instant first-frame
/// rendering from SQLite cache), then coalesces and trailing-debounces subsequent
/// rapid events emitted by background write bursts.
extension LeadingImmediateDebounce<T> on Stream<T> {
  Stream<T> leadingImmediateDebounce(Duration duration) {
    late StreamController<T> controller;
    StreamSubscription<T>? subscription;
    Timer? debounceTimer;
    bool hasEmittedFirst = false;
    T? pendingTrailingEvent;
    bool hasPendingTrailing = false;

    controller = StreamController<T>(
      onListen: () {
        subscription = listen(
          (data) {
            if (!hasEmittedFirst) {
              hasEmittedFirst = true;
              controller.add(data);
              debounceTimer = Timer(duration, () {
                if (hasPendingTrailing) {
                  controller.add(pendingTrailingEvent as T);
                  hasPendingTrailing = false;
                  pendingTrailingEvent = null;
                }
                hasEmittedFirst = false;
              });
            } else {
              pendingTrailingEvent = data;
              hasPendingTrailing = true;
              debounceTimer?.cancel();
              debounceTimer = Timer(duration, () {
                if (hasPendingTrailing) {
                  controller.add(pendingTrailingEvent as T);
                  hasPendingTrailing = false;
                  pendingTrailingEvent = null;
                }
                hasEmittedFirst = false;
              });
            }
          },
          onError: controller.addError,
          onDone: () {
            debounceTimer?.cancel();
            if (hasPendingTrailing) {
              controller.add(pendingTrailingEvent as T);
            }
            controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        debounceTimer?.cancel();
        subscription?.cancel();
      },
    );

    return controller.stream;
  }
}
