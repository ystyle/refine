package refine

import std.collection.ArrayList
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

    // 纯连接层：返回 DB（datasource + paramOffset + 连接池），无方言。
    public func toDB(): DB {
        DB(openPooledDatasource(), detectParamOffset(driver))
    }

    // ORM 层：建纯 DB + 方言，返回 Refine（持有 DB，getParamOffset/方言经 db）。
    // M1: 与 Refine.open 一致，构造前调用 d.initialize(db) 钩子——避免方言初始化
    // 实现后 Refine.open 与 DatabaseConfig.toRefine 两条入口静默行为分叉。
    // R-M19: mariadb 驱动走运行时服务端探测（与 Refine.open 一致）。探测在包装池之前
    // 用 openRawDatasource() 拿原始 datasource 建连执行 SELECT VERSION()，随后同一
    // datasource 再经 applyPoolConfig 入池——探测连接独立开合，不影响池。
    public func toRefine(): Refine {
        let ds = openRawDatasource()
        let d = detectServerDialect(driver, ds)
        let db = DB(applyPoolConfig(this, ds), detectParamOffset(driver))
        d.initialize(db)
        Refine(db, d)
    }

    // 原始（未包装池）datasource：探测与建池共享同一 drv.open 结果，避免两次打开连接。
    private func openRawDatasource(): Datasource {
        let drvOpt = DriverManager.getDriver(driver)
        match (drvOpt) {
            case Some(drv) =>
                var opts = ArrayList<(String, String)>()
                if (user != "") { opts.add(("username", user)) }
                if (passwd != "") { opts.add(("password", passwd)) }
                if (let Some(db) <- database) { opts.add(("database", db)) }
                drv.open(dsn, opts.toArray())
            case None =>
                throw ConnectionException("Driver '${driver}' not found")
        }
    }

    private func openPooledDatasource(): PooledDatasource {
        applyPoolConfig(this, openRawDatasource())
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
