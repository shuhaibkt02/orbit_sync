/// Contract managing multi-user session filesystem sandboxing,
/// token claim validation, and guest-to-user migration.
abstract class ISessionManager {
  /// Computes a deterministic 16-character SHA-256 session path.
  String computeSessionPath(String appDir, String userId);

  /// Validates that an active JWT token's `sub` or `user_id` claim
  /// matches the database session owner to prevent audit contamination.
  Future<void> assertTokenSubject({
    required String? token,
    required String expectedUserId,
  });

  /// Atomically transfers unpushed guest outbox records and domain data
  /// into the newly authenticated user's database.
  Future<int> mergeGuestSession({
    required String guestDatabasePath,
    required String targetDatabasePath,
  });
}
