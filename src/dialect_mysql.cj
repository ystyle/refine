package refine

import std.collection.ArrayList

public class MySQLDialect <: Dialect {
    private var params = ArrayList<Any>()

    public func name(): String { "mysql" }

    public func quoteIdentifier(name: String): String {
        "`" + name + "`"
    }

    public func render(stmt: Statement): (String, Array<Any>) {
        params = ArrayList<Any>()
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
        var hasLock = false
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
                    hasLock = true
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
            if (hasLock) { parts.add("FOR UPDATE") }
        }
        (String.join(parts.toArray(), delimiter: " "), params.toArray())
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
                let (subSql, subParams) = render(s)
                for (p in subParams) { params.add(p) }
                "(" + subSql + ")"
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

    public func hasUpsertSupport(): Bool { true }

    public func upsertSQL(table: String, columns: Array<String>, _conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): String {
        var cols = ArrayList<String>()
        var placeholders = ArrayList<String>()
        var updates = ArrayList<String>()
        for (c in columns) {
            cols.add(quoteIdentifier(c))
            placeholders.add("?")
        }
        for (c in columns) {
            if (auditCreateCols.contains(c)) { continue }
            if (c == versionCol) {
                updates.add(quoteIdentifier(c) + " = " + quoteIdentifier(c) + " + 1")
            } else if (auditUpdateCols.contains(c)) {
                updates.add(quoteIdentifier(c) + " = ?")
            } else {
                updates.add(quoteIdentifier(c) + " = VALUES(" + quoteIdentifier(c) + ")")
            }
        }
        "INSERT INTO " + quoteIdentifier(table) + " (" + String.join(cols.toArray(), delimiter: ", ") + ") VALUES (" + String.join(placeholders.toArray(), delimiter: ", ") + ") ON DUPLICATE KEY UPDATE " + String.join(updates.toArray(), delimiter: ", ")
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

    public func hasReturningSupport(): Bool { false }

    public func hasJSONSupport(): Bool { true }

    public func hasIsolationSupport(): Bool { true }

    public func migrator(db: DB): Migrator { MySQLMigrator(db) }

    public func initialize(db: DB): Unit {}

    public func defaultValueOf(st: StorageType): String { "" }
}
