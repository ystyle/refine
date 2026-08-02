package refine

import std.collection.{ArrayList, HashMap}
import std.database.sql.DriverManager

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
                let offset = if (this.driver == "mariadb") { 1 } else { 0 }
                DB(ds, offset, d)
            case None =>
                throw ConnectionException("Driver '${driver}' not found")
        }
    }
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
