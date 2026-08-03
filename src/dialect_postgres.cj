package refine

import std.collection.ArrayList

// PostgreSQL 方言：ANSI 双引号标识符、FOR UPDATE 行锁（继承 AbstractDialect 默认）。
// 差异点（M18 抽取后仅剩）：
// - renderParam(ctx) = "$n" 编号占位符（从 1 递增并推进 ctx.paramIdx，跨子查询延续编号）
// - hasReturningSupport = true：PG 原生支持 RETURNING（save 用 RETURNING 回填生成字段）
public class PostgreSQLDialect <: AbstractDialect {
    public func name(): String { "postgresql" }

    // PG 占位符用 $n 编号（从 1 递增），覆盖 base 的 "?"；参数顺序与占位符编号一致，
    // 子查询渲染延续外层编号（render 每次新建 RenderContext，paramIdx 从 1 起）。
    // R-I4：paramIdx 收敛进 ctx，不再共享实例字段（详见 dialect_base.cj 文件头）。
    protected override func renderParam(ctx: RenderContext): String {
        let ph = "$" + ctx.paramIdx.toString()
        ctx.paramIdx++
        ph
    }

    // PG 支持 RETURNING（save 用 RETURNING 回填生成字段）
    public override func hasReturningSupport(): Bool { true }

    public func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): (String, Int64) {
        var cols = ArrayList<String>()
        var placeholders = ArrayList<String>()
        var updates = ArrayList<String>()
        var idx: Int64 = 1
        for (c in columns) {
            cols.add(quoteIdentifier(c))
            placeholders.add("$" + idx.toString())
            idx++
            // M14: 主键/冲突列不进入 DO UPDATE SET——冲突行匹配的就是这些列，EXCLUDED.col
            // 即原值，纯噪音且无任何语义（SQLite 保留原行为，见 M14 决策）
            if (conflictColumns.contains(c)) { continue }
            if (auditCreateCols.contains(c)) { continue }
            if (c == versionCol) {
                // R-C1: PG 的 DO UPDATE SET 赋值目标（LHS）不允许 table.col 限定（SQLite/MySQL 允许），
                // 必须裸列名；RHS 裸列名在 PG 有歧义，需表限定引用冲突行当前值（等价 SQLite 裸列 RHS）
                updates.add(quoteIdentifier(c) + " = " + quoteIdentifier(table) + "." + quoteIdentifier(c) + " + 1")
            } else {
                updates.add(quoteIdentifier(c) + " = EXCLUDED." + quoteIdentifier(c))
            }
        }
        var conflictCols = ArrayList<String>()
        for (c in conflictColumns) {
            conflictCols.add(quoteIdentifier(c))
        }
        // M14 防御：全部列都是冲突列（纯关联表直接 upsert）时 DO UPDATE SET 为空，
        // 退化为 DO NOTHING（无列可更新，语义正确且语法合法）
        var conflictAction: String
        if (updates.size == 0) {
            conflictAction = " DO NOTHING"
        } else {
            conflictAction = " DO UPDATE SET " + String.join(updates.toArray(), delimiter: ", ")
        }
        // PostgreSQL 用 EXCLUDED.col 更新冲突行，不需要额外参数
        ("INSERT INTO " + quoteIdentifier(table) + " (" + String.join(cols.toArray(), delimiter: ", ") + ") VALUES (" + String.join(placeholders.toArray(), delimiter: ", ") + ") ON CONFLICT (" + String.join(conflictCols.toArray(), delimiter: ", ") + ")" + conflictAction, 0)
    }

    public func dataTypeOf(st: StorageType): String {
        match (st) {
            case Integer => "BIGINT"
            case Float => "DOUBLE PRECISION"
            case Decimal => "DECIMAL"
            case `Bool` => "BOOLEAN"
            case String => "VARCHAR(255)"
            case Text => "TEXT"
            case Json => "JSONB"
            case Bytes => "BYTEA"
            case Timestamp => "TIMESTAMP"
        }
    }

    public func migrator(db: DB): Migrator { PostgreSQLMigrator(db) }

    // I5: 返回类型合适的 DEFAULT 值字面量（当前仅 SQLite 迁移器消费，三方言统一实现保持一致）。
    // PG 按类型用合法字面量：Bool 用 false，Json 用 '{}'::jsonb，Bytes 用 ''::bytea，Timestamp 用 epoch。
    public func defaultValueOf(st: StorageType): String {
        match (st) {
            case Integer => "0"
            case Float => "0.0"
            case Decimal => "0"
            case `Bool` => "false"
            case String => "''"
            case Text => "''"
            case Json => "'{}'::jsonb"
            case Bytes => "''::bytea"
            case Timestamp => "'1970-01-01 00:00:00'"
        }
    }
}
