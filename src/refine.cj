package refine

import std.database.sql.{Datasource, Connection, Transaction, QueryResult, UpdateResult, Driver, DriverManager, PooledDatasource}
import std.collection.HashMap
import std.collection.ArrayList
import std.convert.*

public class Refine {
    private var datasource: Datasource
    private var dialect: Dialect
    private var paramOffset: Int64 = 0
    private var hookRegistry = HashMap<String, ArrayList<Any>>()
    private var idGenerator: IdGenerator = SonyflakeIdGenerator()

    internal init(datasource: Datasource, dialect: Dialect, paramOffset: Int64) {
        this.datasource = datasource
        this.dialect = dialect
        this.paramOffset = paramOffset
    }

    public func getIdGenerator(): IdGenerator { idGenerator }

    public func setIdGenerator(gen: IdGenerator): Unit { idGenerator = gen }

    public static func open(url: String): Refine {
        open(url, [])
    }

    public static func open(url: String, opts: Array<(String, String)>): Refine {
        let driverName = extractDriver(url)
        let drv = DriverManager.getDriver(driverName).getOrThrow()
        let ds = drv.open(url, opts)
        let d = detectDialect(driverName)
        let offset = if (driverName == "mariadb") { 1 } else { 0 }
        Refine(PooledDatasource(ds), d, offset)
    }

    public func session(): Session {
        Session(datasource.connect(), this, paramOffset)
    }

    public func transaction<T>(action: (Tx) -> T): T {
        let conn = datasource.connect()
        try {
            let tx = Tx(conn, this, paramOffset)
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

    public func transaction<T>(level: IsolationLevel, action: (Tx) -> T): T {
        let conn = datasource.connect()
        try {
            let tx = Tx(conn, this, paramOffset)
            tx.execute(this.dialect.isolationSQL(level), [])
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

    public func getDialect(): Dialect { dialect }

    public func getParamOffset(): Int64 { paramOffset }

    public func getRawConn(): Connection {
        datasource.connect()
    }

    public func hook<T>(typeName: String, kind: HookKind, hook: HookFn<T>): Unit {
        let key = typeName + ":" + kind.toString()
        match (hookRegistry.get(key)) {
            case Some(list) => list.add(hook)
            case None =>
                let list = ArrayList<Any>()
                list.add(hook)
                hookRegistry.add(key, list)
        }
    }

    public func executeHooks<T>(typeName: String, kind: HookKind, scope: Scope<T>): ?Exception {
        let key = typeName + ":" + kind.toString()
        match (hookRegistry.get(key)) {
            case Some(hooks) =>
                for (h in hooks) {
                    if (scope.aborted) { return scope.error }
                    let fn = (h as HookFn<T>).getOrThrow()
                    fn(scope)
                }
                if (scope.aborted) { return scope.error }
            case None => ()
        }
        None
    }

    public func all<T>(query: Query<T>): Array<T> {
        let s = session()
        query.queryDialect = dialect
        query.columnOffset = paramOffset
        let r = query.using(s).all()
        s.close()
        r
    }

    public func one<T>(query: Query<T>): Option<T> {
        let s = session()
        query.queryDialect = dialect
        query.columnOffset = paramOffset
        let r = query.using(s).one()
        s.close()
        r
    }

    public func migrator(): Migrator {
        let db = DB(datasource)
        // For MariaDB/MySQL, the session needs 1-based paramOffset
        if (paramOffset > 0) {
            dialect.migrator(DB(datasource, paramOffset))
        } else {
            dialect.migrator(db)
        }
    }

    public func close(): Unit {
        datasource.close()
    }
}

public func extractDriver(url: String): String {
    match (url.indexOf(":")) {
        case Some(pos) => url[0..pos]
        case None => "sqlite"
    }
}

public func parseId64(s: String): Int64 {
    Int64.parse(s)
}

public func detectDialect(name: String): Dialect {
    match (name) {
        case "mysql" | "mariadb" => MySQLDialect()
        case "postgres" | "postgresql" => PostgreSQLDialect()
        case _ => SQLiteDialect()
    }
}
