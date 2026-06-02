package refine

import std.database.sql.*
import std.collection.HashMap
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
}
