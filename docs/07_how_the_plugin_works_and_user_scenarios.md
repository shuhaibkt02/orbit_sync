# Phase 7: How the Plugin Works & Real-World Developer Scenarios

## 1. What Is This Plugin?
A universal, client-side, offline-first sync engine for Flutter. 
It makes any Flutter app instantly work 100% offline and synchronizes automatically with the developer's existing backend (REST, GraphQL, Supabase, etc.) when connected—without requiring any proprietary server infrastructure.

### Who Is It For?
- **Beginner / Indie Developers:** Want simple local storage + auto-cloud sync without learning SQL or writing sync logic.
- **Enterprise / Senior Developers:** Need zero data loss, multi-tenant isolation, atomic cascade transactions, field-level conflict resolution, and background isolate execution.

---

## 2. Scenario 1: The Beginner Developer (Simple Todo App)

### The Developer's Goal:
A student or junior developer building a Todo app. If the user is on the subway (offline), adding or checking off a task must work immediately and sync to their Node.js/Firebase backend later.

### How They Use the Plugin (3 Simple Steps):

#### Step 1: Annotate the Model
```dart
@SyncEntity(endpoint: '/todos')
class Todo {
  @PrimaryKey()
  final String id;
  final String title;
  final bool isCompleted;

  Todo({required this.id, required this.title, required this.isCompleted});
}
```

#### Step 2: Run build_runner
```bash
dart run build_runner build
```

#### Step 3: Use in Flutter UI
```dart
// 1. Initialize
final sync = await OfflineSync.init(baseUrl: 'https://api.mytodos.com');

// 2. Read reactively (StreamBuilder automatically updates)
Stream<List<Todo>> todosStream = sync.todos.watchAll();

// 3. Write offline
await sync.todos.save(Todo(
  id: uuid.v7(),
  title: 'Buy Groceries',
  isCompleted: false,
));
```

### The Benefit:
- **Takes 10 minutes.**
- No need to learn SQLite, SQL queries, or HTTP retry logic.
- Instant offline support with automatic UI updates.

---

## 3. Scenario 2: The Enterprise Developer (Large Business ERP)

### The Developer's Goal:
A team building an ERP for field engineers (Invoices, Parts Inventory, Work Orders). Engineers work in remote factory basements with zero reception for days. The app must handle heavy data, multi-tenancy, and complex conflict handling.

### How They Use the Plugin:

#### Step 1: Configure Enterprise Engine
```dart
final erpSync = await OfflineSync.init(
  baseUrl: 'https://erp.company.com/api/v1',
  tenantId: currentUser.companyId,
  authStorage: SecureKeyVault(), // Keychain / Keystore encryption
  conflictPolicy: ConflictPolicy.fieldLevelMerge, // Merges edits field-by-field
  enableBackgroundSync: true, // Native WorkManager & BGTaskScheduler
);
```

#### Step 2: Transactional Cascade Writes (Parent + Children)
```dart
// Save Invoice and 5 Line Items in one single atomic transaction
await erpSync.transaction((tx) async {
  await tx.invoices.save(invoice);
  for (final item in lineItems) {
    await tx.invoiceItems.save(item);
  }
});
```

#### Step 3: Per-Record UI Status Exposure
```dart
// The ERP UI shows sync badges to field workers
Widget build(BuildContext context) {
  return StreamBuilder<Invoice>(
    stream: erpSync.invoices.watchById('inv-123'),
    builder: (context, snapshot) {
      final invoice = snapshot.data;
      return ListTile(
        title: Text(invoice.number),
        trailing: switch (invoice.syncStatus) {
          SyncStatus.synced => Icon(Icons.check_circle, color: Colors.green),
          SyncStatus.pending => Icon(Icons.sync, color: Colors.orange),
          SyncStatus.conflict => Icon(Icons.warning, color: Colors.red),
        },
      );
    },
  );
}
```

### The Benefit:
- **Saves 6+ months of engineering:** Outbox, DAG ordering, retries, and dead-letters are pre-built.
- **Zero data loss:** SQLite transactional outbox guarantees atomic commits even if the phone battery dies mid-write.
- **Smooth 120fps UI:** All sync, payload decompression, and JSON parsing run in a background Dart isolate.
- **No backend overhaul:** Plugs directly into their existing enterprise APIs (SAP, Salesforce, Django, Java, Go).

---

## 4. Summary Matrix

| Capability | Beginner Todo App | Enterprise ERP App |
| :--- | :--- | :--- |
| **Complexity to Setup** | 10 minutes (<20 lines of code) | Full control via configuration hooks |
| **Data Safety** | Auto-retry when online | Transactional outbox + DAG cascade ordering |
| **Conflict Resolution** | Last-Write-Wins (default) | Field-level merge or custom domain resolver |
| **UI Experience** | Reactive `StreamBuilder` | Reactive streams + per-record `SyncStatus` badges |
| **Device Resources** | Minimal battery/RAM usage | Background isolate worker + WorkManager |
