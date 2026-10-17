import 'dart:math';

/// Generates time-ordered RFC 9562 UUIDv7 strings.
/// ponytail: millisecond timestamp + 74 random bits; upgrade to sub-millisecond monoseq if generating >4096 IDs/ms per isolate.
class UuidV7 {
  static final Random _rng = Random.secure();
  static int _lastMillis = 0;
  static int _seq = 0;

  static String generate() {
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now <= _lastMillis) {
      _seq++;
      if (_seq > 0x0FFF) {
        _lastMillis++;
        _seq = 0;
      }
      now = _lastMillis;
    } else {
      _lastMillis = now;
      _seq = 0;
    }

    final randA = _seq; // 12 bits
    final randB = _rng.nextInt(0x3FFFFFFF); // 30 bits
    final randC = _rng.nextInt(0x3FFFFFFF); // 30 bits

    // 48-bit timestamp
    final timeHex = now.toRadixString(16).padLeft(12, '0');
    final timeHigh = timeHex.substring(0, 8);
    final timeMid = timeHex.substring(8, 12);

    // 4-bit ver (7) + 12-bit randA
    final verRandA = '7${randA.toRadixString(16).padLeft(3, '0')}';

    // 2-bit var (10) + 14 bits from randB
    final varRandB = ((0x8000 | (randB >> 16 & 0x3FFF))).toRadixString(16).padLeft(4, '0');

    // Remaining random bits
    final randLow = (((randB & 0xFFFF) << 16) | (randC & 0xFFFF)).toRadixString(16).padLeft(8, '0') +
        ((randC >> 16) & 0xFFFF).toRadixString(16).padLeft(4, '0');

    return '$timeHigh-$timeMid-$verRandA-$varRandB-$randLow';
  }
}
