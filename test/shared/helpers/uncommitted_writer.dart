import 'dart:async';
import 'dart:io';
import 'package:orbit_sync/orbit_sync.dart';

void main(List<String> args) async {
  if (args.isEmpty) exit(1);
  final dbPath = args[0];

  final storage = await SyncStorage.open(path: dbPath);
  await storage.registerEntityTable('items', {'name': 'TEXT'});

  // Start write transaction that uncommittedly inserts data and hangs
  storage.db.writeTransaction((tx) async {
    await tx.execute(
        "INSERT INTO items (id, version, updated_at, expires_at, data_json) VALUES ('crash-item', 1, 1000, 0, '{\"name\":\"Half-baked Data\"}')");
    await tx.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, created_at, status) VALUES ('crash-mut', 'items', 'crash-item', 'upsert', 1000, 'pending')");

    // Signal parent that uncommitted writes are pending in SQLite buffer/WAL
    stdout.writeln('WRITE_IN_PROGRESS');
    await stdout.flush();

    // Block forever awaiting SIGKILL from OS
    await Completer<void>().future;
  });
}
