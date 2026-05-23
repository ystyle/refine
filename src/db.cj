package refine

import std.database.sql.{Datasource, Connection, Transaction, QueryResult, UpdateResult, Driver, DriverManager, PooledDatasource}
import std.database.sql.Statement as SqlStatement
import std.time.DateTime

public class DB {
    private var datasource: Datasource

    public init(datasource: Datasource) {
        this.datasource = datasource
    }

    public static func open(url: String): DB {
        open(url, [])
    }

    public static func open(url: String, opts: Array<(String, String)>): DB {
        let driverName = extractDriver(url)
        let drv = DriverManager.getDriver(driverName).getOrThrow()
        let ds = drv.open(url, opts)
        DB(PooledDatasource(ds))
    }

    public func session(): Session {
        Session(datasource.connect())
    }

    public func transaction<T>(action: (Tx) -> T): T {
        let conn = datasource.connect()
        let tx = Tx(conn)
        tx.begin()
        try {
            let result = action(tx)
            tx.commit()
            return result
        } catch (e: Exception) {
            tx.rollback()
            throw e
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

    public init(connection: Connection) {
        this.connection = connection
    }

    public func prepareStatement(sql: String): SqlStatement {
        connection.prepareStatement(sql)
    }

    public func execute(sql: String, params: Array<Any>): UpdateResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i, params[i])
        }
        stmt.update()
    }

    public func query(sql: String, params: Array<Any>): QueryResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i, params[i])
        }
        stmt.query()
    }

    public func getDialect(): Dialect {
        SQLiteDialect()
    }

    public func close(): Unit {
        connection.close()
    }
}

public class Tx {
    private var connection: Connection
    private var transaction: Transaction

    public init(connection: Connection) {
        this.connection = connection
        this.transaction = connection.createTransaction()
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
            dispatchSet(stmt, i, params[i])
        }
        stmt.update()
    }

    public func query(sql: String, params: Array<Any>): QueryResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i, params[i])
        }
        stmt.query()
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
