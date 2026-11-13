typedef VoidCallback = void Function();

/// Core listener interface matching Flutter's ValueListenable contract
/// for seamless consumption in UI widgets and reactive state stores.
abstract class ValueListenable<T> {
  T get value;
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

/// Pure Dart implementation of ValueNotifier providing change notification.
class OrbitValueNotifier<T> implements ValueListenable<T> {
  T _value;
  final Set<VoidCallback> _listeners = {};
  final void Function()? onActive;
  final void Function()? onInactive;

  OrbitValueNotifier(this._value, {this.onActive, this.onInactive});

  @override
  T get value => _value;

  set value(T newValue) {
    if (_value == newValue) return;
    _value = newValue;
    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    final wasEmpty = _listeners.isEmpty;
    _listeners.add(listener);
    if (wasEmpty && _listeners.isNotEmpty) {
      onActive?.call();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      onInactive?.call();
    }
  }

  void notifyListeners() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  void dispose() {
    _listeners.clear();
    onInactive?.call();
  }
}
