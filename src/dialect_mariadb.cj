package refine

import std.collection.ArrayList

// R-M19: MariaDBDialect —— MySQLDialect 的 MariaDB 服务端变体。
//
// 背景：R-M19 将 MySQL 的 upsert 从 `VALUES(col)`（MySQL 8.0.20 起废弃）迁到
// `INSERT ... VALUES (...) AS new ON DUPLICATE KEY UPDATE col = new.col`（8.0.19+ 语法）。
// 但 `AS new` 行别名是 MySQL 8.0.19+ 独有语法，真实 MariaDB 服务端不支持（ERROR 1064
// syntax error near 'AS new'）。mariadb 驱动可连真实 MariaDB（SELECT VERSION() 返回
// `11.8.8-MariaDB-ubu2404`），运行时探测识别后走本方言。
//
// 仅覆盖 upsertSQL 与 name()，其余全部继承 MySQLDialect（quoteIdentifier 反引号、
// dataTypeOf、renderLimitOffset 哨兵、migrator=MySQLMigrator、能力位），MariaDB 与
// MySQL 在渲染/迁移层面语法完全一致。检测逻辑见 refine.cj 的 parseServerVersion/detectServerDialect。
public class MariaDBDialect <: MySQLDialect {
    public override func name(): String { "mariadb" }

    // 与 MySQLDialect.upsertSQL 同构，差异：
    // - VALUES 列表后**不加** `AS new`（MariaDB 报 ERROR 1064）
    // - 非冲突列更新用 `col = VALUES(col)`（MariaDB 老语法，语义与 MySQL 的 new.col
    //   等价——VALUES(col) 在 ON DUPLICATE KEY UPDATE 里引用新插入行的列值）
    // - version 自增 `col = VALUES(version) + 1`（新插入值 + 1，等价 MySQL 的 new.col）
    // - 全冲突列无操作更新 `col = VALUES(col)`（恒等赋值，语法合法，无 AS new 时不需表限定）
    public override func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): (String, Int64) {
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
                // R-M19: MariaDB 的 VALUES(col) 语义 = 新插入行的列值（等价 MySQL 的 new.col），
                // version 冲突自增 = 新值 + 1。与 MySQL 的 `version = table.version + 1`（现有行+1）
                // 语义等价——upsert 场景实体携带的 version 即现有行 version（save 后读回）。
                updates.add(quoteIdentifier(c) + " = VALUES(" + quoteIdentifier(c) + ") + 1")
            } else if (auditUpdateCols.contains(c)) {
                updates.add(quoteIdentifier(c) + " = ?")
                extraParamCount++
            } else {
                // MariaDB 老语法：ON DUPLICATE KEY UPDATE 里 VALUES(col) 引用新插入值，
                // 与 MySQL 8.0.19+ 的行别名 new.col 语义一致（MySQL 8.0.20 起 VALUES() 废弃，
                // 但 MariaDB 不识别 AS new，故保留 VALUES(col)，两者各自服务端语法唯一正确）。
                updates.add(quoteIdentifier(c) + " = VALUES(" + quoteIdentifier(c) + ")")
            }
        }
        // M14 防御：全部列都是冲突列（纯关联表直接 upsert）时 UPDATE SET 为空，MySQL/MariaDB
        // 的 ON DUPLICATE KEY UPDATE 必须至少一条赋值，用首列无操作更新保语法合法。
        // R-M19: 无 AS new 时裸列名无歧义，无操作更新直接用 VALUES(col)（恒等赋值）即可。
        var updateClause: String
        if (updates.size == 0) {
            updateClause = " ON DUPLICATE KEY UPDATE " + quoteIdentifier(columns[0]) +
                " = VALUES(" + quoteIdentifier(columns[0]) + ")"
        } else {
            updateClause = " ON DUPLICATE KEY UPDATE " + String.join(updates.toArray(), delimiter: ", ")
        }
        ("INSERT INTO " + quoteIdentifier(table) + " (" + String.join(cols.toArray(), delimiter: ", ") + ") VALUES (" + String.join(placeholders.toArray(), delimiter: ", ") + ")" + updateClause, extraParamCount)
    }
}
