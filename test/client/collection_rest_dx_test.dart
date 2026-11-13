import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

class Address {
  final String city;
  const Address({required this.city});
  factory Address.fromJson(Map<String, dynamic> json) =>
      Address(city: json['city'] as String);
  Map<String, dynamic> toJson() => {'city': city};
}

class UserProfile {
  final String id;
  final String name;
  final Address address;
  final List<String> tags;

  const UserProfile(
      {required this.id,
      required this.name,
      required this.address,
      required this.tags});

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        address: Address.fromJson(json['address'] as Map<String, dynamic>),
        tags: (json['tags'] as List).cast<String>(),
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'address': address.toJson(), 'tags': tags};
}

void main() {
  late String dbPath;
  late OrbitClient client;

  setUp(() async {
    dbPath =
        '${Directory.systemTemp.path}/test_dx_${DateTime.now().microsecondsSinceEpoch}.db';
    client = await OrbitClient.initialize(
        databasePath: dbPath, baseUrl: 'https://api.acme.corp/v1');
  });

  tearDown(() async {
    await client.close();
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  test('collection auto-wires endpoint, HTTP methods, and outbox metadata',
      () async {
    final users = client.collection<UserProfile>(
      name: 'users',
      endpoint: '/users',
      createMethod: HttpMethod.post,
      updateMethod: HttpMethod.patch,
      deleteMethod: HttpMethod.delete,
      fromJson: UserProfile.fromJson,
      toJson: (u) => u.toJson(),
    );

    final u1 = UserProfile(
        id: 'usr-1',
        name: 'Alice',
        address: const Address(city: 'Berlin'),
        tags: ['core']);
    await users.save(u1);

    final createOutbox = await client.query(
        "SELECT endpoint_url, http_method FROM _sync_outbox WHERE entity_id = 'usr-1'");
    expect(createOutbox.first['endpoint_url'],
        equals('https://api.acme.corp/v1/users'));
    expect(createOutbox.first['http_method'], equals('POST'));

    await users.save(UserProfile(
        id: 'usr-1',
        name: 'Alice C',
        address: const Address(city: 'Berlin'),
        tags: ['lead']));
    final updateOutbox = await client.query(
        "SELECT endpoint_url, http_method FROM _sync_outbox WHERE entity_id = 'usr-1' ORDER BY sequence_id DESC");
    expect(updateOutbox.first['endpoint_url'],
        equals('https://api.acme.corp/v1/users/usr-1'));
    expect(updateOutbox.first['http_method'], equals('PATCH'));

    await users.delete('usr-1');
    final deleteOutbox = await client.query(
        "SELECT endpoint_url, http_method FROM _sync_outbox WHERE entity_id = 'usr-1' AND op = 'delete'");
    expect(deleteOutbox.first['endpoint_url'],
        equals('https://api.acme.corp/v1/users/usr-1'));
    expect(deleteOutbox.first['http_method'], equals('DELETE'));
  });

  test(
      'pathParams and null-safe queryParams interpolate correctly without ? on empty',
      () async {
    final users = client.collection<UserProfile>(
      name: 'org_users',
      createEndpoint: '/orgs/:orgId/users',
      fromJson: UserProfile.fromJson,
      toJson: (u) => u.toJson(),
    );

    await users.save(
      UserProfile(
          id: 'usr-org',
          name: 'Bob',
          address: const Address(city: 'Tokyo'),
          tags: ['dev']),
      pathParams: {'orgId': 'org-42'},
      queryParams: {'active': true, 'nullFilter': null},
    );

    final outbox = await client.query(
        "SELECT endpoint_url FROM _sync_outbox WHERE entity_id = 'usr-org'");
    expect(outbox.first['endpoint_url'],
        equals('https://api.acme.corp/v1/orgs/org-42/users?active=true'));
  });

  test('No Sync Illusion: throws StateError if endpoint is not configured',
      () async {
    final readOnlyUsers = client.collection<UserProfile>(
      name: 'ro_users',
      listEndpoint: '/users', // Only list is configured!
      fromJson: UserProfile.fromJson,
      toJson: (u) => u.toJson(),
    );

    expect(
      () => readOnlyUsers.save(UserProfile(
          id: '1', name: 'N', address: const Address(city: 'C'), tags: [])),
      throwsStateError,
    );
    expect(() => readOnlyUsers.delete('1'), throwsStateError);
  });

  test('auto-deserialization safely decodes nested maps and lists', () async {
    final users = client.collection<UserProfile>(
        name: 'n_users',
        endpoint: '/users',
        fromJson: UserProfile.fromJson,
        toJson: (u) => u.toJson());
    await users.save(UserProfile(
        id: 'u-nest',
        name: 'Bob',
        address: const Address(city: 'Tokyo'),
        tags: ['eng']));

    final retrieved = await users.get('u-nest');
    expect(retrieved!.address.city, equals('Tokyo'));
    expect(retrieved.tags, equals(['eng']));
  });

  test(
      'watchRecords does not produce duplicate rows on multiple pending mutations',
      () async {
    final users = client.collection<UserProfile>(
        name: 'd_users',
        endpoint: '/users',
        fromJson: UserProfile.fromJson,
        toJson: (u) => u.toJson());
    await users.save(UserProfile(
        id: 'u-dup',
        name: 'Charlie',
        address: const Address(city: 'London'),
        tags: []));
    await users.save(UserProfile(
        id: 'u-dup',
        name: 'Charlie B',
        address: const Address(city: 'London'),
        tags: ['sr']));

    final records = await users.watchRecords().first;
    expect(records.length, equals(1));
    expect(records.first.data.name, equals('Charlie B'));
  });

  test('initialization validates baseUrl scheme and host', () async {
    expect(() => OrbitClient.initialize(databasePath: 'test.db', baseUrl: ''),
        throwsArgumentError);
    expect(
        () => OrbitClient.initialize(
            databasePath: 'test.db', baseUrl: 'invalid-url'),
        throwsArgumentError);
  });
}
