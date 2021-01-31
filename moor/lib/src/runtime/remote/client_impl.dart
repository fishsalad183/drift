import 'dart:async';

import 'package:moor/src/runtime/api/runtime_api.dart';
import 'package:moor/src/runtime/executor/executor.dart';
import 'package:moor/src/runtime/executor/stream_queries.dart';
import 'package:moor/src/runtime/types/sql_types.dart';
import 'package:stream_channel/stream_channel.dart';

import 'communication.dart';
import 'protocol.dart';

/// The client part of a remote moor communication scheme.
class MoorClient {
  final MoorCommunication _channel;

  late final _RemoteStreamQueryStore _streamStore =
      _RemoteStreamQueryStore(this);

  /// The resulting database connection. Operations on this connection are
  /// relayed through the remote communication channel.
  late final DatabaseConnection connection = DatabaseConnection(
    SqlTypeSystem.defaultInstance,
    _RemoteQueryExecutor(this),
    _streamStore,
  );

  late QueryExecutorUser _connectedDb;

  /// Starts relaying database operations over the request channel.
  MoorClient(StreamChannel<Object?> channel, bool debugLog)
      : _channel = MoorCommunication(channel, debugLog) {
    _channel.setRequestHandler(_handleRequest);
  }

  dynamic _handleRequest(Request request) {
    final payload = request.payload;

    if (payload is RunBeforeOpen) {
      final executor = _RemoteQueryExecutor(this, payload.createdExecutor);
      return _connectedDb.beforeOpen(executor, payload.details);
    } else if (payload is NotifyTablesUpdated) {
      _streamStore.handleTableUpdates(payload.updates.toSet(), true);
    }
  }
}

abstract class _BaseExecutor extends QueryExecutor {
  final MoorClient client;
  int? _executorId;

  _BaseExecutor(this.client, [this._executorId]);

  @override
  Future<void> runBatched(BatchedStatements statements) {
    return client._channel
        .request(ExecuteBatchedStatement(statements, _executorId));
  }

  Future<T> _runRequest<T>(
      StatementMethod method, String sql, List<Object?>? args) {
    return client._channel
        .request<T>(ExecuteQuery(method, sql, args ?? const [], _executorId));
  }

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) {
    return _runRequest(
      StatementMethod.custom,
      statement,
      args,
    );
  }

  @override
  Future<int> runDelete(String statement, List<Object?> args) {
    return _runRequest(StatementMethod.deleteOrUpdate, statement, args);
  }

  @override
  Future<int> runUpdate(String statement, List<Object?> args) {
    return _runRequest(StatementMethod.deleteOrUpdate, statement, args);
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) {
    return _runRequest(StatementMethod.insert, statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
      String statement, List<Object?> args) async {
    final result = await _runRequest<SelectResult>(
        StatementMethod.select, statement, args);

    return result.rows;
  }
}

class _RemoteQueryExecutor extends _BaseExecutor {
  _RemoteQueryExecutor(MoorClient client, [int? executorId])
      : super(client, executorId);

  Completer<void>? _setSchemaVersion;

  @override
  TransactionExecutor beginTransaction() {
    return _RemoteTransactionExecutor(client, _executorId);
  }

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    client._connectedDb = user;
    if (_setSchemaVersion != null) {
      await _setSchemaVersion!.future;
      _setSchemaVersion = null;
    }
    return client._channel
        .request<bool>(EnsureOpen(user.schemaVersion, _executorId));
  }

  @override
  Future<void> close() {
    if (!client._channel.isClosed) {
      client._channel.close();
    }

    return Future.value();
  }
}

class _RemoteTransactionExecutor extends _BaseExecutor
    implements TransactionExecutor {
  final int? _outerExecutorId;

  _RemoteTransactionExecutor(MoorClient client, this._outerExecutorId)
      : super(client);

  Completer<bool>? _pendingOpen;
  bool _done = false;

  @override
  TransactionExecutor beginTransaction() {
    throw UnsupportedError('Nested transactions');
  }

  @override
  Future<bool> ensureOpen(_) {
    assert(
      !_done,
      'Transaction used after it was closed. Are you missing an await '
      'somewhere?',
    );

    final completer = _pendingOpen ??= Completer()..complete(_openAtServer());
    return completer.future;
  }

  Future<bool> _openAtServer() async {
    _executorId = await client._channel.request<int>(
        RunTransactionAction(TransactionControl.begin, _outerExecutorId));
    return true;
  }

  Future<void> _sendAction(TransactionControl action) {
    return client._channel.request(RunTransactionAction(action, _executorId));
  }

  @override
  Future<void> rollback() async {
    // don't do anything if the transaction isn't open yet
    if (_pendingOpen == null) return;

    await _sendAction(TransactionControl.rollback);
    _done = true;
  }

  @override
  Future<void> send() async {
    // don't do anything if the transaction isn't open yet
    if (_pendingOpen == null) return;

    await _sendAction(TransactionControl.commit);
    _done = true;
  }
}

class _RemoteStreamQueryStore extends StreamQueryStore {
  final MoorClient _client;
  final Set<Completer> _awaitingUpdates = {};

  _RemoteStreamQueryStore(this._client);

  @override
  void handleTableUpdates(Set<TableUpdate> updates,
      [bool comesFromServer = false]) {
    if (comesFromServer) {
      super.handleTableUpdates(updates);
    } else {
      // requests are async, but the function is synchronous. We await that
      // future in close()
      final completer = Completer<void>();
      _awaitingUpdates.add(completer);

      completer.complete(
          _client._channel.request(NotifyTablesUpdated(updates.toList())));

      completer.future.catchError((_) {
        // we don't care about errors if the connection is closed before the
        // update is dispatched. Why?
      }, test: (e) => e is ConnectionClosedException).whenComplete(() {
        _awaitingUpdates.remove(completer);
      });
    }
  }

  @override
  Future<void> close() async {
    await super.close();

    // create a copy because awaiting futures in here mutates the set
    final updatesCopy = _awaitingUpdates.map((e) => e.future).toList();
    await Future.wait(updatesCopy);
  }
}
