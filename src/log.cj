package refine

import std.collection.ArrayList
import std.time.DateTime

public enum LogLevel {
    | Debug
    | Info
    | Warn
    | Error
}

public class Logger {
    private static var level: LogLevel = LogLevel.Info
    private static var slowThreshold: Duration = Duration.second * 5
    private static var enabled: Bool = true

    public static func getLevel(): LogLevel {
        level
    }

    public static func isEnabled(): Bool {
        enabled
    }

    public static func setLevel(lvl: LogLevel): Unit {
        level = lvl
    }

    public static func setSlowThreshold(d: Duration): Unit {
        slowThreshold = d
    }

    public static func setEnabled(e: Bool): Unit {
        enabled = e
    }

    public static func debug(msg: String): Unit {
        if (enabled && levelPriority(LogLevel.Debug) >= levelPriority(level)) {
            log("DEBUG", msg)
        }
    }

    public static func info(msg: String): Unit {
        if (enabled && levelPriority(LogLevel.Info) >= levelPriority(level)) {
            log("INFO", msg)
        }
    }

    public static func warn(msg: String): Unit {
        if (enabled && levelPriority(LogLevel.Warn) >= levelPriority(level)) {
            log("WARN", msg)
        }
    }

    public static func error(msg: String): Unit {
        if (enabled && levelPriority(LogLevel.Error) >= levelPriority(level)) {
            log("ERROR", msg)
        }
    }

    public static func logSQL(sql: String, params: Array<Any>): Unit {
        if (enabled && levelPriority(LogLevel.Debug) >= levelPriority(level)) {
            var parts = ArrayList<String>()
            for (p in params) {
                parts.add(formatAny(p))
            }
            var paramStr = String.join(parts.toArray(), delimiter: ", ")
            log("SQL", "${sql}  [params: ${paramStr}]")
        }
    }

    public static func logSlowQuery(sql: String, elapsed: Duration): Unit {
        if (elapsed > slowThreshold) {
            warn("SLOW QUERY (${elapsed}): ${sql}")
        }
    }

    // M6/R-M6: formatAny 对 DateTime/Array 及全部标量数值类型补齐格式化，不再一律输出 <unknown>。
    // R-M6: 补齐 Int8/Int16/UInt8/UInt16/UInt32/UInt64（修复前漏匹配落入 <unknown>；
    // Float32 已覆盖）。这些类型是宏层接受的实体字段类型（meta.cj 白名单），日志参数
    // 出现时必须有可读输出。
    // internal（非 private）：同包测试直接断言格式化结果（宏生成代码不依赖此函数，无需 public）。
    static func formatAny(val: Any): String {
        match (val) {
            case s: String => s
            case i: Int8 => i.toString()
            case i: Int16 => i.toString()
            case i: Int32 => i.toString()
            case i: Int64 => i.toString()
            case i: UInt8 => i.toString()
            case i: UInt16 => i.toString()
            case i: UInt32 => i.toString()
            case i: UInt64 => i.toString()
            case b: Bool => if (b) { "true" } else { "false" }
            case f: Float32 => f.toString()
            case f: Float64 => f.toString()
            // DateTime 实现 ToString，输出 ISO 8601（如 2024-05-22T12:34:56+08:00）
            case dt: DateTime => dt.toString()
            case bytes: Array<UInt8> =>
                var hexParts = ArrayList<String>()
                for (byte in bytes) { hexParts.add(hexByte(byte)) }
                if (hexParts.size == 0) { "bytes[]" } else { "bytes[" + String.join(hexParts.toArray(), delimiter: "") + "]" }
            case arr: Array<Any> =>
                var parts = ArrayList<String>()
                for (v in arr) { parts.add(formatAny(v)) }
                "[" + String.join(parts.toArray(), delimiter: ", ") + "]"
            case _ => "<unknown>"
        }
    }

    private static func hexByte(b: UInt8): String {
        let hex = "0123456789abcdef"
        let hi = Int64(b) >> 4
        let lo = Int64(b) & 0xF
        // String 下标 hex[i] 返回 UInt8（单字节），用 fromUtf8 还原为单字符 String
        String.fromUtf8([hex[hi]]) + String.fromUtf8([hex[lo]])
    }

    private static func levelPriority(lvl: LogLevel): Int64 {
        match (lvl) {
            case LogLevel.Debug => 0
            case LogLevel.Info => 1
            case LogLevel.Warn => 2
            case LogLevel.Error => 3
        }
    }

    private static func log(tag: String, msg: String): Unit {
        let now = DateTime.now()
        println("[${now.format("HH:mm:ss")}] [${tag}] ${msg}")
    }
}
