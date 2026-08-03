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
            // 原值（VALUES(col) 即 col），纯噪音且无任何语义（SQLite 保留原行为，见 M14 决策）
            if (conflictColumns.contains(c)) { continue }
            if (auditCreateCols.contains(c)) { continue }
            if (c == versionCol) {
                updates.add(quoteIdentifier(c) + " = " + quoteIdentifier(c) + " + 1")
            } else if (auditUpdateCols.contains(c)) {
                updates.add(quoteIdentifier(c) + " = ?")
                extraParamCount++
            } else {
                updates.add(quoteIdentifier(c) + " = VALUES(" + quoteIdentifier(c) + ")")
            }
        }
        // M14 防御：全部列都是冲突列（纯关联表直接 upsert）时 UPDATE SET 为空，MySQL 的
        // ON DUPLICATE KEY UPDATE 必须至少一条赋值，用首列无操作更新（col = col）保语法合法
        var updateClause: String
        if (updates.size == 0) {
            updateClause = " ON DUPLICATE KEY UPDATE " + quoteIdentifier(columns[0]) + " = " + quoteIdentifier(columns[0])
        } else {
            updateClause = " ON DUPLICATE KEY UPDATE " + String.join(updates.toArray(), delimiter: ", ")
        }
        ("INSERT INTO " + quoteIdentifier(table) + " (" + String.join(cols.toArray(), delimiter: ", ") + ") VALUES (" + String.join(placeholders.toArray(), delimiter: ", ") + ")" + updateClause, extraParamCount)
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
