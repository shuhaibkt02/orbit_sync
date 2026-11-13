/// Thrown when an active auth token claim does not match the database session owner.
class AuthSubjectMismatchException implements Exception {
  final String expectedOwner;
  final String actualSubject;

  const AuthSubjectMismatchException({
    required this.expectedOwner,
    required this.actualSubject,
  });

  @override
  String toString() =>
      'AuthSubjectMismatchException: Database owned by "$expectedOwner" but token subject is "$actualSubject". Sync halted to prevent audit contamination.';
}

/// Thrown when operations are invoked on an OrbitClient that has been closed.
class ClientClosedException implements Exception {
  final String operation;

  const ClientClosedException([this.operation = 'Operation']);

  @override
  String toString() =>
      'ClientClosedException: Cannot execute $operation because client is closed.';
}
