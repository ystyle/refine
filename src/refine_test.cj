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

// R-M19: connect() 必抛异常，用于验证 detectServerDialect 探测连接失败时回退 MySQLDialect。
class RMockConnFailDS <: Datasource {
    public func connect(): Connection { throw Exception("mock connect failure") }
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
        let ds = RMockTrackingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        let s = r.session()
        @Expect(s.getParamOffset(), 0)
        s.close()
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            @Expect(ds.created.get(0).getOrThrow().isClosed(), true)
        }
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

    // Fix 1 (M19 评审): action 内手动 commit 后又抛异常时，包装器的回滚路径
    // 不能把原始异常遮蔽成 "transaction is not active"。回滚改为 best-effort，
    // 始终向上传播原始异常。
    @TestCase
    public func testTransactionActionCommitThenThrowKeepsOriginal(): Unit {
        let ds = RMockTrackingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        try {
            r.transaction { tx: Tx => tx.commit(); throw Exception("original failure") }
            @Fail("expected Exception")
        } catch (e: Exception) {
            @Expect(e.message, "original failure")
        }
        r.close()
    }

    @TestCase
    public func testTransactionActionCommitThenThrowClosesConnection(): Unit {
        let ds = RMockTrackingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        try {
            r.transaction { tx: Tx => tx.commit(); throw Exception("original failure") }
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

    // R-M12: action 内手动 commit 后，包装器不得再次 commit（否则 M19 守卫抛
    // "transaction is not active"），应正常返回——手动 commit 被尊重。
    @TestCase
    public func testTransactionActionManualCommitReturnsNormally(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let result = r.transaction { tx: Tx => tx.commit(); 42 }
        @Expect(result, 42)
        r.close()
    }

    // R-M12: 隔离级别重载同样尊重手动 commit。
    @TestCase
    public func testTransactionLevelActionManualCommitReturnsNormally(): Unit {
        let r = Refine(RMockDS(), MySQLDialect(), 0)
        let result = r.transaction(IsolationLevel.Serializable) { tx: Tx => tx.commit(); 42 }
        @Expect(result, 42)
        r.close()
    }

    // R-M12: 手动 commit 后连接仍被 finally 关闭（不泄漏）。
    @TestCase
    public func testTransactionActionManualCommitClosesConnection(): Unit {
        let ds = RMockTrackingDS()
        let r = Refine(ds, SQLiteDialect(), 0)
        let result = r.transaction { tx: Tx => tx.commit(); 42 }
        @Expect(result, 42)
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
        r.hook<Int64>("E", HookKind.TxBeforeUpdate) { scope: Scope<Int64> => flag.v = true }
        let s = Scope<Int64>(1)
        r.executeHooks("E", HookKind.TxBeforeUpdate, s)
        @Expect(flag.v, true)
        r.close()
    }

    @TestCase
    public func testHookAbort(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        r.hook<Int64>("E", HookKind.TxBeforeUpdate) { scope: Scope<Int64> =>
            scope.abort(Exception("stop"))
        }
        let s = Scope<Int64>(1)
        let err = r.executeHooks("E", HookKind.TxBeforeUpdate, s)
        @Expect(err.isSome(), true)
        r.close()
    }

    @TestCase
    public func testHookNonexistent(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let s = Scope<Int64>(1)
        let err = r.executeHooks("X", HookKind.TxBeforeUpdate, s)
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
        // TxBeforeCreate should NOT fire for a different kind (TxAfterCreate)
        let s2 = Scope<Int64>(1)
        let flag2 = RFlag()
        r.hook<Int64>("E", HookKind.TxAfterCreate) { scope: Scope<Int64> => flag2.v = true }
        r.executeHooks("E", HookKind.TxAfterCreate, s2)
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
        let m = r.migrator()
        match (m) {
            case _: SQLiteMigrator => ()
            case _ => @Fail("expected SQLiteMigrator for SQLite dialect")
        }
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

    // R-M19: 运行时服务器类型探测的纯解析函数。SELECT VERSION() 返回串含 "MariaDB"
    // → MariaDBDialect，否则 MySQLDialect（URL 协议不可靠，mariadb:// 可连真实 MySQL）。
    @TestCase
    public func testParseServerVersion(): Unit {
        @Expect(parseServerVersion("11.8.8-MariaDB-ubu2404").name(), "mariadb")
        @Expect(parseServerVersion("10.11.6-MariaDB").name(), "mariadb")
        @Expect(parseServerVersion("9.7.0").name(), "mysql")
        @Expect(parseServerVersion("8.0.36-community").name(), "mysql")
        @Expect(parseServerVersion("").name(), "mysql")
    }

    // R-M19: detectServerDialect 对非 mariadb 驱动不做探测（直接走静态 detectDialect）。
    // 用 connect/prepareStatement 必抛的 RMockThrowingDS 证明：若探测被触发会抛异常，
    // 而非 mariadb 驱动能正常返回对应方言。
    @TestCase
    public func testDetectServerDialectSkipsProbeForNonMaria(): Unit {
        @Expect(detectServerDialect("sqlite", RMockThrowingDS()).name(), "sqlite")
        @Expect(detectServerDialect("mysql", RMockThrowingDS()).name(), "mysql")
        @Expect(detectServerDialect("postgres", RMockThrowingDS()).name(), "postgresql")
        @Expect(detectServerDialect("postgresql", RMockThrowingDS()).name(), "postgresql")
        @Expect(detectServerDialect("unknown", RMockThrowingDS()).name(), "sqlite")
    }

    // R-M19: mariadb 驱动探测执行 SELECT VERSION() 抛异常（prepareStatement 失败）
    // → 回退 MySQLDialect，不阻断打开。
    @TestCase
    public func testDetectServerDialectProbeThrowsFallsBackToMySQL(): Unit {
        @Expect(detectServerDialect("mariadb", RMockThrowingDS()).name(), "mysql")
    }

    // R-M19: 探测连接本身失败（connect 抛异常）→ 回退 MySQLDialect。
    @TestCase
    public func testDetectServerDialectConnectThrowsFallsBackToMySQL(): Unit {
        @Expect(detectServerDialect("mariadb", RMockConnFailDS()).name(), "mysql")
    }

    // R-M19: 探测查询无结果（result.next() 为 false）→ 回退 MySQLDialect。
    @TestCase
    public func testDetectServerDialectEmptyResultFallsBackToMySQL(): Unit {
        @Expect(detectServerDialect("mariadb", MockDatasource()).name(), "mysql")
    }

    // DB 收敛为纯连接层后，URL 方言/paramOffset 探测归属 Refine.open
    // （DB.open 只建 datasource + offset，不再 detectDialect）。
    // R-M19: mariadb 驱动走运行时探测（detectServerDialect）；mock 探测无结果
    // （next()=false）→ 回退 MySQLDialect，故此处 mariadb 断言仍是 "mysql"，仅探测定真。
    @TestCase
    public func testRefineOpenDetectsDialect(): Unit {
        let realMysql = DriverManager.getDriver("mysql")
        let realPg = DriverManager.getDriver("postgresql")
        let realMaria = DriverManager.getDriver("mariadb")
        DriverManager.deregister("mysql")
        DriverManager.register("mysql", MockDriver())
        DriverManager.deregister("postgresql")
        DriverManager.register("postgresql", MockDriver())
        DriverManager.deregister("mariadb")
        DriverManager.register("mariadb", MockDriver())
        try {
            let rf1 = Refine.open("mysql://localhost:3306/testdb")
            @Expect(rf1.getDialect().name(), "mysql")
            @Expect(rf1.getParamOffset(), 0)
            rf1.close()
            let rf2 = Refine.open("postgresql://localhost:5432/testdb")
            @Expect(rf2.getDialect().name(), "postgresql")
            @Expect(rf2.getParamOffset(), 0)
            rf2.close()
            let rf3 = Refine.open("mariadb://localhost:3306/testdb")
            @Expect(rf3.getDialect().name(), "mysql")
            @Expect(rf3.getParamOffset(), 1)
            rf3.close()
        } finally {
            DriverManager.deregister("mysql")
            DriverManager.deregister("postgresql")
            DriverManager.deregister("mariadb")
            if (let Some(drv) <- realMysql) { DriverManager.register("mysql", drv) }
            if (let Some(drv) <- realPg) { DriverManager.register("postgresql", drv) }
            if (let Some(drv) <- realMaria) { DriverManager.register("mariadb", drv) }
        }
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

    // R-I1: rf.all(query) 必须触发 AfterFind hook。修复前 copy().using(session)
    // 走 using(exec: ExecutionContext) 只设 executor/queryDialect/columnOffset 不设 ref，
    // runAfterFindHooks 见 ref=None 静默跳过 hook（query.using(rf).all() 却正常触发）。
    @TestCase
    public func testAllFiresAfterFindHook(): Unit {
        let ds = QueryTrackDatasource()
        let r = Refine(ds, SQLiteDialect(), 0)
        let flag = HookFlag()
        r.hook<Int64>("RfAllHook", HookKind.AfterFind) { scope: Scope<Int64> =>
            flag.called = true
        }
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false)]
        ds.conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.typeName = "RfAllHook"
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.all(q)
        @Expect(result.size, 1)
        @Expect(flag.called, true)
        // 副本上设置 ref，调用方持有的 Query 仍保持未绑定状态
        @Expect(q.ref.isNone(), true)
        r.close()
    }

    // R-I1: rf.one(query) 同样必须触发 AfterFind hook。
    @TestCase
    public func testOneFiresAfterFindHook(): Unit {
        let ds = QueryTrackDatasource()
        let r = Refine(ds, SQLiteDialect(), 0)
        let flag = HookFlag()
        r.hook<Int64>("RfOneHook", HookKind.AfterFind) { scope: Scope<Int64> =>
            flag.called = true
        }
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false)]
        ds.conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.typeName = "RfOneHook"
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let result = r.one(q)
        @Expect(result.isSome(), true)
        @Expect(flag.called, true)
        r.close()
    }

    // R-I1 延续: rf.transaction { tx => query().using(tx).all() } 是最常用查询入口之一。
    // tx 由 Refine.transaction 创建（Tx(conn, this, paramOffset) → ref = Some(this)），
    // 修复前 using(exec) 不传播 ref，此路径静默跳过 AfterFind。
    @TestCase
    public func testTransactionAllFiresAfterFind(): Unit {
        let ds = QueryTrackDatasource()
        let r = Refine(ds, SQLiteDialect(), 0)
        let flag = HookFlag()
        r.hook<Int64>("RfTxAllHook", HookKind.AfterFind) { scope: Scope<Int64> =>
            flag.called = true
        }
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false)]
        ds.conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.typeName = "RfTxAllHook"
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        r.transaction { tx: Tx =>
            let rows = q.using(tx).all()
            @Expect(rows.size, 1)
        }
        @Expect(flag.called, true)
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

    // I9: copy 对 clauses 列表必须是深拷贝。Task 2 后 processIncluded 已是 no-op，
    // 不再追加 JoinClause/改写 SelectClause；本用例保留为 copy 深拷贝隔离的回归——
    // 批量装配（Task 3+）在副本上执行仍要求调用方 Query 的 stmt/included 完全独立。
    // 用 PostWithRel.query() 自带生成 mapper，走真实 include 路径。
    @TestCase
    public func testAllIncludeDoesNotMutateQueryClauses(): Unit {
        let r = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = PostWithRel.query().include(PostWithRelRel.author)
        let clauseCount = q.stmt.clauses.size
        var selectFieldCount: Int64 = -1
        match (q.stmt.clauses[0]) {
            case Clause.SelectClause(fields) => selectFieldCount = fields.size
            case _ => @Fail("expected SelectClause before all()")
        }
        let result = r.all(q)
        @Expect(result.size, 0)
        // 原始 stmt 不得新增任何子句（Task 2 后 processIncluded 为 no-op，不追加 JoinClause）
        @Expect(q.stmt.clauses.size, clauseCount)
        for (clause in q.stmt.clauses) {
            match (clause) {
                case Clause.JoinClause(_, _, _) => @Fail("original query must not gain JoinClause")
                case _ => ()
            }
        }
        // 原始 SelectClause 不得被改写：字段数不变，且仍为未限定列的 Expr.Column。
        match (q.stmt.clauses[0]) {
            case Clause.SelectClause(fields) =>
                @Expect(fields.size, selectFieldCount)
                for (f in fields) {
                    match (f) {
                        case Expr.Column(_) => ()
                        case _ => @Fail("original SELECT must not be rewritten")
                    }
                }
            case _ => @Fail("expected SelectClause")
        }
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

    // R-M11: q.using(rf1) 预绑定 Session，再 rf2.all(q)。修复前 copy.executor 保留 s1，
    // copy.using(s2) 覆盖为 s2，s1 连接泄漏（永不关闭）；修复后预绑定 Session 被关闭。
    @TestCase
    public func testAllClosesPreboundSessionFromUsingRf(): Unit {
        let ds = RMockCountDS()
        let rf1 = Refine(ds, SQLiteDialect(), 0)
        let rf2 = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        q.using(rf1)
        let result = rf2.all(q)
        @Expect(result.size, 0)
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            let c = ds.created.get(0).getOrThrow()
            @Expect(c.closeCount, 1)
        }
        rf1.close()
        rf2.close()
    }

    // R-M11: 同 all，验证 one() 路径预绑定 Session 也被关闭。
    @TestCase
    public func testOneClosesPreboundSessionFromUsingRf(): Unit {
        let ds = RMockCountDS()
        let rf1 = Refine(ds, SQLiteDialect(), 0)
        let rf2 = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        q.using(rf1)
        let result = rf2.one(q)
        @Expect(result.isNone(), true)
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            let c = ds.created.get(0).getOrThrow()
            @Expect(c.closeCount, 1)
        }
        rf1.close()
        rf2.close()
    }

    // R-M11: q.using(session) 预绑定 Session（db.session() 裸会话 + 注入 ref，
    // 原 using(DB) 缺陷 API 已随 DB 收敛移除，显式建会话等价），rf.all(q) 时同样关闭。
    @TestCase
    public func testAllClosesPreboundSessionFromUsingDb(): Unit {
        let ds = RMockCountDS()
        let db = DB(ds)
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let s = db.session()
        s.ref = Some(rf)
        q.using(s)
        let result = rf.all(q)
        @Expect(result.size, 0)
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            let c = ds.created.get(0).getOrThrow()
            @Expect(c.closeCount, 1)
        }
        rf.close()
    }

    // R-M11: 预绑定 Tx 不属于 Refine.all 的生命周期，不得关闭——执行改用新 session 后
    // Tx 仍保持 Active，调用方继续 commit 不抛 "transaction is not active"。
    @TestCase
    public func testAllDoesNotClosePreboundTx(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> => 0 })
        let tx = Tx(RMockConn(), rf, 0)
        tx.begin()
        q.using(tx)
        let result = rf.all(q)
        @Expect(result.size, 0)
        tx.commit()
        @Expect(true, true)
        rf.close()
    }
}
