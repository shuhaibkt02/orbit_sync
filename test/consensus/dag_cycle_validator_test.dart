import 'package:test/test.dart';
import 'package:orbit_sync/src/consensus/domain/policies/dag_cycle_validator.dart';

void main() {
  group('Layer 2 Consensus: DagCycleValidator & Priority Inheritance', () {
    test('Test 1: Valid acyclic dependency graph succeeds', () {
      final graph = <String, String?>{
        'mut-b': 'mut-a',
        'mut-c': 'mut-b',
      };

      expect(
        () => DagCycleValidator.assertAcyclic(
          graph: graph,
          childId: 'mut-d',
          parentId: 'mut-c',
        ),
        returnsNormally,
      );
    });

    test('Test 2: Self-dependency throws ArgumentError immediately', () {
      expect(
        () => DagCycleValidator.assertAcyclic(
          graph: {},
          childId: 'mut-x',
          parentId: 'mut-x',
        ),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message, 'message', contains('cannot depend on itself'))),
      );
    });

    test('Test 3: Cyclic dependency (A -> B -> C -> A) throws ArgumentError',
        () {
      final graph = <String, String?>{
        'mut-b': 'mut-a',
        'mut-c': 'mut-b',
      };

      expect(
        () => DagCycleValidator.assertAcyclic(
          graph: graph,
          childId: 'mut-a',
          parentId: 'mut-c',
        ),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('illegal cycle'))),
      );
    });

    test(
        'Test 4: Priority inheritance elevates prerequisite priority and tightens SLA',
        () {
      final inherited = DagCycleValidator.inheritPriority(
        parentPriority: 0,
        parentSlaSeconds: 86400,
        childPriority: 2,
        childSlaSeconds: 900,
      );

      expect(inherited.priority, 2);
      expect(inherited.slaSeconds, 900);
    });
  });
}
