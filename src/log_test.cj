package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.time.{DateTime, Month}

@Test
public class LoggerFormatAnyTest {
    // M6: formatAny 对 DateTime/Array 等常见参数类型补齐格式化，不再输出 <unknown>
    @TestCase
    public func testFormatDateTimeIsIso(): Unit {
        let dt = DateTime.of(year: 2024, month: May, dayOfMonth: 22, hour: 12, minute: 34, second: 56)
        let s = Logger.formatAny(dt)
        @Expect(s.startsWith("2024-05-22T12:34:56"), true)
        @Expect(s.contains("<unknown>"), false)
    }

    @TestCase
    public func testFormatArrayAnyJoinsElements(): Unit {
        let arr: Array<Any> = [1, "a", true]
        @Expect(Logger.formatAny(arr), "[1, a, true]")
    }

    @TestCase
    public func testFormatArrayUInt8IsHex(): Unit {
        let bytes: Array<UInt8> = [1, 2, 3, 10, 255, 16]
        @Expect(Logger.formatAny(bytes), "bytes[0102030aff10]")
    }

    @TestCase
    public func testFormatEmptyArrayUInt8(): Unit {
        let bytes: Array<UInt8> = []
        @Expect(Logger.formatAny(bytes), "bytes[]")
    }

    @TestCase
    public func testFormatNestedArray(): Unit {
        // 内层数组需显式 Array<Any>：仓颉泛型不变性使 Array<Int64> 不匹配 Array<Any>（formatAny 里为 <unknown>）
        let inner: Array<Any> = [1, 2]
        let arr: Array<Any> = [inner, "x"]
        @Expect(Logger.formatAny(arr), "[[1, 2], x]")
    }

    @TestCase
    public func testFormatInt32(): Unit {
        let v: Int32 = 42
        @Expect(Logger.formatAny(v), "42")
    }

    @TestCase
    public func testFormatFloat32(): Unit {
        let v: Float32 = 1.5
        @Expect(Logger.formatAny(v), "1.500000")
    }
}

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
