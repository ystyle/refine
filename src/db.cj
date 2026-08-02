package refine

import std.database.sql.{Datasource, Connection, Transaction, QueryResult, UpdateResult, Driver, DriverManager, PooledDatasource, TransactionIsoLevel}
import std.database.sql.Statement as SqlStatement
import std.collection.{ArrayList, HashMap}
import std.time.DateTime

public class DB {
    private var datasource: Datasource
    private var paramOffset: Int64 = 0
    var dialect: Dialect = SQLiteDialect()
    public mut prop maxPoolSize: Int32 { get() { _maxPoolSize } set(v) { _maxPoolSize = v } }
    public mut prop connectionTimeout: Int64 { get() { _connectionTimeout } set(v) { _connectionTimeout = v } }
    public mut prop idleTimeout: Int64 { get() { _idleTimeout } set(v) { _idleTimeout = v } }
    public mut prop maxLifeTime: Int64 { get() { _maxLifeTime } set(v) { _maxLifeTime = v } }
    private var _maxPoolSize: Int32 = 10
    private var _connectionTimeout: Int64 = 30000
    private var _idleTimeout: Int64 = 60000
    private var _maxLifeTime: Int64 = 3600000

    public init(datasource: Datasource) {
        this.datasource = datasource
    }

    public init(datasource: Datasource, paramOffset: Int64) {
        this.datasource = datasource
        this.paramOffset = paramOffset
    }

    public init(datasource: Datasource, dialect: Dialect) {
        this.datasource = datasource
        this.dialect = dialect
    }

    public init(datasource: Datasource, paramOffset: Int64, dialect: Dialect) {
        this.datasource = datasource
        this.paramOffset = paramOffset
        this.dialect = dialect
    }

    public static func open(url: String): DB {
        open(url, [])
    }

    public static func open(url: String, opts: Array<(String, String)>): DB {
        let driverName = extractDriver(url)
        let drv = DriverManager.getDriver(driverName).getOrThrow()
        let ds = drv.open(url, opts)
        DB(PooledDatasource(ds), detectParamOffset(driverName), detectDialect(driverName))
    }

    public func session(): Session {
        Session(datasource.connect(), paramOffset, this.dialect)
    }

    public func getDialect(): Dialect {
        this.dialect
    }

    public func transaction<T>(action: (Tx) -> T): T {
        let conn = datasource.connect()
        try {
            let tx = Tx(conn, paramOffset, this.dialect)
            tx.begin()
            try {
                let result = action(tx)
                tx.commit()
                return result
            } catch (e: Exception) {
                tx.rollback()
                throw e
            }
        } finally {
            conn.close()
        }
    }

    public func close(): Unit {
        datasource.close()
    }

    private static func extractDriver(url: String): String {
        match (url.indexOf(":")) {
            case Some(pos) => url[0..pos]
            case None => "sqlite"
        }
    }
}

public class Session {
    private var connection: Connection
    var paramOffset: Int64 = 0
    public var ref: Option<Refine> = None
    var dialectOpt: Option<Dialect> = None

    public init(connection: Connection) {
        this.connection = connection
    }

    public init(connection: Connection, paramOffset: Int64) {
        this.connection = connection
        this.paramOffset = paramOffset
    }

    public init(connection: Connection, ref: Refine, paramOffset: Int64) {
        this.connection = connection
        this.ref = Some(ref)
        this.paramOffset = paramOffset
    }

    public init(connection: Connection, paramOffset: Int64, dialect: Dialect) {
        this.connection = connection
        this.paramOffset = paramOffset
        this.dialectOpt = Some(dialect)
    }

    public func prepareStatement(sql: String): SqlStatement {
        connection.prepareStatement(sql)
    }

    public func execute(sql: String, params: Array<Any>): UpdateResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.update()
    }

    public func query(sql: String, params: Array<Any>): QueryResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.query()
    }

    public func getDialect(): Dialect {
        match (this.ref) {
            case Some(rf) => rf.getDialect()
            case None =>
                match (this.dialectOpt) {
                    case Some(d) => d
                    case None => SQLiteDialect()
                }
        }
    }

    public func close(): Unit {
        connection.close()
    }
}

public class Tx {
    private var connection: Connection
    private var transaction: Transaction
    private var paramOffset: Int64 = 0
    public var ref: Option<Refine> = None
    var dialectOpt: Option<Dialect> = None

    public init(connection: Connection) {
        this.connection = connection
        this.transaction = connection.createTransaction()
    }

    public init(connection: Connection, paramOffset: Int64) {
        this.connection = connection
        this.transaction = connection.createTransaction()
        this.paramOffset = paramOffset
    }

    public init(connection: Connection, ref: Refine, paramOffset: Int64) {
        this.connection = connection
        this.transaction = connection.createTransaction()
        this.ref = Some(ref)
        this.paramOffset = paramOffset
    }

