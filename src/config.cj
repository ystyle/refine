package refine

import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.database.sql.{Datasource, DriverManager, PooledDatasource}

public class DatabaseConfig {
    var driver: String = "sqlite"
    var dsn: String = ""
    var user: String = ""
    var passwd: String = ""
    var database: Option<String> = None
    var maxPoolSize: Int32 = 50
    var maxIdleSize: Int32 = 25
    var connectionTimeout: Int64 = 30
    var idleTimeout: Int64 = 600
    var maxLifeTime: Int64 = 1800
    var keepaliveTime: Int64 = 60

    public init() {}

    public func toDB(): DB {
        let drvOpt = DriverManager.getDriver(driver)
        match (drvOpt) {
            case Some(drv) =>
                var opts = ArrayList<(String, String)>()
                if (user != "") { opts.add(("username", user)) }
                if (passwd != "") { opts.add(("password", passwd)) }
                if (let Some(db) <- database) { opts.add(("database", db)) }
                let ds = drv.open(dsn, opts.toArray())
                let d = detectDialect(this.driver)
                let offset = detectParamOffset(this.driver)
                DB(applyPoolConfig(this, ds), offset, d)
            case None =>
                throw ConnectionException("Driver '${driver}' not found")
        }
    }
}

// I17: DatabaseConfig 的连接池参数此前从未接线（死参数）。这里把驱动数据源包装为
// PooledDatasource 并将全部池参数应用到连接池；超时类参数以秒为单位换算为 Duration。
func applyPoolConfig(cfg: DatabaseConfig, ds: Datasource): PooledDatasource {
    let pooled = PooledDatasource(ds)
    pooled.maxSize = cfg.maxPoolSize
    pooled.maxIdleSize = cfg.maxIdleSize
    pooled.connectionTimeout = Duration.second * cfg.connectionTimeout
    pooled.idleTimeout = Duration.second * cfg.idleTimeout
    pooled.maxLifeTime = Duration.second * cfg.maxLifeTime
    pooled.keepaliveTime = Duration.second * cfg.keepaliveTime
    pooled
}

public class DatabaseRegistry {
    private static var instances = HashMap<String, DB>()
    private static var configs = HashMap<String, DatabaseConfig>()

    public static func register(name: String, config: DatabaseConfig): Unit {
        configs.add(name, config)
    }

    public static func get(name: String): DB {
        match (instances.get(name)) {
            case Some(db) => db
            case None =>
                match (configs.get(name)) {
                    case Some(config) =>
                        let db = config.toDB()
                        instances.add(name, db)
                        db
                    case None =>
                        throw ConfigException("Database '${name}' not configured")
                }
        }
    }

    public static func initAll(): Unit {
        for (name in configs.keys()) {
            get(name)
        }
    }

    public static func closeAll(): Unit {
        for (db in instances.values()) {
            db.close()
        }
        instances = HashMap<String, DB>()
    }

    public static func clear(): Unit {
        instances = HashMap<String, DB>()
        configs = HashMap<String, DatabaseConfig>()
    }
}
