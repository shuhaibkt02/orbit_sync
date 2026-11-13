import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/client/services/session_manager.dart';

void main() {
  late Directory tempDir;
  const sessionManager = SessionManager();

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('layer5_challenge5_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 5 Facade: Challenge 5 Multi-User Session Sandboxing & Token Pinning', () {
    test('computeSessionPath produces deterministic 16-char SHA-256 sandboxed paths', () {
      final path1 = sessionManager.computeSessionPath(tempDir.path, 'user_alice@example.com');
      final path2 = sessionManager.computeSessionPath(tempDir.path, 'user_alice@example.com');
      final path3 = sessionManager.computeSessionPath(tempDir.path, 'user_bob@example.com');

      expect(path1, equals(path2));
      expect(path1, isNot(equals(path3)));
      expect(path1, contains('/orbit_sessions/'));
    });

    test('assertTokenSubject throws AuthSubjectMismatchException when JWT sub claim mismatches', () async {
      // Create fake JWT with sub = user_alice
      final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256'})));
      final payloadAlice = base64Url.encode(utf8.encode(jsonEncode({'sub': 'user_alice'})));
      final fakeJwt = '$header.$payloadAlice.fakeSignature';

      // Matches Alice -> no exception
      await expectLater(
        sessionManager.assertTokenSubject(token: fakeJwt, expectedUserId: 'user_alice'),
        completes,
      );

      // Mismatches Bob -> throws AuthSubjectMismatchException
      expect(
        () => sessionManager.assertTokenSubject(token: fakeJwt, expectedUserId: 'user_bob'),
        throwsA(isA<AuthSubjectMismatchException>()),
      );
    });

    test('mergeGuestSession transfers unpushed guest mutations into target database', () async {
      final guestPath = '${tempDir.path}/guest.db';
      final targetPath = '${tempDir.path}/user.db';

      final guestClient = await OrbitClient.initialize(databasePath: guestPath);
      await guestClient.registerTable('cart_items', {'item': 'TEXT'});
      await guestClient.store('cart_items', {'item': 'Offline Guest Item'});
      await guestClient.close();

      // Merge guest session into authenticated user session
      final count = await sessionManager.mergeGuestSession(
        guestDatabasePath: guestPath,
        targetDatabasePath: targetPath,
      );
      expect(count, equals(1));

      // Assert target user database now has the unpushed item
      final userClient = await OrbitClient.initialize(databasePath: targetPath);
      final pending = await userClient.query("SELECT * FROM _sync_outbox WHERE status = 'pending'");
      expect(pending.length, equals(1));
      expect(pending.first['entity_name'], equals('cart_items'));

      await userClient.close();
    });
  });
}
