package refine

import std.collection.ArrayList

public class PostgreSQLDialect <: Dialect {
    private var params = ArrayList<Any>()
    private var paramIdx: Int64 = 1

    public func name(): String { "postgresql" }

    public func quoteIdentifier(name: String): String {
        "\"" + name + "\""
    }

    public func render(stmt: Statement): (String, Array<Any>) {
        params = ArrayList<Any>()
        paramIdx = 1
        var parts = ArrayList<String>()
        var hasSelect = false
        for (i in 0..stmt.clauses.size) {
            match (stmt.clauses[i]) {
                case SelectClause(_) => hasSelect = true
                case _ => ()
            }
        }
        if (!hasSelect) { parts.add("SELECT *") }
        for (i in 0..stmt.clauses.size) {
            let clause = stmt.clauses[i]
            match (clause) {
                case SelectClause(fields) =>
                    if (fields.size == 0) {
                        parts.add("SELECT *")
                    } else {
                        parts.add("SELECT " + renderExprList(fields))
                    }
                case FromClause(table) =>
                    parts.add("FROM " + quoteIdentifier(table))
                case WhereClause(predicates) =>
                    parts.add("WHERE " + renderAndList(predicates))
                case OrderByClause(fields) =>
                    parts.add("ORDER BY " + renderExprList(fields))
                case GroupByClause(fields) =>
                    parts.add("GROUP BY " + renderExprList(fields))
                case HavingClause(predicates) =>
                    parts.add("HAVING " + renderAndList(predicates))
                case LimitClause(n) =>
                    parts.add("LIMIT " + n.toString())
                case OffsetClause(n) =>
                    parts.add("OFFSET " + n.toString())
                case JoinClause(table, alias, on) =>
                    parts.add("LEFT JOIN " + quoteIdentifier(table) + " " + quoteIdentifier(alias) + " ON " + renderExpr(on))
            }
        }
        (joinStrings(parts, " "), params.toArray())
    }

    private func renderExpr(expr: Expr): String {
        match (expr) {
            case Column(n) => quoteIdentifier(n)
            case Value(v) =>
                params.add(v)
                let ph = "$" + paramIdx.toString()
                paramIdx++
                ph
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
        joinStrings(parts, ", ")
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

    private func renderAndList(exprs: Array<Expr>): String {
        if (exprs.size == 0) { return "" }
        var parts = ArrayList<String>()
        for (e in exprs) {
            parts.add(renderExpr(e))
        }
        joinStrings(parts, " AND ")
    }

    public func hasUpsertSupport(): Bool { true }

    public func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>): String {
        var cols = ArrayList<String>()
        var placeholders = ArrayList<String>()
        var updates = ArrayList<String>()
        var idx: Int64 = 1
        for (c in columns) {
            cols.add(quoteIdentifier(c))
            placeholders.add("$" + idx.toString())
            idx++
            updates.add(quoteIdentifier(c) + " = EXCLUDED." + quoteIdentifier(c))
        }
        var conflictCols = ArrayList<String>()
        for (c in conflictColumns) {
            conflictCols.add(quoteIdentifier(c))
        }
        "INSERT INTO " + quoteIdentifier(table) + " (" + joinStrings(cols, ", ") + ") VALUES (" + joinStrings(placeholders, ", ") + ") ON CONFLICT (" + joinStrings(conflictCols, ", ") + ") DO UPDATE SET " + joinStrings(updates, ", ")
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

    public func hasReturningSupport(): Bool { true }

    public func hasJSONSupport(): Bool { true }

    public func migrator(db: DB): Migrator { throw Exception("PostgreSQL migration not yet implemented") }

    public func initialize(db: DB): Unit {}

    public func defaultValueOf(st: StorageType): String { "" }

    private func joinStrings(strings: ArrayList<String>, separator: String): String {
        var result = ""
        var first = true
        for (s in strings) {
            if (first) {
                result = s
                first = false
            } else {
                result = result + separator + s
            }
        }
        result
    }
}
