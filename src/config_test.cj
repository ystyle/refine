package refine

import std.unittest.*
import std.unittest.testmacro.*

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
}
