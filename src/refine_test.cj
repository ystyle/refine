package refine

import std.database.sql.*
import std.collection.{HashMap, ArrayList}
import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.Statement as SqlStatement

// ─── Mocks ──────────────────────────────────────────────

class RMockDS <: Datasource {
    public func connect(): Connection { RMockConn() }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

class RMockConn <: Connection {
    public var closed = false

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }

    public func createTransaction(): Transaction { MockTransaction() }
    public func getMetaData(): HashMap<String, String> { HashMap() }
    public func prepareStatement(sql: String): SqlStatement { MockStatement() }
}

class RMockTrackingDS <: Datasource {
    public var created = ArrayList<Connection>()
    public func connect(): Connection {
        let c = RMockConn()
        created.add(c)
        c
    }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

class RMockFailingTx <: Transaction {
    public mut prop accessMode: TransactionAccessMode {
        get() { _accessMode }
        set(v) { _accessMode = v }
    }
    public mut prop deferrableMode: TransactionDeferrableMode {
        get() { _deferrableMode }
        set(v) { _deferrableMode = v }
    }
    public mut prop isoLevel: TransactionIsoLevel {
        get() { _isoLevel }
        set(v) { _isoLevel = v }
    }
    private var _accessMode: TransactionAccessMode = TransactionAccessMode.ReadWrite
    private var _deferrableMode: TransactionDeferrableMode = TransactionDeferrableMode.NotDeferrable
    private var _isoLevel: TransactionIsoLevel = TransactionIsoLevel.Serializable
    public func begin(): Unit { throw Exception("begin failed") }
    public func commit(): Unit {}
    public func release(_: String): Unit {}
    public func rollback(): Unit {}
    public func rollback(_: String): Unit {}
    public func save(_: String): Unit {}
}

class RMockFailingConn <: Connection {
    public var closed = false

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }

    public func createTransaction(): Transaction { RMockFailingTx() }
    public func getMetaData(): HashMap<String, String> { HashMap() }
    public func prepareStatement(sql: String): SqlStatement { MockStatement() }
}

class RMockFailingDS <: Datasource {
    public var created = ArrayList<Connection>()
    public func connect(): Connection {
        let c = RMockFailingConn()
        created.add(c)
        c
    }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

class RMockTxFailConn <: Connection {
    public var closed = false

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }

    public func createTransaction(): Transaction { throw Exception("createTransaction failed") }
    public func getMetaData(): HashMap<String, String> { HashMap() }
    public func prepareStatement(sql: String): SqlStatement { MockStatement() }
}

class RMockTxFailDS <: Datasource {
    public var created = ArrayList<Connection>()
    public func connect(): Connection {
        let c = RMockTxFailConn()
        created.add(c)
        c
    }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

// I9: 统计底层连接 close() 调用次数，用于验证"成功路径恰好关闭一次"（closeExecutor + finally 不重复）。
class RMockCountConn <: Connection {
    public var closeCount = 0
    public func close(): Unit { closeCount++ }
    public func isClosed(): Bool { closeCount > 0 }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }
    public func createTransaction(): Transaction { MockTransaction() }
    public func getMetaData(): HashMap<String, String> { HashMap() }
    public func prepareStatement(sql: String): SqlStatement { MockStatement() }
}

class RMockCountDS <: Datasource {
    public var created = ArrayList<RMockCountConn>()
    public func connect(): Connection {
        let c = RMockCountConn()
        created.add(c)
        c
    }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

// I9: prepareStatement 必抛异常，用于验证 all()/one() 异常路径 session 仍被 finally 关闭。
class RMockThrowingConn <: Connection {
    public var closeCount = 0
    public func close(): Unit { closeCount++ }
    public func isClosed(): Bool { closeCount > 0 }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }
    public func createTransaction(): Transaction { MockTransaction() }
    public func getMetaData(): HashMap<String, String> { HashMap() }
    public func prepareStatement(sql: String): SqlStatement { throw Exception("mock query failure") }
}

class RMockThrowingDS <: Datasource {
    public var created = ArrayList<RMockThrowingConn>()
    public func connect(): Connection {
        let c = RMockThrowingConn()
        created.add(c)
        c
    }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

// ─── Tests ──────────────────────────────────────────────

class RFlag { var v: Bool = false; init() {} }

@Test
public class RefineTest {

    @TestCase
    public func testInitAndClose(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        @Expect(r.getDialect().name(), "sqlite")
        @Expect(r.getParamOffset(), 0)
        r.close()
        @Expect(true, true)
    }

