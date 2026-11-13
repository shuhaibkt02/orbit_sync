import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/sync_server.dart';

void main() async {
  stdout.writeln('=== Running FakeSyncServer Acceptance Test Suite ===');
  final server = await FakeSyncServer.start(port: 0);
  final client = HttpClient();

  Future<(int, Map<String, dynamic>)> request(
    String method,
    String path, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('${server.baseUrl}$path');
    final req = await client.openUrl(method, uri);
    req.headers.contentType = ContentType.json;
    if (headers != null) {
      headers.forEach((k, v) => req.headers.set(k, v));
    }
    if (body != null) {
      req.add(utf8.encode(jsonEncode(body)));
    }
    final resp = await req.close();
    final respBody = await utf8.decoder.bind(resp).join();
    final json = respBody.isNotEmpty ? (jsonDecode(respBody) as Map<String, dynamic>) : <String, dynamic>{};
    return (resp.statusCode, json);
  }

  try {
    // Spec 1: Idempotent Deduplication (Challenge 2)
    stdout.writeln('\n[Spec 1] Idempotent Deduplication:');
    final key1 = 'idem-uuid-001';
    final batch1 = [
      {'entity': 'task', 'id': 't-1', 'op': 'upsert', 'payload': {'title': 'Task 1'}}
    ];

    final (st1, res1) = await request('POST', '/sync/push', body: batch1, headers: {'Idempotency-Key': key1});
    assert(st1 == 200 && res1['status'] == 'ok' && res1['deduplicated'] == false);
    assert(res1['server_cursor'] == 1, 'Expected cursor 1, got ${res1['server_cursor']}');

    // Resend same push with same idempotency key
    final (st2, res2) = await request('POST', '/sync/push', body: batch1, headers: {'Idempotency-Key': key1});
    assert(st2 == 200 && res2['deduplicated'] == true);
    assert(res2['server_cursor'] == 1, 'Cursor should not increment on deduplicated push');

    final (_, pullRes) = await request('GET', '/sync/pull?since=0');
    final changes = (pullRes['changes'] as List);
    assert(changes.length == 1, 'Expected exactly 1 change, found ${changes.length}');
    stdout.writeln('  -> Passed: retry with identical Idempotency-Key returned cached response with 0 duplicates.');

    // Spec 2: Monotonic Change Feed & Pagination (Challenge 4)
    stdout.writeln('\n[Spec 2] Monotonic Change Feed & Pagination:');
    for (var i = 2; i <= 6; i++) {
      await request('POST', '/sync/push',
          body: [
            {'entity': 'task', 'id': 't-$i', 'op': 'upsert', 'payload': {'title': 'Task $i'}}
          ],
          headers: {'Idempotency-Key': 'idem-t-$i'});
    }

    // Total 6 tasks (cursors 1..6). Pull with limit=2
    final (p1St, p1) = await request('GET', '/sync/pull?since=0&limit=2');
    assert(p1St == 200);
    assert((p1['changes'] as List).length == 2 && p1['has_more'] == true);
    assert(p1['next_cursor'] == 2);
    assert((p1['changes'] as List).map((c) => c['id']).toList().join(',') == 't-1,t-2');

    // Page 2
    final (p2St, p2) = await request('GET', '/sync/pull?since=${p1['next_cursor']}&limit=2');
    assert(p2St == 200);
    assert((p2['changes'] as List).length == 2 && p2['has_more'] == true);
    assert(p2['next_cursor'] == 4);
    assert((p2['changes'] as List).map((c) => c['id']).toList().join(',') == 't-3,t-4');

    // Page 3
    final (p3St, p3) = await request('GET', '/sync/pull?since=${p2['next_cursor']}&limit=2');
    assert(p3St == 200);
    assert((p3['changes'] as List).length == 2 && p3['has_more'] == false);
    assert(p3['next_cursor'] == 6);
    assert((p3['changes'] as List).map((c) => c['id']).toList().join(',') == 't-5,t-6');
    stdout.writeln('  -> Passed: monotonic change feed correctly paginates across cursors with zero skips.');

    // Spec 3: Tombstone vs Scope Eviction (Challenge 5)
    stdout.writeln('\n[Spec 3] Tombstone vs Scope Eviction:');
    await request('POST', '/sync/push',
        body: [
          {'entity': 'task', 'id': 't-1', 'op': 'delete'}
        ],
        headers: {'Idempotency-Key': 'del-t-1'});

    await request('POST', '/sync/push',
        body: [
          {'entity': 'task', 'id': 'scoped-1', 'op': 'upsert', 'payload': {'title': 'Dept A', 'dept': 'finance'}},
          {'entity': 'task', 'id': 'scoped-2', 'op': 'upsert', 'payload': {'title': 'Dept B', 'dept': 'eng'}},
        ],
        headers: {'Idempotency-Key': 'scope-test'});

    // Pull delete
    final (_, pullDel) = await request('GET', '/sync/pull?since=6');
    final delList = (pullDel['changes'] as List).cast<Map<String, dynamic>>();
    final delChange = delList.firstWhere((c) => c['id'] == 't-1');
    assert(delChange['_deleted'] == true, 'Expected _deleted: true for delete mutation');

    // Pull scoped
    final scopeParam = Uri.encodeComponent(jsonEncode({'dept': 'finance'}));
    final (_, pullScoped) = await request('GET', '/sync/pull?since=6&scope=$scopeParam');
    final scopedList = (pullScoped['changes'] as List).cast<Map<String, dynamic>>();
    final s1 = scopedList.firstWhere((c) => c['id'] == 'scoped-1');
    final s2 = scopedList.firstWhere((c) => c['id'] == 'scoped-2');
    assert(s1['left_scope'] != true);
    assert(s2['left_scope'] == true && s2['data'] == null);
    stdout.writeln('  -> Passed: _deleted: true emitted for tombstones and left_scope: true for filter evictions.');

    // Spec 4: Chaos Injection (Challenges 2, 4, 6, 9)
    stdout.writeln('\n[Spec 4] Chaos Injection:');

    // 4a: 409 Conflict
    final (stConf, resConf) = await request('POST', '/sync/push?chaos=conflict', body: []);
    assert(stConf == 409 && resConf['error'] == 'conflict');
    stdout.writeln('  -> Passed: ?chaos=conflict returned HTTP 409.');

    // 4b: 422 Validation Error RFC 9457
    final (stVal, resVal) = await request('POST', '/sync/push?chaos=validation_error', body: []);
    assert(stVal == 422 && resVal.containsKey('invalid_params'));
    stdout.writeln('  -> Passed: ?chaos=validation_error returned HTTP 422 RFC 9457.');

    // 4c: 410 Expired Cursor
    final (stExp, resExp) = await request('GET', '/sync/pull?since=1&chaos=expired_cursor');
    assert(stExp == 410 && resExp['error'] == 'cursor_expired');
    stdout.writeln('  -> Passed: ?chaos=expired_cursor returned HTTP 410.');

    // 4d: In-Flight Socket Drop (Two Generals' Problem)
    stdout.writeln('  -> Testing ?chaos=drop_before_response (Two Generals):');
    final dropIdemKey = 'drop-uuid-999';
    final dropBody = [
      {'entity': 'task', 'id': 't-drop-1', 'op': 'upsert', 'payload': {'title': 'In Flight Drop'}}
    ];

    bool dropOccurred = false;
    try {
      final reqDrop = await client.openUrl('POST', Uri.parse('${server.baseUrl}/sync/push?chaos=drop_before_response'));
      reqDrop.headers.contentType = ContentType.json;
      reqDrop.headers.set('Idempotency-Key', dropIdemKey);
      reqDrop.add(utf8.encode(jsonEncode(dropBody)));
      final resp = await reqDrop.close();
      await utf8.decoder.bind(resp).join();
    } catch (_) {
      dropOccurred = true;
    }
    assert(dropOccurred, 'Expected connection to be abruptly destroyed by server');

    // Retry with SAME Idempotency-Key
    final (stRetry, resRetry) = await request('POST', '/sync/push', body: dropBody, headers: {'Idempotency-Key': dropIdemKey});
    assert(stRetry == 200);
    assert(resRetry['deduplicated'] == true, 'Retried push must be recognized as deduplicated');

    // Confirm exactly one record exists
    final (_, pullAll) = await request('GET', '/sync/pull?since=0&limit=100');
    final dropRecords = (pullAll['changes'] as List).where((c) => c['id'] == 't-drop-1').toList();
    assert(dropRecords.length == 1, 'Expected 1 record, found ${dropRecords.length}');
    stdout.writeln('  -> Passed: Two Generals in-flight drop committed, retried, and deduplicated seamlessly.');

    stdout.writeln('\nALL ISSUE 01 ACCEPTANCE CRITERIA PASSED (100% SUCCESS)');
  } finally {
    client.close();
    await server.stop();
  }
}
