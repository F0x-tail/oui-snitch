import 'dart:ffi';

import 'package:sqlite3/sqlite3.dart';

/// The Dart-implemented SQL functions drift registers on every database it
/// opens, mirroring `useNativeFunctions()` in
/// `drift/lib/src/sqlite3/native_functions.dart`.
///
/// Kept as data rather than inferred, because the point is to drop *exactly*
/// these and forward everything else.
const Set<String> kDriftBuiltinFunctions = {
  'power',
  'pow',
  'sqrt',
  'sin',
  'cos',
  'tan',
  'asin',
  'acos',
  'atan',
  'regexp',
  'regexp_moor_ffi',
  'moor_contains',
  'current_time_millis',
};

/// A [SqliteResolver] for drift's `NativeDatabase` that opens sqlite3 with
/// drift's own Dart SQL functions suppressed.
///
/// ## Why
///
/// Giving sqlite3 a Dart closure makes `dart:ffi` build a native call
/// trampoline, which means `mprotect`-ing an anonymous page to `PROT_EXEC`.
/// GrapheneOS denies that when *Dynamic code loading via memory* is
/// Restricted, and the Dart VM aborts the whole process:
///
/// ```
/// virtual_memory_posix.cc: error: mprotect failed: 13 (Permission denied)
/// signal 6 (SIGABRT)
/// ```
///
/// drift's `Sqlite3Delegate._initializeDatabase()` calls
/// `database.useNativeFunctions()` unconditionally on every open, with no flag
/// to disable it. Because this app opens its database with
/// `NativeDatabase.createInBackground`, the abort lands on the background
/// isolate a few seconds into startup.
///
/// An AOT release build does not avoid this. AOT removes the JIT, but FFI
/// callbacks still need executable memory.
///
/// Upstream: flutter/flutter#191385 (closed, handed off) and
/// dart-lang/sdk#64137 (open, P3, no activity since it was filed).
///
/// ## How
///
/// drift accepts a `sqlite3:` resolver, so no fork is needed. This wraps the
/// real sqlite3 and drops `createFunction` calls for exactly
/// [kDriftBuiltinFunctions]. **Everything else is forwarded untouched**, so any
/// function this app registers itself still works — and would still fail the
/// same way stock drift does — rather than being silently swallowed.
///
/// Safe here because none of those functions appear in this app's SQL. If that
/// ever changes, SQLite fails loudly with `no such function` rather than
/// returning a wrong answer.
///
/// Not gated to Android: the same path runs everywhere so it cannot rot.
///
/// The approach (wrap the resolver rather than patch drift) is due to
/// resonchat-org/resonchat@7d85861. Their implementation is GPL-3.0; this one
/// is written against sqlite3 2.9.4's interface and shares no code with it.
Sqlite3 guardedSqlite3() => _GuardedSqlite3(sqlite3);

Database _unwrap(Database db) => db is _GuardedDatabase ? db._inner : db;

final class _GuardedSqlite3 implements Sqlite3 {
  _GuardedSqlite3(this._inner);

  final Sqlite3 _inner;

  @override
  Database open(
    String filename, {
    String? vfs,
    OpenMode mode = OpenMode.readWriteCreate,
    bool uri = false,
    bool? mutex,
  }) =>
      _GuardedDatabase(
          _inner.open(filename, vfs: vfs, mode: mode, uri: uri, mutex: mutex));

  @override
  Database openInMemory({String? vfs}) =>
      _GuardedDatabase(_inner.openInMemory(vfs: vfs));

  @override
  Database fromPointer(Pointer<void> database) =>
      _GuardedDatabase(_inner.fromPointer(database));

  @override
  Database copyIntoMemory(Database restoreFrom) =>
      _GuardedDatabase(_inner.copyIntoMemory(_unwrap(restoreFrom)));

  @override
  Version get version => _inner.version;

  @override
  String? get tempDirectory => _inner.tempDirectory;

