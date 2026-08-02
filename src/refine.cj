package refine

import std.database.sql.{Datasource, Connection, Driver, DriverManager, PooledDatasource}
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
        let offset = detectParamOffset(driverName)
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
            tx.setIsolation(level)
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

    public func clearHooks(): Unit {
        hookRegistry.clear()
    }

    // I9: 在 Query 副本上执行，绝不修改调用方持有的 Query（queryDialect/columnOffset/executor
    // 都被 using() 写进副本）；session 生命周期全部收敛在 try/finally：
    // 成功路径由 Query.closeExecutor 关闭（Session.close 幂等，finally 的 close 是 no-op），
    // 异常路径由 finally 兜底关闭，任何情况下底层连接恰好关闭一次。
    public func all<T>(query: Query<T>): Array<T> {
        let s = session()
        try {
            return query.copy().using(s).all()
        } finally {
            s.close()
        }
    }

    public func one<T>(query: Query<T>): Option<T> {
        let s = session()
        try {
            return query.copy().using(s).one()
        } finally {
            s.close()
        }
    }

    public func migrator(): Migrator {
        dialect.migrator(DB(datasource, paramOffset, dialect))
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

public func detectParamOffset(driver: String): Int64 {
    if (driver == "mariadb") { 1 } else { 0 }
}

public func visitedContains(visited: ArrayList<Object>, target: Object): Bool {
    for (v in visited) {
        if (refEq(v, target)) { return true }
    }
    false
}

public func visitedKeyContains(visited: ArrayList<String>, key: String): Bool {
    for (k in visited) {
        if (k == key) { return true }
    }
    false
}
