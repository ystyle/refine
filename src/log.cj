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

    private static func formatAny(val: Any): String {
        match (val) {
            case s: String => s
            case i: Int64 => i.toString()
            case b: Bool => if (b) { "true" } else { "false" }
            case f: Float64 => f.toString()
            case _ => "<unknown>"
        }
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