    public init(connection: Connection, paramOffset: Int64, dialect: Dialect) {
        this.connection = connection
        this.transaction = connection.createTransaction()
        this.paramOffset = paramOffset
        this.dialectOpt = Some(dialect)
    }

    public func begin(): Unit {
        transaction.begin()
    }

    public func commit(): Unit {
        transaction.commit()
    }

    public func rollback(): Unit {
        transaction.rollback()
    }

    public func save(name: String): Unit {
        transaction.save(name)
    }

    public func rollbackTo(name: String): Unit {
        transaction.rollback(name)
    }

    public func prepareStatement(sql: String): SqlStatement {
        connection.prepareStatement(sql)
    }

    public func execute(sql: String, params: Array<Any>): UpdateResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.update()
    }

    public func query(sql: String, params: Array<Any>): QueryResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.query()
    }

    public func getDialect(): Dialect {
        match (this.ref) {
            case Some(rf) => rf.getDialect()
            case None =>
                match (this.dialectOpt) {
                    case Some(d) => d
                    case None => SQLiteDialect()
                }
        }
    }

    public func getParamOffset(): Int64 { paramOffset }

    public func setIsolation(level: IsolationLevel): Unit {
        if (!this.getDialect().hasIsolationSupport()) {
            throw RefineException("SQLite does not support transaction isolation levels")
        }
        let mapped = match (level) {
            case ReadUncommitted => TransactionIsoLevel.ReadUncommitted
            case ReadCommitted => TransactionIsoLevel.ReadCommitted
            case RepeatableRead => TransactionIsoLevel.RepeatableRead
            case Serializable => TransactionIsoLevel.Serializable
        }
        transaction.isoLevel = mapped
    }
}

public interface ExecutionContext {
    func query(sql: String, params: Array<Any>): QueryResult
    func execute(sql: String, params: Array<Any>): UpdateResult
    func getDialect(): Dialect
    func getParamOffset(): Int64
}

extend Session <: ExecutionContext {
    public func getParamOffset(): Int64 { paramOffset }
}
extend Tx <: ExecutionContext {}

extend Tx {
    public func queryAll<T>(sql: String, params: Array<Any>,
                            mapper: (QueryResult, HashMap<String, Int64>) -> T): Array<T> {
        let result = this.query(sql, params)
        let offset = this.getParamOffset()
        let cm = buildColumnMap(result.columnInfos, offset)
        var entities = ArrayList<T>()
        while (result.next()) {
            entities.add(mapper(result, cm))
        }
        entities.toArray()
    }

    public func queryOne<T>(sql: String, params: Array<Any>,
                            mapper: (QueryResult, HashMap<String, Int64>) -> T): Option<T> {
        let result = this.query(sql, params)
        let offset = this.getParamOffset()
        let cm = buildColumnMap(result.columnInfos, offset)
        if (result.next()) { Some(mapper(result, cm)) } else { None }
    }
}

extend Session {
    public func queryAll<T>(sql: String, params: Array<Any>,
                            mapper: (QueryResult, HashMap<String, Int64>) -> T): Array<T> {
        let result = this.query(sql, params)
        let offset = this.getParamOffset()
        let cm = buildColumnMap(result.columnInfos, offset)
        var entities = ArrayList<T>()
        while (result.next()) {
            entities.add(mapper(result, cm))
        }
        entities.toArray()
    }

    public func queryOne<T>(sql: String, params: Array<Any>,
                            mapper: (QueryResult, HashMap<String, Int64>) -> T): Option<T> {
        let result = this.query(sql, params)
        let offset = this.getParamOffset()
        let cm = buildColumnMap(result.columnInfos, offset)
        if (result.next()) { Some(mapper(result, cm)) } else { None }
    }
}

extend DB {
    public func migrator(): Migrator {
        this.dialect.migrator(this)
    }
}

func dispatchSet(stmt: SqlStatement, index: Int, value: Any): Unit {
    match (value) {
        case v: Int64    => stmt.set<Int64>(index, v)
        case v: Int32    => stmt.set<Int32>(index, v)
        case v: String   => stmt.set<String>(index, v)
        case v: Bool     => stmt.set<Bool>(index, v)
        case v: Float64  => stmt.set<Float64>(index, v)
        case v: DateTime => stmt.set<DateTime>(index, v)
        case v: Array<UInt8> => stmt.set<Array<UInt8>>(index, v)
        case _           => stmt.setNull(index)
    }
}

// For drivers with 1-based parameter indices (e.g. MariaDB)
public func dispatchSet1(stmt: SqlStatement, index: Int, value: Any): Unit {
    dispatchSet(stmt, index + 1, value)
}
