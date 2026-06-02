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
}
