package refine

import std.database.sql.{Connection, Transaction, QueryResult, UpdateResult, ColumnInfo, ConnectionState, TransactionAccessMode, TransactionDeferrableMode, TransactionIsoLevel, SqlDbType, Datasource, DriverManager, Driver}
import std.database.sql.Statement as SqlStatement
import std.collection.{HashMap, ArrayList}
import std.unittest.*
import std.unittest.testmacro.*

class MockColumnInfo <: ColumnInfo {
    public prop displaySize: Int64 { get() { _displaySize } }
    public prop length: Int64 { get() { _length } }
    public prop name: String { get() { _name } }
    public prop nullable: Bool { get() { _nullable } }
    public prop scale: Int64 { get() { _scale } }
    public prop typeName: String { get() { _typeName } }

    private var _displaySize: Int64 = 0
    private var _length: Int64 = 0
    private var _name: String = ""
    private var _nullable: Bool = false
    private var _scale: Int64 = 0
    private var _typeName: String = ""

    public init() {}

    public init(name: String) {
        this._name = name
    }
}

class MockUpdateResult <: UpdateResult {
    public prop lastInsertId: Int64 { get() { _lastInsertId } }
    public prop rowCount: Int64 { get() { _rowCount } }

    private var _lastInsertId: Int64 = 0
    private var _rowCount: Int64 = 0
}

class MockQueryResult <: QueryResult {
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop columnInfos: Array<ColumnInfo> { get() { _columnInfos } }

    private var _columnInfos: Array<ColumnInfo> = []
    public var rowAvailable: Bool = false

    public init() {}

    public init(columnInfos: Array<ColumnInfo>) {
        this._columnInfos = columnInfos
    }

    public func next(): Bool {
        if (rowAvailable) {
            rowAvailable = false
            return true
        }
        false
    }
    public func next(_values: Array<SqlDbType>): Bool { next() }
    public func get<T>(index: Int): T { throw Exception("not implemented") }
    public func getOrNull<T>(index: Int): ?T { None }
}

class MockTransaction <: Transaction {
    public var isoLevelSet: ?TransactionIsoLevel = None

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
        set(v) {
            _isoLevel = v
            isoLevelSet = Some(v)
        }
    }

    private var _accessMode: TransactionAccessMode = TransactionAccessMode.ReadWrite
    private var _deferrableMode: TransactionDeferrableMode = TransactionDeferrableMode.NotDeferrable
    private var _isoLevel: TransactionIsoLevel = TransactionIsoLevel.Serializable

    public func begin(): Unit {}
    public func commit(): Unit {}
    public func release(_: String): Unit {}
    public func rollback(): Unit {}
    public func rollback(_: String): Unit {}
    public func save(_: String): Unit {}
}

class MockStatement <: SqlStatement {
    public var lastSetType: String = ""
    public var lastSetIndex: Int = -1
    public var lastSetValue: Any = 0
    public var queryColumnInfos: Array<ColumnInfo> = []
    public var queryRow: Bool = false

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { _parameterColumnInfos } }

    private var _parameterColumnInfos: Array<ColumnInfo> = []

    public func query(): QueryResult {
        let r = MockQueryResult(queryColumnInfos)
        r.rowAvailable = queryRow
        r
    }
    public func query(_params: Array<SqlDbType>): QueryResult { query() }
    public func set<T>(index: Int, value: T): Unit {
        lastSetType = "set"
        lastSetIndex = index
        lastSetValue = value
    }
    public func setNull(index: Int): Unit {
        lastSetType = "setNull"
        lastSetIndex = index
    }
    public func setOption(_key: String, value: String): Unit {}
    public func update(): UpdateResult { MockUpdateResult() }
    public func update(_params: Array<SqlDbType>): UpdateResult { MockUpdateResult() }
}

class MockConnection <: Connection {
    public var queryColumnInfos: Array<ColumnInfo> = []
    public var queryRow: Bool = false
    public var createdTxns = ArrayList<MockTransaction>()

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop state: ConnectionState { get() { _state } }

    private var _state: ConnectionState = ConnectionState.Connected

