import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Ticket 08: Binary Media Multipart Streaming (pushMultipart)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('orbit_multipart_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('1. Multipart Payload Assembly & Field Inclusion', () {
      test('assembles FormData with binary file and non-binary extraFields',
          () async {
        final filePath = '${tempDir.path}/delivery_receipt.jpg';
        final file = File(filePath);
        final dummyBytes = utf8.encode('image-binary-content-simulation-12345');
        await file.writeAsBytes(dummyBytes);

        final dio = Dio();
        FormData? capturedFormData;
        RequestOptions? capturedOptions;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedOptions = options;
              if (options.data is FormData) {
                capturedFormData = options.data as FormData;
              }
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: '{"status":"uploaded","media_id":"med-99"}',
                ),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        final response = await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/api/v1/attachments'),
          method: 'POST',
          fieldName: 'attachment',
          filePath: filePath,
          fileName: 'delivery_receipt.jpg',
          mimeType: 'image/jpeg',
          extraFields: {
            'order_id': 'ord-777',
            'notes': 'Left with receptionist',
            'attempt': 2,
            'is_signature': false,
          },
        );

        expect(response.isSuccess, isTrue);
        expect(response.statusCode, equals(200));
        expect(response.body, contains('med-99'));

        // Assert FormData structure
        expect(capturedOptions, isNotNull);
        expect(capturedFormData, isNotNull);
        final formData = capturedFormData!;

        // Assert binary file attachment
        expect(formData.files.length, equals(1));
        final fileEntry = formData.files.first;
        expect(fileEntry.key, equals('attachment'));
        expect(fileEntry.value.filename, equals('delivery_receipt.jpg'));
        expect(fileEntry.value.contentType?.mimeType, equals('image/jpeg'));
        expect(fileEntry.value.length, equals(dummyBytes.length));

        // Assert non-binary extra fields inclusion
        final fieldsMap = Map.fromEntries(
          formData.fields.map((e) => MapEntry(e.key, e.value)),
        );
        expect(fieldsMap['order_id'], equals('ord-777'));
        expect(fieldsMap['notes'], equals('Left with receptionist'));
        expect(fieldsMap['attempt'], equals('2'));
        expect(fieldsMap['is_signature'], equals('false'));

        adapter.dispose();
      });

      test(
          'sanitizes extraFields removing internal sync & offline flags (zero metadata pollution)',
          () async {
        final filePath = '${tempDir.path}/signature.png';
        final file = File(filePath);
        await file.writeAsString('fake-signature-data');

        final dio = Dio();
        FormData? capturedFormData;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.data is FormData) {
                capturedFormData = options.data as FormData;
              }
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: '{"id":"sig-101"}',
                ),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/signatures'),
          fieldName: 'sig',
          filePath: filePath,
          extraFields: {
            'clean_field': 'preserve_me',
            'order_number': '12345',
            // Internal metadata to be stripped:
            '_sync_status': 'in_flight',
            '_sync_version': 4,
            '_offline_meta': {'device': 'pixel_8'},
            'expires_at': 1700000000,
            'updated_at': 1700000001,
            '_base_snapshot_json': '{"dirty":true}',
          },
        );

        expect(capturedFormData, isNotNull);
        final fieldKeys = capturedFormData!.fields.map((e) => e.key).toSet();

        expect(fieldKeys.contains('clean_field'), isTrue);
        expect(fieldKeys.contains('order_number'), isTrue);
        expect(fieldKeys.contains('_sync_status'), isFalse);
        expect(fieldKeys.contains('_sync_version'), isFalse);
        expect(fieldKeys.contains('_offline_meta'), isFalse);
        expect(fieldKeys.contains('expires_at'), isFalse);
        expect(fieldKeys.contains('updated_at'), isFalse);
        expect(fieldKeys.contains('_base_snapshot_json'), isFalse);

        adapter.dispose();
      });
    });

    group('2. Streaming Directly from Disk (Zero RAM Blowup)', () {
      test(
          'streams binary file via chunked openRead stream without loading full byte array into RAM',
          () async {
        // Create a 512 KB test file with predictable byte pattern
        final filePath = '${tempDir.path}/large_document.pdf';
        final file = File(filePath);
        final sink = file.openWrite();
        const chunkSize = 16 * 1024; // 16 KB chunks
        const totalChunks = 32; // 512 KB total
        final chunkPattern = List<int>.generate(chunkSize, (i) => i % 256);
        for (var i = 0; i < totalChunks; i++) {
          sink.add(chunkPattern);
        }
        await sink.flush();
        await sink.close();

        final expectedLength = await file.length();
        expect(expectedLength, equals(512 * 1024));

        final dio = Dio();
        MultipartFile? capturedFile;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              final formData = options.data as FormData;
              capturedFile = formData.files.first.value;

              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: '{"status":"chunk_received"}',
                ),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        final response = await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/documents'),
          fieldName: 'document',
          filePath: filePath,
          fileName: 'large_document.pdf',
          mimeType: 'application/pdf',
        );

        expect(response.isSuccess, isTrue);
        expect(capturedFile, isNotNull);

        // Verify the MultipartFile knows its length from disk file descriptor
        expect(capturedFile!.length, equals(expectedLength));

        // Consume the internal stream builder to verify chunked streaming from disk
        final stream = capturedFile!.finalize();
        var streamedByteCount = 0;
        await for (final chunk in stream) {
          streamedByteCount += chunk.length;
        }
        expect(streamedByteCount, equals(expectedLength));

        adapter.dispose();
      });

      test('infers fileName from filePath basename when fileName is omitted',
          () async {
        final filePath = '${tempDir.path}/auto_named_photo.jpg';
        await File(filePath).writeAsString('photo-data');

        final dio = Dio();
        MultipartFile? capturedFile;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final formData = options.data as FormData;
              capturedFile = formData.files.first.value;
              return handler.resolve(
                Response(requestOptions: options, statusCode: 200),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/photos'),
          fieldName: 'file',
          filePath: filePath,
        );

        expect(capturedFile, isNotNull);
        expect(capturedFile!.filename, equals('auto_named_photo.jpg'));

        adapter.dispose();
      });
    });

    group('3. Dedicated Transfer Timeout (60 Seconds)', () {
      test('enforces dedicated 60-second transfer timeout by default',
          () async {
        final filePath = '${tempDir.path}/small.txt';
        await File(filePath).writeAsString('sample');

        final dio = Dio();
        Duration? capturedSendTimeout;
        Duration? capturedReceiveTimeout;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedSendTimeout = options.sendTimeout;
              capturedReceiveTimeout = options.receiveTimeout;
              return handler.resolve(
                Response(requestOptions: options, statusCode: 200),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/upload'),
          fieldName: 'file',
          filePath: filePath,
        );

        expect(capturedSendTimeout, equals(const Duration(seconds: 60)));
        expect(capturedReceiveTimeout, equals(const Duration(seconds: 60)));

        adapter.dispose();
      });

      test('allows overriding the transfer timeout when specified', () async {
        final filePath = '${tempDir.path}/small.txt';
        await File(filePath).writeAsString('sample');

        final dio = Dio();
        Duration? capturedSendTimeout;
        Duration? capturedReceiveTimeout;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedSendTimeout = options.sendTimeout;
              capturedReceiveTimeout = options.receiveTimeout;
              return handler.resolve(
                Response(requestOptions: options, statusCode: 200),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/upload'),
          fieldName: 'file',
          filePath: filePath,
          timeout: const Duration(seconds: 45),
        );

        expect(capturedSendTimeout, equals(const Duration(seconds: 45)));
        expect(capturedReceiveTimeout, equals(const Duration(seconds: 45)));

        adapter.dispose();
      });

      test(
          'maps sendTimeout DioException to TransportResponse with isNetworkError',
          () async {
        final filePath = '${tempDir.path}/small.txt';
        await File(filePath).writeAsString('sample');

        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              return handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.sendTimeout,
                  message: 'Uploading stream timed out after 60s',
                ),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        final response = await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/upload'),
          fieldName: 'file',
          filePath: filePath,
        );

        expect(response.isSuccess, isFalse);
        expect(response.statusCode, equals(0));
        expect(response.isNetworkError, isTrue);
        expect(response.error, isA<DioException>());

        adapter.dispose();
      });
    });

    group('4. Headers, Content-Type, & Error Handling', () {
      test(
          'custom headers and auth token preserved while application/json is stripped for multipart boundary',
          () async {
        final filePath = '${tempDir.path}/note.txt';
        await File(filePath).writeAsString('note content');

        final dio = Dio();
        Map<String, dynamic>? capturedHeaders;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedHeaders = options.headers;
              return handler.resolve(
                Response(requestOptions: options, statusCode: 200),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/upload'),
          fieldName: 'doc',
          filePath: filePath,
          headers: {
            'Authorization': 'Bearer token-xyz',
            'Content-Type':
                'application/json', // Should be stripped to allow multipart boundary
            'X-Trace-Id': 'trace-404',
          },
        );

        expect(capturedHeaders, isNotNull);
        expect(capturedHeaders!['authorization'], equals('Bearer token-xyz'));
        expect(capturedHeaders!['x-trace-id'], equals('trace-404'));
        // Verify application/json was removed
        expect(capturedHeaders!['content-type'],
            isNot(equals('application/json')));

        adapter.dispose();
      });

      test('captures HTTP 401/409/500 errors into TransportResponse cleanly',
          () async {
        final filePath = '${tempDir.path}/test.txt';
        await File(filePath).writeAsString('test');

        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              return handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 409,
                    data: '{"error":"Duplicate file fingerprint"}',
                    headers: Headers.fromMap({
                      'x-retry': ['false']
                    }),
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );

        final adapter = DioHttpAdapter(dio: dio);

        final response = await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/upload'),
          fieldName: 'f',
          filePath: filePath,
        );

        expect(response.isSuccess, isFalse);
        expect(response.isConflict, isTrue);
        expect(response.statusCode, equals(409));
        expect(response.body, contains('Duplicate file fingerprint'));
        expect(response.headers['x-retry'], equals('false'));

        adapter.dispose();
      });

      test(
          'returns error in TransportResponse when file does not exist on disk',
          () async {
        final adapter = DioHttpAdapter();

        final response = await adapter.pushMultipart(
          uri: Uri.parse('https://api.example.com/upload'),
          fieldName: 'f',
          filePath: '/non/existent/path/ghost_file.bin',
        );

        expect(response.isSuccess, isFalse);
        expect(response.statusCode, equals(0));
        expect(response.error, isNotNull);
        expect(response.error, isA<FileSystemException>());

        adapter.dispose();
      });
    });

    group(
        '5. Transport Integration (SyncTransport.dio & InMemorySyncTransport)',
        () {
      test('SyncTransport.dio injects auth token and resolves relative URI',
          () async {
        final filePath = '${tempDir.path}/upload.pdf';
        await File(filePath).writeAsString('pdf data');

        final dio = Dio();
        String? capturedUri;
        String? capturedAuth;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedUri = options.uri.toString();
              capturedAuth = options.headers['authorization'];
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: '{"uploaded":true}',
                ),
              );
            },
          ),
        );

        final transport = SyncTransport.dio(
          baseUrl: 'https://enterprise.example.com/api',
          dio: dio,
          getAuthToken: () async => 'auth-jwt-token-77',
        );

        final response = await transport.pushMultipart(
          uri: Uri.parse('v1/photos'),
          fieldName: 'image',
          filePath: filePath,
          extraFields: {'caption': 'Delivery snapshot'},
        );

        expect(response.isSuccess, isTrue);
        expect(capturedUri,
            equals('https://enterprise.example.com/api/v1/photos'));
        expect(capturedAuth, equals('Bearer auth-jwt-token-77'));

        transport.dispose();
      });

      test(
          'InMemorySyncTransport records pushMultipart calls and resets correctly',
          () async {
        final transport = SyncTransport.inMemory(
          pushStatusCode: 201,
          pushResponseBody: '{"id":"mem-1"}',
        );

        final response = await transport.pushMultipart(
          uri: Uri.parse('https://mock.example.com/upload'),
          method: 'POST',
          fieldName: 'avatar',
          filePath: '/mock/path/avatar.png',
          fileName: 'avatar.png',
          mimeType: 'image/png',
          extraFields: {'user_id': 'usr_99'},
        );

        expect(response.isSuccess, isTrue);
        expect(response.statusCode, equals(201));
        expect(response.body, equals('{"id":"mem-1"}'));

        final inMemory = transport as InMemorySyncTransport;
        expect(inMemory.multipartPushes.length, equals(1));
        final record = inMemory.multipartPushes.first;
        expect(record['fieldName'], equals('avatar'));
        expect(record['filePath'], equals('/mock/path/avatar.png'));
        expect(record['extraFields'], equals({'user_id': 'usr_99'}));

        inMemory.reset();
        expect(inMemory.multipartPushes, isEmpty);

        transport.dispose();
      });

      test('DefaultHttpAdapter returns TransportResponse with UnsupportedError',
          () async {
        final transport = SyncTransport.http(
          baseUrl: 'https://api.example.com',
        );

        final response = await transport.pushMultipart(
          uri: Uri.parse('https://api.example.com/upload'),
          fieldName: 'f',
          filePath: '/dummy/path',
        );

        expect(response.isSuccess, isFalse);
        expect(response.statusCode, equals(0));
        expect(response.error, isA<UnsupportedError>());

        transport.dispose();
      });
    });
  });
}
