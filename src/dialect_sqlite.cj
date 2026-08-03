package refine

import std.collection.ArrayList

// SQLite 方言：占位符 `?`、ANSI 双引号标识符（继承 AbstractDialect 默认）。
// 差异点（M18 抽取后仅剩）：
// - hasLockSupport = false：SQLite 无 SELECT ... FOR UPDATE 行锁概念（单写者）
// - hasIsolationSupport = false：SQLite 无事务隔离级别概念（单写者）
// - hasReturningSupport = false（继承默认）：SQLite ≥3.35 语法上支持 RETURNING，但本项目没有真实
//   SQLite 驱动可验证 save 的 RETURNING 路径（当前仅有 mock 与 sqlite3 CLI 语法检查），保持关闭不冒险
//   切换保存路径到 RETURNING。待引入驱动后按真实行为启用（见 audit I15 决策）。
public class SQLiteDialect <: AbstractDialect {
    public func name(): String { "sqlite" }

    // SQLite 无行锁概念（单写者），渲染时不追加 FOR UPDATE
    protected override func hasLockSupport(): Bool { false }

    // SQLite 无事务隔离级别概念（单写者），保持不支持
    public override func hasIsolationSupport(): Bool { false }

    // SQLite upsert 用 ON CONFLICT ... DO UPDATE；冲突行引用用 excluded.col（关键字不区分大小写，
    // 对齐 SQLite 文档采用小写），不需要额外参数（extraParamCount = 0）。
    // version 冲突自增用无表前缀的列名（SQLite 的 DO UPDATE SET 不支持 table.col 限定符，
    // 未限定列名即引用冲突前的原行值，与 PG 的 EXCLUDED 语义对应）。
    // 契约：auditCreateCols 与 auditUpdateCols 不相交；auditCreate 优先（continue 跳过，不生成更新子句）。
    public func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): (String, Int64) {
        var cols = ArrayList<String>()
        var placeholders = ArrayList<String>()
        var updates = ArrayList<String>()
        for (c in columns) {
            cols.add(quoteIdentifier(c))
            placeholders.add("?")
            if (auditCreateCols.contains(c)) { continue }
            if (c == versionCol) {
                updates.add(quoteIdentifier(c) + " = " + quoteIdentifier(c) + " + 1")
            } else {
                updates.add(quoteIdentifier(c) + " = excluded." + quoteIdentifier(c))
            }
        }
        var conflictCols = ArrayList<String>()
        for (c in conflictColumns) {
            conflictCols.add(quoteIdentifier(c))
        }
        ("INSERT INTO " + quoteIdentifier(table) + " (" + String.join(cols.toArray(), delimiter: ", ") + ") VALUES (" + String.join(placeholders.toArray(), delimiter: ", ") + ") ON CONFLICT (" + String.join(conflictCols.toArray(), delimiter: ", ") + ") DO UPDATE SET " + String.join(updates.toArray(), delimiter: ", "), 0)
    }

    public func dataTypeOf(st: StorageType): String {
        match (st) {
            case Integer => "INTEGER"
            case Float => "REAL"
            case Decimal => "NUMERIC"
            case `Bool` => "INTEGER"
            case String => "TEXT"
            case Text => "TEXT"
            case Json => "TEXT"
            case Bytes => "BLOB"
            case Timestamp => "TEXT"
        }
    }

    public func migrator(db: DB): Migrator { SQLiteMigrator(db) }

    // I5: 返回类型合适的 DEFAULT 值字面量（SQLite 非空表 ADD COLUMN NOT NULL 列必须带 DEFAULT）。
    // 按 SQLite 亲和性选择：数字列用数值字面量，文本列用字符串字面量，BLOB 用 X'' 字面量。
    public func defaultValueOf(st: StorageType): String {
        match (st) {
            case Integer => "0"
            case Float => "0.0"
            case Decimal => "0"
            case `Bool` => "0"
            case String => "''"
            case Text => "''"
            case Json => "'{}'"
            case Bytes => "X''"
            case Timestamp => "0"
        }
    }
}
