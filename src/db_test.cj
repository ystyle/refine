package refine

import std.database.sql.{Connection, Transaction, QueryResult, UpdateResult, ColumnInfo, ConnectionState, TransactionAccessMode, TransactionDeferrableMode, TransactionIsoLevel, SqlDbType, Datasource}
import std.database.sql.Statement as SqlStatement
import std.collection.HashMap
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

    public func next(): Bool { false }
    public func next(_values: Array<SqlDbType>): Bool { false }
    public func get<T>(index: Int): T { throw Exception("not implemented") }
    public func getOrNull<T>(index: Int): ?T { None }
}

class MockTransaction <: Transaction {
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

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { _parameterColumnInfos } }

    private var _parameterColumnInfos: Array<ColumnInfo> = []

    public func query(): QueryResult { MockQueryResult() }
    public func query(_params: Array<SqlDbType>): QueryResult { MockQueryResult() }
    public func set<T>(index: Int, value: T): Unit {
        lastSetType = "set"
        lastSetIndex = index
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
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop state: ConnectionState { get() { _state } }

    private var _state: ConnectionState = ConnectionState.Connected

    public func createTransaction(): Transaction { MockTransaction() }
    public func getMetaData(): HashMap<String, String> { HashMap<String, String>() }
    public func prepareStatement(sql: String): SqlStatement { MockStatement() }
}

class MockDatasource <: Datasource {
    public var closed: Bool = false

    public func connect(): Connection {
        MockConnection()
    }

    public func close(): Unit {
        closed = true
    }

    public func isClosed(): Bool {
        closed
    }

    public func setOption(key: String, value: String): Unit {}
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

    @TestCase
    public func testDispatchSetNull(): Unit {
        let stmt = MockStatement()
        dispatchSet(stmt, 5, (1, 2))
        @Expect(stmt.lastSetType, "setNull")
        @Expect(stmt.lastSetIndex, 5)
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
        let stmt = tx.prepareStatement("SELECT 1")
        @Expect(stmt.parameterColumnInfos.size, 0)
    }

    @TestCase
    public func testTxExecute(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
        let result = tx.execute("UPDATE t SET x = ?", [1])
        @Expect(result.rowCount, 0)
    }

    @TestCase
    public func testTxQuery(): Unit {
        let conn = MockConnection()
        let tx = Tx(conn)
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
}
