package refine

import std.collection.ArrayList

public class MySQLDialect <: Dialect {
    public func name(): String { "mysql" }

    public func quoteIdentifier(name: String): String {
        "`" + name + "`"
    }

    public func render(stmt: Statement): (String, Array<Any>) {
        var sql = ArrayList<String>()
        var params = ArrayList<Any>()
        for (i in 0..stmt.clauses.size) {
            let clause = stmt.clauses[i]
            match (clause) {
                case SelectClause(fields) =>
                    if (fields.size == 0) {
                        sql.add("SELECT *")
                    } else {
                        sql.add("SELECT " + renderExprList(fields))
                    }
                case FromClause(table) =>
                    sql.add("FROM " + quoteIdentifier(table))
                case WhereClause(predicates) =>
                    sql.add("WHERE " + renderExprList(predicates))
                case OrderByClause(fields) =>
                    sql.add("ORDER BY " + renderExprList(fields))
                case GroupByClause(fields) =>
                    sql.add("GROUP BY " + renderExprList(fields))
                case HavingClause(predicates) =>
                    sql.add("HAVING " + renderExprList(predicates))
                case LimitClause(n) =>
                    sql.add("LIMIT " + n.toString())
                case OffsetClause(n) =>
                    sql.add("OFFSET " + n.toString())
                case JoinClause(table, alias, on) =>
                    sql.add("LEFT JOIN " + quoteIdentifier(table) + " " + quoteIdentifier(alias) + " ON " + renderExpr(on))
            }
        }
        (joinStrings(sql, " "), params.toArray())
    }

    private func renderExpr(expr: Expr): String {
        match (expr) {
            case Column(n) => quoteIdentifier(n)
            case Value(v) => "?"
            case Binary(l, op, r) =>
                renderExpr(l) + " " + renderOp(op) + " " + renderExpr(r)
            case Unary(op, e) =>
                renderUnaryOp(op) + " " + renderExpr(e)
            case FuncCall(n, args) =>
                n + "(" + renderExprList(args) + ")"
            case Raw(s) => s
            case Ordered(expr, dir) =>
                renderExpr(expr) + " " + dir
            case SubQuery(s) =>
                let (subSql, subParams) = render(s)
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

    public func hasUpsertSupport(): Bool { true }

    public func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>): String {
        var cols = ArrayList<String>()
        var placeholders = ArrayList<String>()
        var updates = ArrayList<String>()
        for (c in columns) {
            cols.add(quoteIdentifier(c))
            placeholders.add("?")
            updates.add(quoteIdentifier(c) + " = VALUES(" + quoteIdentifier(c) + ")")
        }
        "INSERT INTO " + quoteIdentifier(table) + " (" + joinStrings(cols, ", ") + ") VALUES (" + joinStrings(placeholders, ", ") + ") ON DUPLICATE KEY UPDATE " + joinStrings(updates, ", ")
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
