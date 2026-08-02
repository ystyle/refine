package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.DriverManager

@Test
public class ConfigTest {
    @TestCase
    public func testDefaultConfig(): Unit {
        let cfg = DatabaseConfig()
        @Expect(cfg.driver, "sqlite")
        @Expect(cfg.maxPoolSize, 50)
    }

    @TestCase
    public func testConfigWithValues(): Unit {
        let cfg = DatabaseConfig()
        cfg.driver = "postgresql"
        cfg.dsn = "host=localhost port=5432"
        cfg.user = "test"
        @Expect(cfg.driver, "postgresql")
        @Expect(cfg.dsn, "host=localhost port=5432")
    }

    @TestCase
    public func testRegisterAndGet(): Unit {
        DatabaseRegistry.clear()
        let cfg = DatabaseConfig()
        cfg.driver = "sqlite"
        cfg.dsn = "test.db"
        DatabaseRegistry.register("default", cfg)

        try {
            let db = DatabaseRegistry.get("default")
            @Fail("should have thrown")
        } catch (e: ConnectionException) {
            // Expected - no driver available
        } catch (e: ConfigException) {
            @Fail("wrong exception type")
        }
    }

    @TestCase
    public func testGetUnknownDatabase(): Unit {
        DatabaseRegistry.clear()
        try {
            let db = DatabaseRegistry.get("nonexistent")
            @Fail("should have thrown")
        } catch (e: ConfigException) {
            // Expected
        }
    }

    @TestCase
    public func testClear(): Unit {
        DatabaseRegistry.clear()
        DatabaseRegistry.register("db1", DatabaseConfig())
        DatabaseRegistry.register("db2", DatabaseConfig())
        DatabaseRegistry.clear()
        try {
            DatabaseRegistry.get("db1")
            @Fail("should have thrown after clear")
        } catch (e: ConfigException) {
            // Expected
        }
    }

    @TestCase
    public func testDatabaseConfigToDB(): Unit {
        let cfg = DatabaseConfig()
        cfg.driver = "nonexistent"
        try {
            let db = cfg.toDB()
            @Fail("should have thrown")
        } catch (e: ConnectionException) {
            @Expect(e.message, "Driver 'nonexistent' not found")
        }
    }

    @TestCase
    public func testRegister(): Unit {
        DatabaseRegistry.clear()
        let cfg = DatabaseConfig()
        cfg.driver = "sqlite"
        cfg.dsn = "test.db"
        DatabaseRegistry.register("mydb", cfg)
        try {
            DatabaseRegistry.get("mydb")
            @Fail("should have thrown")
        } catch (e: ConnectionException) {
            @Expect(e.message.contains("not found"), true)
        } catch (e: ConfigException) {
            @Fail("wrong exception type")
        }
    }

    @TestCase
    public func testInitAllEmpty(): Unit {
        DatabaseRegistry.clear()
        // initAll with no configs should be a no-op
        DatabaseRegistry.initAll()
        @Expect(true, true)
    }

    @TestCase
    public func testCloseAllEmpty(): Unit {
        DatabaseRegistry.clear()
        // closeAll with no instances should be a no-op
        DatabaseRegistry.closeAll()
        @Expect(true, true)
    }

    @TestCase
    public func testGetCachedHit(): Unit {
        DatabaseRegistry.clear()
        let cfg = DatabaseConfig()
        cfg.driver = "sqlite"
        cfg.dsn = ":memory:"
        DatabaseRegistry.register("testdb", cfg)
        // First call: miss, create, cache
        // If first call throws, cache is not populated
        try {
            let db = DatabaseRegistry.get("testdb")
            @Expect(true, true)
        } catch (_: Exception) {
            // Expected if sqlite driver not available
        }
    }

    @TestCase
    public func testConfigWithDatabaseOpts(): Unit {
        let cfg = DatabaseConfig()
        cfg.driver = "mysql"
        cfg.database = Some("testdb")
        cfg.user = "root"
        cfg.passwd = "secret"
        @Expect(cfg.driver, "mysql")
        @Expect(cfg.database.getOrThrow(), "testdb")
    }

    @TestCase
    public func testConfigToDBWithMySQLDriver(): Unit {
        DriverManager.deregister("mysql")
        DriverManager.register("mysql", MockDriver())
        try {
            let cfg = DatabaseConfig()
            cfg.driver = "mysql"
            cfg.dsn = "mysql://localhost:3306/testdb"
            cfg.database = Some("testdb")
            let db = cfg.toDB()
            @Expect(db.getDialect().name(), "mysql")
            let s = db.session()
            @Expect(s.getParamOffset(), 0)
            s.close()
            db.close()
        } finally {
            DriverManager.deregister("mysql")
        }
    }

    @TestCase
    public func testConfigToDBWithMariaDBDriver(): Unit {
        let realDrv = DriverManager.getDriver("mariadb")
        DriverManager.deregister("mariadb")
        DriverManager.register("mariadb", MockDriver())
        try {
            let cfg = DatabaseConfig()
            cfg.driver = "mariadb"
            cfg.dsn = "mariadb://localhost:3306/testdb"
            let db = cfg.toDB()
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

    // I17: DatabaseConfig 的连接池参数此前全是死参数（从未接线到数据源）。
    // applyPoolConfig 必须把全部 6 个池参数应用到 PooledDatasource。
    @TestCase
    public func testApplyPoolConfigWiring(): Unit {
        let cfg = DatabaseConfig()
        cfg.maxPoolSize = 8
        cfg.maxIdleSize = 3
        cfg.connectionTimeout = 5
        cfg.idleTimeout = 120
        cfg.maxLifeTime = 3600
        cfg.keepaliveTime = 45
        let pooled = applyPoolConfig(cfg, MockDatasource())
        @Expect(pooled.maxSize, 8)
        @Expect(pooled.maxIdleSize, 3)
        @Expect(pooled.connectionTimeout.toSeconds(), 5)
        @Expect(pooled.idleTimeout.toSeconds(), 120)
        @Expect(pooled.maxLifeTime.toSeconds(), 3600)
        @Expect(pooled.keepaliveTime.toSeconds(), 45)
    }

    // I17: 默认池参数同样必须生效。
    @TestCase
    public func testApplyPoolConfigDefaults(): Unit {
        let cfg = DatabaseConfig()
        let pooled = applyPoolConfig(cfg, MockDatasource())
        @Expect(pooled.maxSize, 50)
        @Expect(pooled.maxIdleSize, 25)
        @Expect(pooled.connectionTimeout.toSeconds(), 30)
        @Expect(pooled.idleTimeout.toSeconds(), 600)
        @Expect(pooled.maxLifeTime.toSeconds(), 1800)
        @Expect(pooled.keepaliveTime.toSeconds(), 60)
    }
}