    public func createTransaction(): Transaction {
        let t = MockTransaction()
        createdTxns.add(t)
        t
    }
    public func getMetaData(): HashMap<String, String> { HashMap<String, String>() }
    public func prepareStatement(sql: String): SqlStatement {
        let s = MockStatement()
        s.queryColumnInfos = this.queryColumnInfos
        s.queryRow = this.queryRow
        s
    }
}

class MockDatasource <: Datasource {
    public var closed: Bool = false
    public var createdConns = ArrayList<MockConnection>()

    public func connect(): Connection {
        let c = MockConnection()
        createdConns.add(c)
        c
    }

    public func close(): Unit {
        closed = true
    }

    public func isClosed(): Bool {
        closed
    }

    public func setOption(key: String, value: String): Unit {}
}

class MockDriver <: Driver {
    public prop name: String { get() { "mock" } }
    public prop preferredPooling: Bool { get() { false } }
    public prop version: String { get() { "1.0" } }

    public func open(connectionString: String, opts: Array<(String, String)>): Datasource {
        MockDatasource()
    }
}

@Test
public class DbTest {
    @TestCase
    public func testSessionGetDialect(): Unit {
        let conn = MockConnection()
        let session = Session(conn)
        let dialect = session.getDialect()
        @Expect(dialect.name(), "sqlite")
    }

    @TestCase
    public func testSessionConstruct(): Unit {
        let conn = MockConnection()
        let session = Session(conn)
        @Expect(session.getDialect().name(), "sqlite")
    }

    @TestCase
    public func testTxConstruct(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        @Expect(true, true)
    }

    @TestCase
    public func testTxBeginCommit(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.commit()
        @Expect(true, true)
    }

    @TestCase
    public func testTxRollback(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.rollback()
        @Expect(true, true)
    }

    @TestCase
    public func testTxSaveAndRollbackTo(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.save("sp1")
        tx.rollbackTo("sp1")
        tx.commit()
        @Expect(true, true)
    }

    // ─── M19: Tx 状态防护 ──────────────────────────────
    // 未 begin / 已 commit / 已 rollback 的 Tx 上执行 SQL、savepoint、重复 begin、
    // 状态外 commit/rollback 都必须抛 RefineException；正常 begin→commit 流程不抛。

    @TestCase
    public func testTxExecuteWithoutBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        try {
            tx.execute("UPDATE t SET x = ?", [1])
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxQueryWithoutBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        try {
            tx.query("SELECT * FROM t", [])
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxCommitWithoutBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        try {
            tx.commit()
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxRollbackWithoutBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        try {
            tx.rollback()
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxRepeatedBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        try {
            tx.begin()
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction already begun")
        }
    }

    @TestCase
    public func testTxExecuteAfterCommitThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.commit()
        try {
            tx.execute("UPDATE t SET x = ?", [1])
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxExecuteAfterRollbackThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.rollback()
        try {
            tx.execute("UPDATE t SET x = ?", [1])
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxRollbackAfterCommitThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.commit()
        try {
            tx.rollback()
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxCommitAfterRollbackThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.rollback()
        try {
            tx.commit()
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxSavepointWithoutBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        try {
            tx.save("sp1")
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxRollbackToWithoutBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        try {
            tx.rollbackTo("sp1")
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxBeginCommitExecuteNormalFlow(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        let result = tx.execute("UPDATE t SET x = ?", [1])
        tx.commit()
        @Expect(result.rowCount, 0)
    }

    @TestCase
    public func testDispatchSetInt64(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, 42)
        @Expect(stmt.lastSetType, "set")
        @Expect(stmt.lastSetIndex, 0)
    }

    @TestCase
    public func testDispatchSetInt32(): Unit {
        let stmt = MockStatement()
        let v: Int32 = 42
        dispatchSet(stmt, 1, v)
        @Expect(stmt.lastSetType, "set")
        @Expect(stmt.lastSetIndex, 1)
    }

    // ─── R-C2: 窄整数/单精度浮点绑定回归 ────────────────────────────────
    // 宏层接受这些类型作实体字段（映射 BIGINT/DOUBLE），修复前 dispatchSet 无对应
    // 分支落 setNull（可空列静默写 NULL）。修复后按存储表示换算：整数列绑定 Int64、
    // Float32 绑定 Float64，断言 mock 收到的绑定值与换算结果一致。

    @TestCase
    public func testDispatchSetInt8(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, Int8(-5))
        @Expect(stmt.lastSetType, "set")
        @Expect(stmt.lastSetIndex, 0)
        @Expect((stmt.lastSetValue as Int64).getOrThrow(), -5)
    }

    @TestCase
    public func testDispatchSetInt16(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, Int16(-1000))
        @Expect(stmt.lastSetType, "set")
        @Expect((stmt.lastSetValue as Int64).getOrThrow(), -1000)
    }

    @TestCase
    public func testDispatchSetUInt8(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, UInt8(200))
        @Expect(stmt.lastSetType, "set")
        @Expect((stmt.lastSetValue as Int64).getOrThrow(), 200)
    }

    @TestCase
    public func testDispatchSetUInt16(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, UInt16(60000))
        @Expect(stmt.lastSetType, "set")
        @Expect((stmt.lastSetValue as Int64).getOrThrow(), 60000)
    }

    @TestCase
    public func testDispatchSetUInt32(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, UInt32(4000000000))
        @Expect(stmt.lastSetType, "set")
        @Expect((stmt.lastSetValue as Int64).getOrThrow(), 4000000000)
    }

    @TestCase
    public func testDispatchSetUInt64(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, UInt64(9000000000))
        @Expect(stmt.lastSetType, "set")
        @Expect((stmt.lastSetValue as Int64).getOrThrow(), 9000000000)
    }

    @TestCase
    public func testDispatchSetFloat32(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 0, Float32(1.5))
        @Expect(stmt.lastSetType, "set")
        @Expect((stmt.lastSetValue as Float64).getOrThrow(), 1.5)
    }

    @TestCase
    public func testDispatchSetString(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 2, "hello")
        @Expect(stmt.lastSetType, "set")
        @Expect(stmt.lastSetIndex, 2)
    }