  @override
  set tempDirectory(String? value) => _inner.tempDirectory = value;

  @override
  void ensureExtensionLoaded(SqliteExtension extension) =>
      _inner.ensureExtensionLoaded(extension);

  @override
  void registerVirtualFileSystem(VirtualFileSystem vfs,
          {bool makeDefault = false}) =>
      _inner.registerVirtualFileSystem(vfs, makeDefault: makeDefault);

  @override
  void unregisterVirtualFileSystem(VirtualFileSystem vfs) =>
      _inner.unregisterVirtualFileSystem(vfs);
}

final class _GuardedDatabase implements Database {
  _GuardedDatabase(this._inner);

  final Database _inner;

  // ---- the only behaviour that differs from stock sqlite3 ----

  @override
  void createFunction({
    required String functionName,
    required ScalarFunction function,
    AllowedArgumentCount argumentCount = const AllowedArgumentCount.any(),
    bool deterministic = false,
    bool directOnly = true,
    bool subtype = false,
  }) {
    if (kDriftBuiltinFunctions.contains(functionName)) return;
    _inner.createFunction(
      functionName: functionName,
      function: function,
      argumentCount: argumentCount,
      deterministic: deterministic,
      directOnly: directOnly,
      subtype: subtype,
    );
  }

  // ---- everything below is plain delegation ----

  @override
  DatabaseConfig get config => _inner.config;

  @override
  int get userVersion => _inner.userVersion;

  @override
  set userVersion(int value) => _inner.userVersion = value;

  @override
  int get lastInsertRowId => _inner.lastInsertRowId;

  @override
  int get updatedRows => _inner.updatedRows;

  @override
  // ignore: deprecated_member_use
  int getUpdatedRows() => _inner.getUpdatedRows();

  @override
  Stream<SqliteUpdate> get updates => _inner.updates;

  @override
  Stream<SqliteUpdate> get updatesSync => _inner.updatesSync;

  @override
  VoidPredicate? get commitFilter => _inner.commitFilter;

  @override
  set commitFilter(VoidPredicate? value) => _inner.commitFilter = value;

  @override
  Stream<void> get commits => _inner.commits;

  @override
  Stream<void> get rollbacks => _inner.rollbacks;

  @override
  bool get autocommit => _inner.autocommit;

  @override
  Pointer<void> get handle => _inner.handle;

  @override
  void execute(String sql, [List<Object?> parameters = const []]) =>
      _inner.execute(sql, parameters);

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      _inner.select(sql, parameters);

  @override
  PreparedStatement prepare(
    String sql, {
    bool persistent = false,
    bool vtab = true,
    bool checkNoTail = false,
  }) =>
      _inner.prepare(sql,
          persistent: persistent, vtab: vtab, checkNoTail: checkNoTail);

  @override
  List<PreparedStatement> prepareMultiple(
    String sql, {
    bool persistent = false,
    bool vtab = true,
  }) =>
      _inner.prepareMultiple(sql, persistent: persistent, vtab: vtab);

  @override
  Stream<double> backup(Database toDatabase, {int nPage = 5}) =>
      _inner.backup(_unwrap(toDatabase), nPage: nPage);

  @override
  void createCollation({
    required String name,
    required CollatingFunction function,
  }) =>
      _inner.createCollation(name: name, function: function);

  @override
  void createAggregateFunction<V>({
    required String functionName,
    required AggregateFunction<V> function,
    AllowedArgumentCount argumentCount = const AllowedArgumentCount.any(),
    bool deterministic = false,
    bool directOnly = true,
    bool subtype = false,
  }) =>
      _inner.createAggregateFunction<V>(
        functionName: functionName,
        function: function,
        argumentCount: argumentCount,
        deterministic: deterministic,
        directOnly: directOnly,
        subtype: subtype,
      );

  @override
  void dispose() => _inner.dispose();
}
