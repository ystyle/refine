package refine

import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.sync.Mutex
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

// M16: DatabaseRegistry 是静态全局状态（instances/configs），并发场景（多线程同时
// register/get/initAll/closeAll/clear）必须加锁保护，否则 HashMap 并发读写可能抛异常
// 或损坏结构。Mutex 可重入，嵌套调用（如 initAll 内调 get）不会死锁。
public class DatabaseRegistry {
    private static var instances = HashMap<String, DB>()
    private static var configs = HashMap<String, DatabaseConfig>()
    private static let registryLock = Mutex()

    public static func register(name: String, config: DatabaseConfig): Unit {
        synchronized(registryLock) {
            configs.add(name, config)
        }
    }

    public static func get(name: String): DB {
        synchronized(registryLock) {
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
    }

    public static func initAll(): Unit {
        synchronized(registryLock) {
            for (name in configs.keys()) {
                get(name)
            }
        }
    }

    public static func closeAll(): Unit {
        synchronized(registryLock) {
            for (db in instances.values()) {
                db.close()
            }
            instances = HashMap<String, DB>()
        }
    }

    public static func clear(): Unit {
        synchronized(registryLock) {
            instances = HashMap<String, DB>()
            configs = HashMap<String, DatabaseConfig>()
        }
    }
}
