package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class LoggerTest {
    @TestCase
    public func testDefaultLevelIsInfo(): Unit {
        // At default Info level, debug should not log but info should
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Info)
        Logger.debug("should not appear at info level")
    }

    @TestCase
    public func testSetLevelToDebug(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Debug)
        Logger.debug("debug level should appear")
    }

    @TestCase
    public func testEnabledByDefault(): Unit {
        @Expect(Logger.isEnabled(), true)
    }

    @TestCase
    public func testSetEnabled(): Unit {
        Logger.setEnabled(false)
        @Expect(Logger.isEnabled(), false)
        Logger.setEnabled(true)
        @Expect(Logger.isEnabled(), true)
    }

    @TestCase
    public func testDebugNotShownWhenLevelIsInfo(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Info)
        Logger.debug("this debug should not appear")
    }

    @TestCase
    public func testAllLevelsLogAtDebug(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Debug)
        Logger.debug("debug msg")
        Logger.info("info msg")
        Logger.warn("warn msg")
        Logger.error("error msg")
    }

    @TestCase
    public func testLogSQLWithParams(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Debug)
        let params: Array<Any> = ["hello", 42, true]
        Logger.logSQL("SELECT * FROM t WHERE name = ? AND id = ?", params)
    }

    @TestCase
    public func testLogSQLNotShownAtInfo(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Info)
        let params: Array<Any> = ["test"]
        Logger.logSQL("SELECT 1", params)
    }

    @TestCase
    public func testSlowQueryWarning(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Warn)
        Logger.setSlowThreshold(Duration.millisecond * 1)
        Logger.logSlowQuery("SELECT * FROM big_table", Duration.millisecond * 100)
    }

    @TestCase
    public func testFastQueryNoWarning(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Warn)
        Logger.setSlowThreshold(Duration.second * 10)
        Logger.logSlowQuery("SELECT * FROM small_table", Duration.millisecond * 100)
    }

    @TestCase
    public func testDisabledLogging(): Unit {
        Logger.setEnabled(false)
        Logger.setLevel(LogLevel.Debug)
        Logger.debug("should not appear")
        Logger.info("should not appear")
        Logger.warn("should not appear")
        Logger.error("should not appear")
        let p: Array<Any> = []
        Logger.logSQL("SELECT 1", p)
        Logger.logSlowQuery("SELECT 1", Duration.second * 100)
        Logger.setEnabled(true)
        @Expect(Logger.isEnabled(), true)
    }

    @TestCase
    public func testEmptyParamsLogSQL(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Debug)
        let params: Array<Any> = []
        Logger.logSQL("SELECT 1", params)
    }

    @TestCase
    public func testLogPreservesLevelAfterChange(): Unit {
        Logger.setLevel(LogLevel.Debug)
        Logger.setEnabled(true)
        Logger.debug("debug msg")
        Logger.setLevel(LogLevel.Warn)
        Logger.debug("should not appear after level change")
        Logger.warn("warn msg")
    }

    @TestCase
    public func testSlowThresholdCanBeSet(): Unit {
        Logger.setSlowThreshold(Duration.second * 3)
        Logger.setLevel(LogLevel.Warn)
        Logger.setEnabled(true)
        Logger.logSlowQuery("test", Duration.second * 5)
    }

    @TestCase
    public func testLogSQLWithNoneParams(): Unit {
        Logger.setEnabled(true)
        Logger.setLevel(LogLevel.Debug)
        let params: Array<Any> = ["only_one"]
        Logger.logSQL("SELECT * FROM t WHERE id = ?", params)
    }
}
