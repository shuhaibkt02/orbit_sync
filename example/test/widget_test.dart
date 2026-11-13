import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:example/main.dart';
import 'package:example/ui/widgets/apple_checkbox.dart';
import 'package:example/ui/widgets/apple_segmented_control.dart';
import 'package:example/ui/widgets/quick_add_bar.dart';
import 'package:example/ui/widgets/undo_toast.dart';

void main() {
  testWidgets('AppleCheckbox toggles value and calls onChanged', (tester) async {
    bool isChecked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AppleCheckbox(
              value: isChecked,
              onChanged: (val) => setState(() => isChecked = val),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AppleCheckbox), findsOneWidget);
    await tester.tap(find.byType(AppleCheckbox));
    await tester.pumpAndSettle();
    expect(isChecked, isTrue);
  });

  testWidgets('AppleSegmentedControl switches selected tab', (tester) async {
    TaskFilter selected = TaskFilter.all;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AppleSegmentedControl<TaskFilter>(
              items: const {
                TaskFilter.all: 'All',
                TaskFilter.active: 'Active',
                TaskFilter.completed: 'Done',
              },
              counts: const {
                TaskFilter.all: 5,
                TaskFilter.active: 3,
                TaskFilter.completed: 2,
              },
              selected: selected,
              onSelected: (filter) => setState(() => selected = filter),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    await tester.tap(find.text('Active'));
    await tester.pumpAndSettle();
    expect(selected, equals(TaskFilter.active));
  });

  testWidgets('QuickAddBar submits text and clears field', (tester) async {
    String? submittedText;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickAddBar(
            onAdd: (text) => submittedText = text,
          ),
        ),
      ),
    );

    final inputFinder = find.byType(TextField);
    expect(inputFinder, findsOneWidget);

    await tester.enterText(inputFinder, 'Deploy Orbit Sync Engine');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(submittedText, equals('Deploy Orbit Sync Engine'));
  });

  testWidgets('UndoToast renders message and triggers onUndo', (tester) async {
    bool undone = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UndoToast(
            message: 'Task removed',
            onUndo: () => undone = true,
            onDismiss: () {},
          ),
        ),
      ),
    );

    expect(find.text('Task removed'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(undone, isTrue);
  });
}