    @TestCase
    public func testDispatchSetBool(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 3, true)
        @Expect(stmt.lastSetType, "set")
        @Expect(stmt.lastSetIndex, 3)
    }

    @TestCase
    public func testDispatchSetFloat64(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 4, 3.14)
        @Expect(stmt.lastSetType, "set")
        @Expect(stmt.lastSetIndex, 4)
    }

    // R-C2: 未知类型不再静默 setNull——抛 RefineException 并提示支持的参数类型，
    // 杜绝「合法字段类型保存成 NULL」这类静默数据损坏的根源（修复前是 setNull）。
    @TestCase
    public func testDispatchSetUnknownTypeThrows(): Unit {
        let stmt = MockStatement()
        try {
            dispatchSet(stmt, 5, (1, 2))
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message.contains("unsupported param type for dispatchSet"), true)
        }
    }

    // R-C2: 窄整数经换算后若超 Int64 表示范围（UInt64 > Int64.max），转换抛运行时
    // 异常而非静默写错值——BIGINT 有符号列本就存不下该值，显式报错优于数据损坏。
    @TestCase
    public func testDispatchSetUInt64OverflowThrows(): Unit {
        let stmt = MockStatement()
        try {
            dispatchSet(stmt, 5, UInt64.Max)
            @Fail("expected exception")
        } catch (_: Exception) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testSessionPrepareStatement(): Unit {
        let conn = MockConnection()
        let session = Session(conn)
        let stmt = session.prepareStatement("SELECT 1")
        @Expect(stmt.parameterColumnInfos.size, 0)
    }

    @TestCase
    public func testSessionExecute(): Unit {
        let conn = MockConnection()
        let session = Session(conn)
        let result = session.execute("UPDATE t SET x = ?", [1])
        @Expect(result.rowCount, 0)
    }

    @TestCase
    public func testSessionQuery(): Unit {
        let conn = MockConnection()
        let session = Session(conn)
        let result = session.query("SELECT * FROM t WHERE id = ?", [1])
        @Expect(result.columnInfos.size, 0)
    }

    @TestCase
    public func testTxPrepareStatement(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        let stmt = tx.prepareStatement("SELECT 1")
        @Expect(stmt.parameterColumnInfos.size, 0)
    }

    // Fix 2 (M19 评审): prepareStatement 是最后一个未加状态守卫的 SQL 能力入口，
    // 与 execute/query 一致要求 Active，否则 `tx.prepareStatement(sql).update()`
    // 可在事务结束后绕过状态机继续发 SQL。
    @TestCase
    public func testTxPrepareStatementWithoutBeginThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        try {
            tx.prepareStatement("SELECT 1")
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxPrepareStatementAfterCommitThrows(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        tx.commit()
        try {
            tx.prepareStatement("SELECT 1")
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(e.message, "transaction is not active")
        }
    }

    @TestCase
    public func testTxExecute(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        let result = tx.execute("UPDATE t SET x = ?", [1])
        @Expect(result.rowCount, 0)
    }

    @TestCase
    public func testTxQuery(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        let result = tx.query("SELECT * FROM t WHERE id = ?", [1])
        @Expect(result.columnInfos.size, 0)
    }

    @TestCase
    public func testDBInit(): Unit {
        let ds = MockDatasource()
        let db = DB(ds)
        let session = db.session()
        @Expect(session.getDialect().name(), "sqlite")
    }

    @TestCase
    public func testDBOpenSQLite(): Unit {
        let ds = MockDatasource()
        let db = DB(ds)
        @Expect(db.getDialect().name(), "sqlite")
    }

    @TestCase
    public func testDBClose(): Unit {
        let ds = MockDatasource()
        let db = DB(ds)
        db.close()
        @Expect(ds.closed, true)
    }

    @TestCase
    public func testDBTransactionCommit(): Unit {
        let ds = MockDatasource()
        let db = DB(ds)
        let result = db.transaction({ tx => "committed" })
        @Expect(result, "committed")
    }

    @TestCase
    public func testDBTransactionRollback(): Unit {
        let ds = MockDatasource()
        let db = DB(ds)
        try {
            db.transaction({ tx => throw Exception("rollback") })
            @Expect(false, true)
        } catch (e: Exception) {
            @Expect(e.message, "rollback")
        }
    }

    @TestCase
    public func testDBTransactionClosesConnectionOnCommit(): Unit {
        let ds = RMockTrackingDS()
        let db = DB(ds)
        let result = db.transaction({ tx => "committed" })
        @Expect(result, "committed")
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            @Expect(ds.created.get(0).getOrThrow().isClosed(), true)
        }
    }

    @TestCase
    public func testDBTransactionClosesConnectionOnRollback(): Unit {
        let ds = RMockTrackingDS()
        let db = DB(ds)
        try {
            db.transaction({ tx => throw Exception("rollback") })
            @Expect(false, true)
        } catch (e: Exception) {
            @Expect(e.message, "rollback")
        }
        @Expect(ds.created.size, 1)
        if (ds.created.size > 0) {
            @Expect(ds.created.get(0).getOrThrow().isClosed(), true)
        }
    }

    // Fix 1 (M19 评审): action 内手动 commit 后又抛异常时，DB.transaction 的
    // 回滚路径不得遮蔽原始异常（best-effort 回滚，始终抛原始异常）。
    @TestCase
    public func testDBTransactionActionCommitThenThrowKeepsOriginal(): Unit {
        let ds = RMockTrackingDS()
        let db = DB(ds)
        try {
            db.transaction({ tx: Tx => tx.commit(); throw Exception("original failure") })
            @Fail("expected Exception")
        } catch (e: Exception) {
            @Expect(e.message, "original failure")
        }
        @Expect(ds.created.size, 1)
    }

    @TestCase
    public func testDBOpenWithParamOffset(): Unit {
        let ds = MockDatasource()
        let db = DB(ds, 1)
        db.close()
        @Expect(true, true)
    }

    @TestCase
    public func testSessionQueryAllEmpty(): Unit {
        let conn = MockConnection()
        let session = Session(conn)
        let result = session.queryAll("SELECT * FROM t", [],
            { r: QueryResult, cm: HashMap<String, Int64> => 42 })
        @Expect(result.size, 0)
    }

    @TestCase
    public func testSessionQueryOneEmpty(): Unit {
        let conn = MockConnection()
        let session = Session(conn)
        // R-C2: 参数显式 Array<Any> 传 Int64——修复前 `[1 as Any]` 是 Some(1)
        //（Option），靠 dispatchSet 落 setNull 兜底；未知类型改抛错后该写法不可用。
        let params: Array<Any> = [1]
        let result = session.queryOne("SELECT * FROM t WHERE id = ?", params,
            { r: QueryResult, cm: HashMap<String, Int64> => 42 })
        @Expect(result.isNone(), true)
    }

    @TestCase
    public func testTxQueryAllEmpty(): Unit {
        let rf = Refine(MockDatasource(), SQLiteDialect(), 0)
        let conn = MockConnection()
        let tx = Tx(conn, rf, 0)
        tx.begin()
        let result = tx.queryAll("SELECT * FROM t", [],
            { r: QueryResult, cm: HashMap<String, Int64> => 42 })
        @Expect(result.size, 0)
    }

    @TestCase
    public func testTxQueryOneEmpty(): Unit {
        let rf = Refine(MockDatasource(), SQLiteDialect(), 0)
        let conn = MockConnection()
        let tx = Tx(conn, rf, 0)
        tx.begin()
        let params: Array<Any> = [1]
        let result = tx.queryOne("SELECT * FROM t WHERE id = ?", params,
            { r: QueryResult, cm: HashMap<String, Int64> => 42 })
        @Expect(result.isNone(), true)
    }

    @TestCase
    public func testTxQueryAllWithoutRef(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        let result = tx.queryAll("SELECT * FROM t", [],
            { r: QueryResult, cm: HashMap<String, Int64> => 42 })
        @Expect(result.size, 0)
    }

    @TestCase
    public func testTxQueryOneWithoutRef(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        tx.begin()
        let params: Array<Any> = [1]
        let result = tx.queryOne("SELECT * FROM t WHERE id = ?", params,
            { r: QueryResult, cm: HashMap<String, Int64> => 42 })
        @Expect(result.isNone(), true)
    }

    @TestCase
    public func testDBWithMySQLDialect(): Unit {
        let db = DB(MockDatasource(), MySQLDialect())
        @Expect(db.getDialect().name(), "mysql")
    }

    @TestCase
    public func testDBWithPostgreSQLDialect(): Unit {
        let db = DB(MockDatasource(), PostgreSQLDialect())
        @Expect(db.getDialect().name(), "postgresql")
    }

    @TestCase
    public func testDBDefaultDialectIsSQLite(): Unit {
        let db = DB(MockDatasource())
        @Expect(db.getDialect().name(), "sqlite")
    }

    @TestCase
    public func testDBFullInitWithParamOffsetAndDialect(): Unit {
        let db = DB(MockDatasource(), 1, MySQLDialect())
        @Expect(db.getDialect().name(), "mysql")
        let s = db.session()
        @Expect(s.getParamOffset(), 1)
        s.close()
    }

    @TestCase
    public func testDBSessionCarriesDialect(): Unit {
        let db = DB(MockDatasource(), MySQLDialect())
        let s = db.session()
        @Expect(s.getDialect().name(), "mysql")
        s.close()
    }

    @TestCase
    public func testDBTransactionCarriesDialect(): Unit {
        let db = DB(MockDatasource(), PostgreSQLDialect())
        let name = db.transaction({ tx => tx.getDialect().name() })
        @Expect(name, "postgresql")
    }

    @TestCase
    public func testDBMigratorWithMySQLDialect(): Unit {
        let db = DB(MockDatasource(), MySQLDialect())
        let m = db.migrator()
        let isMySql = match (m) { case _: MySQLMigrator => true; case _ => false }
        @Expect(isMySql, true)
    }

    @TestCase
    public func testDBMigratorWithPostgreSQLDialect(): Unit {
        let db = DB(MockDatasource(), PostgreSQLDialect())
        let m = db.migrator()
        let isPg = match (m) { case _: PostgreSQLMigrator => true; case _ => false }
        @Expect(isPg, true)
    }

    @TestCase
    public func testDBMigratorDefaultIsSQLite(): Unit {
        let db = DB(MockDatasource())
        let m = db.migrator()
        let isSqlite = match (m) { case _: SQLiteMigrator => true; case _ => false }
        @Expect(isSqlite, true)
    }

    @TestCase
    public func testSessionWithDialect(): Unit {
        let s = Session(MockConnection(), 0, MySQLDialect())
        @Expect(s.getDialect().name(), "mysql")
    }

    @TestCase
    public func testTxWithDialect(): Unit {
        let tx = Tx(MockConnection(), 0, PostgreSQLDialect())
        tx.begin()
        @Expect(tx.getDialect().name(), "postgresql")
    }

    @TestCase
    public func testDBOpenWithMySQLURL(): Unit {
        DriverManager.deregister("mysql")
        DriverManager.register("mysql", MockDriver())
        try {
            let db = DB.open("mysql://localhost:3306/testdb")
            @Expect(db.getDialect().name(), "mysql")
            db.close()
        } finally {
            DriverManager.deregister("mysql")
        }
    }

    @TestCase
    public func testDBOpenWithPostgresURL(): Unit {
        DriverManager.deregister("postgresql")
        DriverManager.register("postgresql", MockDriver())
        try {
            let db = DB.open("postgresql://localhost:5432/testdb")
            @Expect(db.getDialect().name(), "postgresql")
            db.close()
        } finally {
            DriverManager.deregister("postgresql")
        }
    }

    @TestCase
    public func testDBOpenWithMariaDBURL(): Unit {
        let realDrv = DriverManager.getDriver("mariadb")
        DriverManager.deregister("mariadb")
        DriverManager.register("mariadb", MockDriver())
        try {
            let db = DB.open("mariadb://localhost:3306/testdb")
            @Expect(db.getDialect().name(), "mysql")
            let s = db.session()
            @Expect(s.getParamOffset(), 1)
            s.close()
            db.close()
        } finally {
            DriverManager.deregister("mariadb")
            if (let Some(drv) <- realDrv) {
                DriverManager.register("mariadb", drv)
            }
        }
    }

    @TestCase
    public func testTxSetIsolationDBPathMySQL(): Unit {
        let ds = MockDatasource()
        let db = DB(ds, MySQLDialect())
        db.transaction({ tx => tx.setIsolation(IsolationLevel.Serializable) })
        @Expect(ds.createdConns.size, 1)
        if (ds.createdConns.size > 0) {
            let conn = ds.createdConns.get(0).getOrThrow()
            @Expect(conn.createdTxns.size, 1)
            if (conn.createdTxns.size > 0) {
                let txn = conn.createdTxns.get(0).getOrThrow()
                @Expect(txn.isoLevelSet.isSome(), true)
                @Expect(txn.isoLevelSet.getOrThrow(), TransactionIsoLevel.Serializable)
            }
        }
    }

    @TestCase
    public func testTxSetIsolationDBPathSQLite(): Unit {
        let db = DB(MockDatasource())
        try {
            db.transaction({ tx => tx.setIsolation(IsolationLevel.Serializable) })
            @Expect(false, true)
        } catch (e: RefineException) {
            // M5: 错误信息方言感知（dialect.name() 小写 sqlite），不再硬编码 "SQLite"
            @Expect(e.message, "sqlite does not support transaction isolation levels")
        }
    }

    @TestCase
    public func testSessionQueryAllColumnOffsetDBPath(): Unit {
        let conn = MockConnection()
        conn.queryColumnInfos = [MockColumnInfo("id"), MockColumnInfo("name")]
        conn.queryRow = true
        let s = Session(conn, 1, MySQLDialect())
        let seen = ArrayList<HashMap<String, Int64>>()
        s.queryAll("SELECT * FROM t", [],
            { r: QueryResult, cm: HashMap<String, Int64> => seen.add(cm); 0 })
        @Expect(seen.size, 1)
        if (seen.size > 0) {
            let cm = seen.get(0).getOrThrow()
            @Expect(cm.get("id").getOrThrow(), 1)
            @Expect(cm.get("name").getOrThrow(), 2)
        }
    }

    @TestCase
    public func testTxQueryOneColumnOffsetDBPath(): Unit {
        let conn = MockConnection()
        conn.queryColumnInfos = [MockColumnInfo("id"), MockColumnInfo("name")]
        conn.queryRow = true
        let tx = Tx(conn, 1, PostgreSQLDialect())
        tx.begin()
        let seen = ArrayList<HashMap<String, Int64>>()
        tx.queryOne("SELECT * FROM t", [],
            { r: QueryResult, cm: HashMap<String, Int64> => seen.add(cm); 0 })
        @Expect(seen.size, 1)
        if (seen.size > 0) {
            let cm = seen.get(0).getOrThrow()
            @Expect(cm.get("id").getOrThrow(), 1)
            @Expect(cm.get("name").getOrThrow(), 2)
        }
    }
}
