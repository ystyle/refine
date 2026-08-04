package refine

import std.collection.ArrayList

// MySQL 方言：占位符 `?`、FOR UPDATE 行锁（继承 AbstractDialect 默认）。
// 差异点（M18 抽取后仅剩）：
// - quoteIdentifier = 反引号标识符（内嵌反引号转义为 ``，C9：封闭标识符逃逸注入通道）
// - renderLimitOffset = 裸 OFFSET（无 LIMIT）前补 `LIMIT 18446744073709551615` 哨兵（I3）
public class MySQLDialect <: AbstractDialect {
    public func name(): String { "mysql" }

    // MySQL 标识符用反引号包裹（`...`），内嵌反引号转义为 ``（C9：封闭标识符逃逸注入通道）
    public override func quoteIdentifier(name: String): String {
        "`" + name.replace("`", "``") + "`"
    }

    // 回归（I3）：MySQL 裸 OFFSET（无 LIMIT）是语法错误，必须补 `LIMIT 18446744073709551615` 哨兵；
    // LIMIT+OFFSET 并存时保持原样。UPDATE/DELETE 路径不经过 renderLimitOffset，不受影响。
    protected override func renderLimitOffset(hasLimit: Bool, hasOffset: Bool, limit: ArrayList<String>): ArrayList<String> {
        var out = ArrayList<String>()
        if (hasOffset && !hasLimit) { out.add("LIMIT 18446744073709551615") }
        for (s in limit) { out.add(s) }
        out
    }

    public func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): (String, Int64) {
        var cols = ArrayList<String>()
        var placeholders = ArrayList<String>()
        var updates = ArrayList<String>()
        // 审计更新列（非 version、非 auditCreate）生成 `col = ?`，每个需要一个额外参数
        var extraParamCount: Int64 = 0
        for (c in columns) {
            cols.add(quoteIdentifier(c))
            placeholders.add("?")
        }
        for (c in columns) {
            // M14: 主键/冲突列不进入 DO UPDATE SET——冲突行匹配的就是这些列，更新它们恒为
            // 原值（new.col 即 col），纯噪音且无任何语义（SQLite 保留原行为，见 M14 决策）
            if (conflictColumns.contains(c)) { continue }
            if (auditCreateCols.contains(c)) { continue }
            if (c == versionCol) {
                // R-M19: 行别名 `AS new` 存在时，DO UPDATE SET 里裸列名会产生歧义（现有行
                // 与 new 行都有该列）。version 冲突自增引用「现有行」的当前值，RHS 须表限定
                // （LHS 赋值目标保持裸列名，MySQL 允许；语义同 SQLite 裸列 RHS 与 PG 的
                // `"version" = "table"."version" + 1`，见 R-C1）。
                updates.add(quoteIdentifier(c) + " = " + quoteIdentifier(table) + "." + quoteIdentifier(c) + " + 1")
            } else if (auditUpdateCols.contains(c)) {
                updates.add(quoteIdentifier(c) + " = ?")
                extraParamCount++
            } else {
                // R-M19: 冲突行的「新插入值」引用从 `VALUES(col)` 迁到行别名 `new.col`
                // （MySQL 8.0.20 起 VALUES() 已废弃，未来版本会移除；经真实 MySQL 9.7 验证）。
                // VALUES 列表后挂 `AS new` 行别名，DO UPDATE SET 用 `new."col"` 引用新行值，
                // 语义与 VALUES(col) 完全一致（同 ON DUPLICATE KEY UPDATE 更新冲突行为新值）。
                updates.add(quoteIdentifier(c) + " = new." + quoteIdentifier(c))
            }
        }
        // M14 防御：全部列都是冲突列（纯关联表直接 upsert）时 UPDATE SET 为空，MySQL 的
        // ON DUPLICATE KEY UPDATE 必须至少一条赋值，用首列无操作更新保语法合法。
        // R-M19: 行别名 AS new 存在时裸列名歧义，无操作更新的 RHS 用表限定引用现有行
        //（冲突列上 new.col 恒等于现有列值，表限定与 new 限定语义等价，取表限定更字面）。
        var updateClause: String
        if (updates.size == 0) {
            updateClause = " ON DUPLICATE KEY UPDATE " + quoteIdentifier(columns[0]) +
                " = " + quoteIdentifier(table) + "." + quoteIdentifier(columns[0])
        } else {
            updateClause = " ON DUPLICATE KEY UPDATE " + String.join(updates.toArray(), delimiter: ", ")
        }
        ("INSERT INTO " + quoteIdentifier(table) + " (" + String.join(cols.toArray(), delimiter: ", ") + ") VALUES (" + String.join(placeholders.toArray(), delimiter: ", ") + ") AS new" + updateClause, extraParamCount)
    }

    public func dataTypeOf(st: StorageType): String {
        match (st) {
            case Integer => "BIGINT"
            case Float => "DOUBLE"
            case Decimal => "DECIMAL(65,30)"
            case `Bool` => "TINYINT(1)"
            case String => "VARCHAR(255)"
            case Text => "TEXT"
            case Json => "JSON"
            case Bytes => "LONGBLOB"
            case Timestamp => "DATETIME(6)"
        }
    }

    public func migrator(db: DB): Migrator { MySQLMigrator(db) }

    // I5: 返回类型合适的 DEFAULT 值字面量（当前仅 SQLite 迁移器消费，三方言统一实现保持一致）。
    public func defaultValueOf(st: StorageType): String {
        match (st) {
            case Integer => "0"
            case Float => "0.0"
            case Decimal => "0"
            case `Bool` => "0"
            case String => "''"
            case Text => "''"
            case Json => "'{}'"
            case Bytes => "''"
            case Timestamp => "0"
        }
    }
}
