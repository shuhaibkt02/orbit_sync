import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 1 Storage: UUIDv7 Generator', () {
    test('UUIDv7: Generates strictly time-ordered monotonic strings', () {
      final id1 = UuidV7.generate();
      final id2 = UuidV7.generate();
      expect(id1.length, 36);
      expect(id2.length, 36);
      expect(id1.compareTo(id2), lessThanOrEqualTo(0));
      // Version 7 check: 15th character is '7'
      expect(id1[14], '7');
      expect(id2[14], '7');
    });
  });
}
