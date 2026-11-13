/// Controllable clock for deterministic time travel, freeze, and skew testing.
class ControllableClock {
  DateTime _current;

  ControllableClock([DateTime? initial])
      : _current = initial ?? DateTime.utc(2026, 10, 17, 12, 0, 0);

  DateTime now() => _current;

  int get millisecondsSinceEpoch => _current.millisecondsSinceEpoch;

  void advance(Duration duration) {
    _current = _current.add(duration);
  }

  void rewind(Duration duration) {
    _current = _current.subtract(duration);
  }

  void setTime(DateTime time) {
    _current = time;
  }
}
