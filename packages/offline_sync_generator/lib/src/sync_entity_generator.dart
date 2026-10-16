import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:offline_sync_annotation/offline_sync_annotation.dart';

class SyncEntityGenerator extends GeneratorForAnnotation<SyncEntity> {
  @override
  String generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '`@SyncEntity` can only be applied to classes.',
        element: element,
      );
    }

    final className = element.name;
    if (className == null || className.isEmpty) {
      throw InvalidGenerationSourceError('Unnamed class cannot be annotated with `@SyncEntity`.', element: element);
    }

    final endpoint = annotation.read('endpoint').stringValue;
    final customTable = annotation.peek('tableName')?.stringValue;
    final tableName = customTable ?? _toSnakeCase(className) + 's';
    final profile = annotation.peek('profile')?.stringValue ?? 'standard';

    final fields = <_FieldInfo>[];
    String? pkName;

    for (final field in element.fields) {
      if (field.isStatic) continue;
      final fieldName = field.name;
      if (fieldName == null || fieldName.isEmpty) continue;

      // Check for @SyncField(isIgnored: true)
      final fieldAnnotation = _getSyncFieldAnnotation(field);
      if (fieldAnnotation != null && fieldAnnotation.isIgnored) continue;

      final isPk = _isPrimaryKey(field);
      if (isPk) {
        pkName = fieldName;
      }

      final colName = fieldAnnotation?.name ?? _toSnakeCase(fieldName);
      final sqliteType = _resolveSqliteType(field.type);

      fields.add(_FieldInfo(
        dartName: fieldName,
        columnName: colName,
        dartType: field.type,
        sqliteType: sqliteType,
        isPrimaryKey: isPk,
      ));
    }

    if (pkName == null) {
      // Default to 'id' if present, otherwise throw
      final hasId = fields.any((f) => f.dartName == 'id');
      if (hasId) {
        pkName = 'id';
        for (var i = 0; i < fields.length; i++) {
          if (fields[i].dartName == 'id') {
            fields[i] = fields[i].copyWith(isPrimaryKey: true);
          }
        }
      } else {
        throw InvalidGenerationSourceError(
          'Class `$className` must have a primary key field annotated with `@PrimaryKey()` or named `id`.',
          element: element,
        );
      }
    }

    return _generateCode(className, tableName, endpoint, profile, fields, pkName);
  }

  String _generateCode(
    String className,
    String tableName,
    String endpoint,
    String profile,
    List<_FieldInfo> fields,
    String pkName,
  ) {
    final buffer = StringBuffer();
    final repoName = '\$${className}Repository';
    final extPropName = _toLowerCamelCase(tableName);

    // 1. Table Schema Map
    buffer.writeln('/// Generated table schema columns for [$className].');
    buffer.writeln('const \$${className}TableSchema = <String, String>{');
    for (final f in fields) {
      if (f.isPrimaryKey) {
        buffer.writeln("  '${f.columnName}': 'TEXT PRIMARY KEY',");
      } else {
        buffer.writeln("  '${f.columnName}': '${f.sqliteType}',");
      }
    }
    buffer.writeln('};');
    buffer.writeln();

    // 2. FromMap Serializer
    buffer.writeln('/// Deserializes a SQLite row/map into [$className].');
    buffer.writeln('$className \$${className}FromMap(Map<String, dynamic> map) {');
    buffer.writeln('  return $className(');
    for (final f in fields) {
      final getter = _generateMapGetter(f);
      buffer.writeln('    ${f.dartName}: $getter,');
    }
    buffer.writeln('  );');
    buffer.writeln('}');
    buffer.writeln();

    // 3. ToMap Serializer
    buffer.writeln('/// Serializes [$className] into a SQLite row/map.');
    buffer.writeln('Map<String, dynamic> \$${className}ToMap($className entity) {');
    buffer.writeln('  return <String, dynamic>{');
    for (final f in fields) {
      final valueExpr = _generateMapSetter(f);
      buffer.writeln("    '${f.columnName}': $valueExpr,");
    }
    buffer.writeln('  };');
    buffer.writeln('}');
    buffer.writeln();

    // 4. Type-Safe Repository
    buffer.writeln('/// Type-safe sync repository for [$className].');
    buffer.writeln('class $repoName {');
    buffer.writeln('  final OfflineSyncClient client;');
    buffer.writeln("  final String tableName = '$tableName';");
    buffer.writeln("  final String endpoint = '$endpoint';");
    buffer.writeln();
    buffer.writeln('  $repoName(this.client);');
    buffer.writeln();
    buffer.writeln('  /// Registers the entity table with schema columns and shadow bases.');
    buffer.writeln('  Future<void> registerTable() async {');
    buffer.writeln('    final cols = Map<String, String>.from(\$${className}TableSchema);');
    buffer.writeln("    cols.remove('id');");
    buffer.writeln('    await client.registerTable(tableName, cols);');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  /// Saves entity optimistically to local SQLite and appends to outbox.');
    buffer.writeln('  Future<String> save($className entity, {String? dependsOnMutationId}) async {');
    buffer.writeln('    return await client.save(');
    buffer.writeln('      entity: tableName,');
    buffer.writeln('      id: entity.$pkName,');
    buffer.writeln('      data: \$${className}ToMap(entity),');
    buffer.writeln('      dependsOnMutationId: dependsOnMutationId,');
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  /// Deletes entity locally and queues delete tombstone in outbox.');
    buffer.writeln('  Future<void> delete(String id) async {');
    buffer.writeln('    await client.delete(entity: tableName, id: id);');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  /// Retrieves a single record by primary key.');
    buffer.writeln('  Future<$className?> getById(String id) async {');
    buffer.writeln("    final rows = await client.query('SELECT * FROM \$tableName WHERE id = ?;', [id]);");
    buffer.writeln('    if (rows.isEmpty) return null;');
    buffer.writeln('    return \$${className}FromMap(rows.first);');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  /// Retrieves all records matching an optional order.');
    buffer.writeln('  Future<List<$className>> getAll({String? orderBy}) async {');
    buffer.writeln("    final sql = orderBy != null ? 'SELECT * FROM \$tableName ORDER BY \$orderBy;' : 'SELECT * FROM \$tableName;';");
    buffer.writeln('    final rows = await client.query(sql);');
    buffer.writeln('    return rows.map((r) => \$${className}FromMap(r)).toList();');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  /// Streams all records reactively with zero-codegen database watch.');
    buffer.writeln('  Stream<List<$className>> watchAll({String? orderBy}) {');
    buffer.writeln("    final sql = orderBy != null ? 'SELECT * FROM \$tableName ORDER BY \$orderBy;' : 'SELECT * FROM \$tableName;';");
    buffer.writeln('    return client.watch(sql).map((rs) => rs.map((r) => \$${className}FromMap(r)).toList());');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  /// Streams a single record reactively by ID.');
    buffer.writeln('  Stream<$className?> watchById(String id) {');
    buffer.writeln("    return client.watch('SELECT * FROM \$tableName WHERE id = ?;', parameters: [id]).map(");
    buffer.writeln('      (rs) => rs.isEmpty ? null : \$${className}FromMap(rs.first),');
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln('}');
    buffer.writeln();

    // 5. Client Extension
    buffer.writeln('/// Client convenience extension for [$className].');
    buffer.writeln('extension \$${className}ClientExtension on OfflineSyncClient {');
    buffer.writeln('  $repoName get $extPropName => $repoName(this);');
    buffer.writeln('}');
    buffer.writeln();

    // 6. Automated Test Suite Generator
    buffer.writeln('/// Automated sync acceptance test suite generator for [$className].');
    buffer.writeln('class \$${className}SyncTestSuite {');
    buffer.writeln('  static void runTests({');
    buffer.writeln('    required Future<OfflineSyncClient> Function() createClient,');
    buffer.writeln('    required $className Function(String id, String label) createEntity,');
    buffer.writeln('  }) {');
    buffer.writeln("    group('Generated Sync Suite: $className', () {");
    buffer.writeln("      test('Test 1: Offline Local Write & Outbox Enqueue', () async {");
    buffer.writeln('        final client = await createClient();');
    buffer.writeln('        await client.$extPropName.registerTable();');
    buffer.writeln("        final entity = createEntity('gen-1', 'Initial Label');");
    buffer.writeln('        await client.$extPropName.save(entity);');
    buffer.writeln();
    buffer.writeln("        final saved = await client.$extPropName.getById('gen-1');");
    buffer.writeln('        expect(saved, isNotNull);');
    buffer.writeln("        final outbox = await client.query(\"SELECT status, action FROM _sync_outbox WHERE entity_id = 'gen-1';\");");
    buffer.writeln("        expect(outbox.first['status'], 'pending');");
    buffer.writeln("        expect(outbox.first['action'], 'upsert');");
    buffer.writeln('        await client.close();');
    buffer.writeln('      });');
    buffer.writeln();
    buffer.writeln("      test('Test 2: Push Sync & Outbox Drain', () async {");
    buffer.writeln('        final client = await createClient();');
    buffer.writeln('        await client.$extPropName.registerTable();');
    buffer.writeln("        final entity = createEntity('gen-2', 'Push Label');");
    buffer.writeln('        await client.$extPropName.save(entity);');
    buffer.writeln('        await client.sync();');
    buffer.writeln();
    buffer.writeln("        final outbox = await client.query(\"SELECT status FROM _sync_outbox WHERE entity_id = 'gen-2';\");");
    buffer.writeln("        expect(outbox.first['status'], 'synced');");
    buffer.writeln('        await client.close();');
    buffer.writeln('      });');
    buffer.writeln();
    buffer.writeln("      test('Test 3: Local Delete & Tombstone Enqueue', () async {");
    buffer.writeln('        final client = await createClient();');
    buffer.writeln('        await client.$extPropName.registerTable();');
    buffer.writeln("        final entity = createEntity('gen-3', 'Delete Label');");
    buffer.writeln('        await client.$extPropName.save(entity);');
    buffer.writeln("        await client.$extPropName.delete('gen-3');");
    buffer.writeln();
    buffer.writeln("        final saved = await client.$extPropName.getById('gen-3');");
    buffer.writeln('        expect(saved, isNull);');
    buffer.writeln("        final outbox = await client.query(\"SELECT action FROM _sync_outbox WHERE entity_id = 'gen-3' AND status = 'pending';\");");
    buffer.writeln("        expect(outbox.first['action'], 'delete');");
    buffer.writeln('        await client.close();');
    buffer.writeln('      });');
    buffer.writeln('    });');
    buffer.writeln('  }');
    buffer.writeln('}');

    return buffer.toString();
  }

  String _generateMapGetter(_FieldInfo f) {
    final raw = "map['${f.columnName}']";
    final typeName = f.dartType.getDisplayString();

    if (f.dartType.isDartCoreString) {
      return "$raw as String";
    } else if (f.dartType.isDartCoreInt) {
      return "$raw as int";
    } else if (f.dartType.isDartCoreDouble) {
      return "($raw as num).toDouble()";
    } else if (f.dartType.isDartCoreBool) {
      return "($raw as int) == 1";
    } else if (typeName.startsWith('DateTime')) {
      return "DateTime.parse($raw as String)";
    }
    return "$raw as $typeName";
  }

  String _generateMapSetter(_FieldInfo f) {
    final typeName = f.dartType.getDisplayString();
    if (f.dartType.isDartCoreBool) {
      return "entity.${f.dartName} ? 1 : 0";
    } else if (typeName.startsWith('DateTime')) {
      return "entity.${f.dartName}.toUtc().toIso8601String()";
    }
    return "entity.${f.dartName}";
  }

  bool _isPrimaryKey(FieldElement field) {
    if (field.name == 'id') return true;
    for (final meta in field.metadata.annotations) {
      final value = meta.computeConstantValue();
      if (value != null && value.type?.getDisplayString() == 'PrimaryKey') {
        return true;
      }
    }
    return false;
  }

  _SyncFieldMeta? _getSyncFieldAnnotation(FieldElement field) {
    for (final meta in field.metadata.annotations) {
      final value = meta.computeConstantValue();
      if (value != null && value.type?.getDisplayString() == 'SyncField') {
        final reader = ConstantReader(value);
        final name = reader.peek('name')?.stringValue;
        final isIgnored = reader.peek('isIgnored')?.boolValue ?? false;
        return _SyncFieldMeta(name: name, isIgnored: isIgnored);
      }
    }
    return null;
  }

  String _resolveSqliteType(DartType type) {
    if (type.isDartCoreString) return 'TEXT NOT NULL';
    if (type.isDartCoreInt) return 'INTEGER NOT NULL DEFAULT 0';
    if (type.isDartCoreBool) return 'INTEGER NOT NULL DEFAULT 0';
    if (type.isDartCoreDouble) return 'REAL NOT NULL DEFAULT 0.0';
    if (type.getDisplayString().startsWith('DateTime')) return 'TEXT NOT NULL';
    return 'TEXT NOT NULL';
  }

  String _toSnakeCase(String text) {
    return text.replaceAllMapped(
      RegExp(r'(?<=[a-z])[A-Z]'),
      (match) => '_${match.group(0)}',
    ).toLowerCase();
  }

  String _toLowerCamelCase(String text) {
    if (text.isEmpty) return text;
    final parts = text.split('_');
    final first = parts.first.toLowerCase();
    final rest = parts.skip(1).map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join();
    return '$first$rest';
  }
}

class _FieldInfo {
  final String dartName;
  final String columnName;
  final DartType dartType;
  final String sqliteType;
  final bool isPrimaryKey;

  _FieldInfo({
    required this.dartName,
    required this.columnName,
    required this.dartType,
    required this.sqliteType,
    this.isPrimaryKey = false,
  });

  _FieldInfo copyWith({bool? isPrimaryKey}) {
    return _FieldInfo(
      dartName: dartName,
      columnName: columnName,
      dartType: dartType,
      sqliteType: sqliteType,
      isPrimaryKey: isPrimaryKey ?? this.isPrimaryKey,
    );
  }
}

class _SyncFieldMeta {
  final String? name;
  final bool isIgnored;

  _SyncFieldMeta({this.name, this.isIgnored = false});
}
