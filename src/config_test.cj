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
    public func testConfigToRefineWithMySQLDriver(): Unit {
        DriverManager.deregister("mysql")
        DriverManager.register("mysql", MockDriver())
        try {
            let cfg = DatabaseConfig()
            cfg.driver = "mysql"
            cfg.dsn = "mysql://localhost:3306/testdb"
            cfg.database = Some("testdb")
            let rf = cfg.toRefine()
            @Expect(rf.getDialect().name(), "mysql")
            @Expect(rf.getParamOffset(), 0)
            rf.close()
        } finally {
            DriverManager.deregister("mysql")
        }
    }

    @TestCase
    public func testConfigToRefineWithMariaDBDriver(): Unit {
        let realDrv = DriverManager.getDriver("mariadb")
        DriverManager.deregister("mariadb")
        DriverManager.register("mariadb", MockDriver())
        try {
            let cfg = DatabaseConfig()
            cfg.driver = "mariadb"
            cfg.dsn = "mariadb://localhost:3306/testdb"
            let rf = cfg.toRefine()
            @Expect(rf.getDialect().name(), "mysql")
            @Expect(rf.getParamOffset(), 1)
            rf.close()
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
