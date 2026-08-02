package refine

import std.collection.ArrayList

public class SQLiteDialect <: Dialect {
    private var params = ArrayList<Any>()

    public func name(): String { "sqlite" }

    public func quoteIdentifier(name: String): String {
        "\"" + name.replace("\"", "\"\"") + "\""
    }

    public func render(stmt: Statement): (String, Array<Any>) {
        params = ArrayList<Any>()
        (renderBody(stmt), params.toArray())
    }

    private func renderBody(stmt: Statement): String {
        var select = ArrayList<String>()
        var from = ArrayList<String>()
        var joins = ArrayList<String>()
        var whereClause = ArrayList<String>()
        var groupBy = ArrayList<String>()
        var having = ArrayList<String>()
        var orderBy = ArrayList<String>()
        var limit = ArrayList<String>()
        var hasSelect = false
        var updateSQL = ""
        var deleteSQL = ""
        var whereAdded = false
        for (i in 0..stmt.clauses.size) {
            let clause = stmt.clauses[i]
            match (clause) {
                case SelectClause(fields) =>
                    hasSelect = true
                    if (fields.size == 0) { select.add("SELECT *") }
                    else { select.add("SELECT " + renderExprList(fields)) }
                case FromClause(table) =>
                    from.add("FROM " + quoteIdentifier(table))
                case WhereClause(predicates) =>
                    let prefix = if (whereAdded) { "AND " } else { "WHERE " }
                    whereAdded = true
                    whereClause.add(prefix + renderAndList(predicates))
                case OrderByClause(fields) =>
                    orderBy.add("ORDER BY " + renderExprList(fields))
                case GroupByClause(fields) =>
                    groupBy.add("GROUP BY " + renderExprList(fields))
                case HavingClause(predicates) =>
                    having.add("HAVING " + renderAndList(predicates))
                case LimitClause(n) =>
                    limit.add("LIMIT " + n.toString())
                case OffsetClause(n) =>
                    limit.add("OFFSET " + n.toString())
                case JoinClause(table, alias, on) =>
                    joins.add("LEFT JOIN " + quoteIdentifier(table) + " " + quoteIdentifier(alias) + " ON " + renderExpr(on))
                case UpdateClause(table, setCols, setVals) =>
                    var setParts = ArrayList<String>()
                    for (_si_ in 0..setCols.size) {
                        setParts.add(quoteIdentifier(setCols[_si_]) + " = ?")
                        params.add(setVals[_si_])
                    }
                    updateSQL = "UPDATE " + quoteIdentifier(table) + " SET " + String.join(setParts.toArray(), delimiter: ", ")
                case DeleteClause(table) =>
                    deleteSQL = "DELETE FROM " + quoteIdentifier(table)
                case LockClause =>
                    ()
            }
        }
        var parts = ArrayList<String>()
        if (updateSQL != "") {
            parts.add(updateSQL)
            for (s in whereClause) { parts.add(s) }
        } else if (deleteSQL != "") {
            parts.add(deleteSQL)
            for (s in whereClause) { parts.add(s) }
        } else {
            if (!hasSelect) { parts.add("SELECT *") }
            else { for (s in select) { parts.add(s) } }
            for (s in from) { parts.add(s) }
            for (s in joins) { parts.add(s) }
            for (s in whereClause) { parts.add(s) }
            for (s in groupBy) { parts.add(s) }
            for (s in having) { parts.add(s) }
            for (s in orderBy) { parts.add(s) }
            for (s in limit) { parts.add(s) }

        }
        String.join(parts.toArray(), delimiter: " ")
    }

    private func renderExpr(expr: Expr): String {
        match (expr) {
            case Column(n) => quoteIdentifier(n)
            case Value(v) =>
                params.add(v)
                "?"
            case Binary(l, op, r) =>
                renderExpr(l) + " " + renderOp(op) + " " + renderExpr(r)
            case Unary(op, e) =>
                renderUnaryOp(op) + " " + renderExpr(e)
            case FuncCall(n, args) =>
                n + "(" + renderExprList(args) + ")"
            case Raw(s) => s
            case Ordered(expr, dir) =>
                renderExpr(expr) + " " + dir
            case Aliased(expr, alias) =>
                renderExpr(expr) + " AS " + quoteIdentifier(alias)
            case SubQuery(s) =>
                "(" + renderBody(s) + ")"
        }
    }

    private func renderExprList(exprs: Array<Expr>): String {
        if (exprs.size == 0) { return "" }
        var parts = ArrayList<String>()
        for (e in exprs) {
            parts.add(renderExpr(e))
        }
        String.join(parts.toArray(), delimiter: ", ")
    }

    private func renderAndList(exprs: Array<Expr>): String {
        if (exprs.size == 0) { return "" }
        var parts = ArrayList<String>()
        for (e in exprs) {
            parts.add(renderExpr(e))
        }
        String.join(parts.toArray(), delimiter: " AND ")
    }

    private func renderOp(op: BinOp): String {
        match (op) {
            case Eq => "="
            case Ne => "<>"
            case Gt => ">"
            case Ge => ">="
            case Lt => "<"
            case Le => "<="
            case And => "AND"
            case Or => "OR"
            case Like => "LIKE"
            case In => "IN"
            case NotIn => "NOT IN"
            case Between => "BETWEEN"
            case Add => "+"
            case Sub => "-"
            case Mul => "*"
            case Div => "/"
            case Mod => "%"
        }
    }

    private func renderUnaryOp(op: UnaryOp): String {
        match (op) {
            case Not => "NOT"
            case IsNull => "IS NULL"
            case IsNotNull => "IS NOT NULL"
        }
    }

    // 现代 SQLite（≥3.24 支持 ON CONFLICT，≥3.35 支持 RETURNING，JSON1 内建）启用这些能力。
    // 后续引入连接抽象后，再按实际 SQLite 版本细化开关（见 audit I15 决策）。
    public func hasUpsertSupport(): Bool { true }

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

    // 现代 SQLite（≥3.35 支持 RETURNING；JSON1 自 SQLite 3.38 起为内建，更早版本多为编译期启用）
    public func hasReturningSupport(): Bool { true }

    public func hasJSONSupport(): Bool { true }

    // SQLite 无事务隔离级别概念（单写者），保持不支持
    public func hasIsolationSupport(): Bool { false }

    public func migrator(db: DB): Migrator { SQLiteMigrator(db) }

    public func initialize(db: DB): Unit {}

    public func defaultValueOf(st: StorageType): String { "" }
}
