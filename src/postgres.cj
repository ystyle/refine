package refine

import std.collection.ArrayList

public class PostgreSQLDialect <: Dialect {
    private var params = ArrayList<Any>()
    private var paramIndex: Int64 = 0

    public func name(): String { "postgresql" }

    public func quoteIdentifier(name: String): String {
        "\"" + name + "\""
    }

    public func render(stmt: Statement): (String, Array<Any>) {
        paramIndex = 0
        params = ArrayList<Any>()
        let sql = renderStatement(stmt)
        (sql, params.toArray())
    }

    private func renderStatement(stmt: Statement): String {
        var parts = ArrayList<String>()
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
        joinStrings(parts, " ")
    }

    private func renderExpr(expr: Expr): String {
        match (expr) {
            case Column(n) => quoteIdentifier(n)
            case Value(v) =>
                paramIndex++
                params.add(v)
                "$" + paramIndex.toString()
            case Binary(l, op, r) =>
                renderExpr(l) + " " + renderOp(op) + " " + renderExpr(r)
            case Unary(op, e) =>
                renderUnaryOp(op) + " " + renderExpr(e)
            case FuncCall(n, args) =>
                n + "(" + renderExprList(args) + ")"
            case Raw(s) => s
            case SubQuery(s) =>
                "(" + renderStatement(s) + ")"
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