    @TestCase
    public func testSession(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let s = r.session()
        s.close()
        @Expect(true, true)
    }

    @TestCase
    public func testTransactionCommit(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let result = r.transaction { tx: Tx => 42 }
        @Expect(result, 42)
        r.close()
    }

    @TestCase
    public func testTransactionRollback(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        try {
            r.transaction { tx: Tx => throw Exception("fail") }
            @Fail("expected exception")
        } catch (_: Exception) {
            @Expect(true, true)
        }
        r.close()
    }

    @TestCase
    public func testTransactionIsolationUnsupported(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        try {
            r.transaction(IsolationLevel.Serializable) { tx: Tx => 42 }
            @Fail("expected RefineException for SQLite")
        } catch (e: RefineException) {
            @Expect(e.message.contains("isolation"), true)
        }
        r.close()
    }

    @TestCase
    public func testTransactionIsolationClosesConnection(): Unit {
        let ds = RMockTrackingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        try {
            r.transaction(IsolationLevel.Serializable) { tx: Tx => 42 }
            @Fail("expected RefineException for SQLite")
        } catch (e: RefineException) {
            @Expect(e.message.contains("isolation"), true)
        }
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            @Expect(ds.created.get(0).getOrThrow().isClosed(), true)
        }
        r.close()
    }

