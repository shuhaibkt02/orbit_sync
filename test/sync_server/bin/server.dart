import 'dart:io';
import '../lib/sync_server.dart';

void main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final server = await FakeSyncServer.start(port: port);
  stdout.writeln('FakeSyncServer listening on http://127.0.0.1:${server.port}');
  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down FakeSyncServer...');
    await server.stop();
    exit(0);
  });
}