    @TestCase
    public func testTransactionBeginFailureClosesConnection(): Unit {
        let ds = RMockFailingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        try {
            r.transaction { tx: Tx => 42 }
            @Fail("expected Exception")
        } catch (_: Exception) {
            @Expect(true, true)
        }
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            @Expect(ds.created.get(0).getOrThrow().isClosed(), true)
        }
        r.close()
    }

    @TestCase
    public func testTransactionTxConstructFailureClosesConnection(): Unit {
        let ds = RMockTxFailDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        try {
            r.transaction { tx: Tx => 42 }
            @Fail("expected Exception")
        } catch (_: Exception) {
            @Expect(true, true)
        }
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            @Expect(ds.created.get(0).getOrThrow().isClosed(), true)
        }
        r.close()
    }

    @TestCase
    public func testTransactionIsolationTxConstructFailureClosesConnection(): Unit {
        let ds = RMockTxFailDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        try {
            r.transaction(IsolationLevel.Serializable) { tx: Tx => 42 }
            @Fail("expected Exception")
        } catch (_: Exception) {
            @Expect(true, true)
        }
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            @Expect(ds.created.get(0).getOrThrow().isClosed(), true)
        }
        r.close()
    }

    @TestCase
    public func testHookRegister(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let flag = RFlag()
        r.hook<Int64>("E", HookKind.BeforeSave) { scope: Scope<Int64> => flag.v = true }
        let s = Scope<Int64>(1)
        r.executeHooks("E", HookKind.BeforeSave, s)
        @Expect(flag.v, true)
        r.close()
    }

    @TestCase
    public func testHookAbort(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        r.hook<Int64>("E", HookKind.BeforeSave) { scope: Scope<Int64> =>
            scope.abort(Exception("stop"))
        }
        let s = Scope<Int64>(1)
        let err = r.executeHooks("E", HookKind.BeforeSave, s)
        @Expect(err.isSome(), true)
        r.close()
    }

    @TestCase
    public func testHookNonexistent(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let s = Scope<Int64>(1)
        let err = r.executeHooks("X", HookKind.BeforeSave, s)
        @Expect(err.isNone(), true)
        r.close()
    }

    @TestCase
    public func testTxHookKind(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let flag = RFlag()
        r.hook<Int64>("E", HookKind.TxBeforeCreate) { scope: Scope<Int64> => flag.v = true }
        let s = Scope<Int64>(1)
        r.executeHooks("E", HookKind.TxBeforeCreate, s)
        @Expect(flag.v, true)
        // TxBeforeCreate should NOT fire for BeforeCreate
        let s2 = Scope<Int64>(1)
        let flag2 = RFlag()
        r.hook<Int64>("E", HookKind.BeforeCreate) { scope: Scope<Int64> => flag2.v = true }
        r.executeHooks("E", HookKind.BeforeCreate, s2)
        @Expect(flag2.v, true)
        r.close()
    }

    @TestCase
    public func testTxHookAbort(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        r.hook<Int64>("E", HookKind.TxBeforeUpdate) { scope: Scope<Int64> =>
            scope.abort(Exception("tx stop"))
        }
        let s = Scope<Int64>(1)
        let err = r.executeHooks("E", HookKind.TxBeforeUpdate, s)
        @Expect(err.isSome(), true)
        r.close()
    }

    @TestCase
    public func testTxHookDeleteAbort(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        r.hook<Int64>("E", HookKind.TxBeforeDelete) { scope: Scope<Int64> =>
            scope.abort(Exception("tx delete stop"))
        }
        let s = Scope<Int64>(1)
        let err = r.executeHooks("E", HookKind.TxBeforeDelete, s)
        @Expect(err.isSome(), true)
        r.close()
    }

    @TestCase
    public func testAll(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.all(q)
        @Expect(result.size, 0)
        r.close()
    }

    @TestCase
    public func testOne(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.one(q)
        @Expect(result.isNone(), true)
        r.close()
    }

    @TestCase
    public func testMigrator(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        r.migrator()
        @Expect(true, true)
        r.close()
    }

    @TestCase
    public func testExtractDriver(): Unit {
        @Expect(extractDriver("sqlite://test.db"), "sqlite")
        @Expect(extractDriver("mysql://localhost:3306/db"), "mysql")
        @Expect(extractDriver("mariadb://host:3306/db"), "mariadb")
        @Expect(extractDriver("postgresql://host/db"), "postgresql")
        @Expect(extractDriver("noscheme"), "sqlite")
    }

    @TestCase
    public func testDetectDialect(): Unit {
        @Expect(detectDialect("sqlite").name(), "sqlite")
        @Expect(detectDialect("mysql").name(), "mysql")
        @Expect(detectDialect("mariadb").name(), "mysql")
        @Expect(detectDialect("postgres").name(), "postgresql")
        @Expect(detectDialect("postgresql").name(), "postgresql")
        @Expect(detectDialect("unknown").name(), "sqlite")
    }

    // I9: Refine.all 不得修改调用方 Query 的状态（queryDialect/columnOffset/executor）。
    @TestCase
    public func testAllDoesNotMutateQuery(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.all(q)
        @Expect(result.size, 0)
        @Expect(q.queryDialect.isNone(), true)
        @Expect(q.columnOffset, 0)
        @Expect(q.executor.isNone(), true)
        r.close()
    }

    // I9: Refine.one 不得修改调用方 Query 的状态。
    @TestCase
    public func testOneDoesNotMutateQuery(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.one(q)
        @Expect(result.isNone(), true)
        @Expect(q.queryDialect.isNone(), true)
        @Expect(q.columnOffset, 0)
        @Expect(q.executor.isNone(), true)
        r.close()
    }

    // I9: 同一个 Query 对象先后复用多次，调用后仍保持原始状态（无并发/复用竞态污染）。
    @TestCase
    public func testQueryReusableAcrossAllCalls(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let r1 = r.all(q)
        let r2 = r.all(q)
        @Expect(r1.size, 0)
        @Expect(r2.size, 0)
        @Expect(q.executor.isNone(), true)
        @Expect(q.queryDialect.isNone(), true)
        r.close()
    }

    // I9: all() 成功路径，底层连接恰好关闭一次（closeExecutor 与 finally 不重复 close）。
    @TestCase
    public func testAllClosesSessionOnce(): Unit {
        let ds = RMockCountDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.all(q)
        @Expect(result.size, 0)
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            let c = ds.created.get(0).getOrThrow()
            @Expect(c.closeCount, 1)
        }
        r.close()
    }

    // I9: one() 成功路径，底层连接恰好关闭一次。
    @TestCase
    public func testOneClosesSessionOnce(): Unit {
        let ds = RMockCountDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.one(q)
        @Expect(result.isNone(), true)
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            let c = ds.created.get(0).getOrThrow()
            @Expect(c.closeCount, 1)
        }
        r.close()
    }

    // I9: all() 异常路径，session 仍被 finally 关闭，且只关闭一次。
    @TestCase
    public func testAllClosesSessionOnException(): Unit {
        let ds = RMockThrowingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        try {
            r.all(q)
            @Fail("expected exception")
        } catch (_: Exception) {
            @Expect(true, true)
        }
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            let c = ds.created.get(0).getOrThrow()
            @Expect(c.closeCount, 1)
        }
        r.close()
    }

    // I9: one() 异常路径，session 仍被 finally 关闭，且只关闭一次。
    @TestCase
    public func testOneClosesSessionOnException(): Unit {
        let ds = RMockThrowingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        try {
            r.one(q)
            @Fail("expected exception")
        } catch (_: Exception) {
            @Expect(true, true)
        }
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            let c = ds.created.get(0).getOrThrow()
            @Expect(c.closeCount, 1)
        }
        r.close()
    }
}
