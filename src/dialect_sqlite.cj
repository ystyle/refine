package refine

import std.collection.ArrayList

public class SQLiteDialect <: Dialect {
    public func name(): String { "sqlite" }

    public func quoteIdentifier(name: String): String {
        "\"" + name + "\""
    }

    public func render(stmt: Statement): (String, Array<Any>) {
        var sql = ArrayList<String>()
        var params = ArrayList<Any>()
        var hasSelect = false
        for (i in 0..stmt.clauses.size) {
            match (stmt.clauses[i]) {
                case SelectClause(_) => hasSelect = true
                case _ => ()
            }
        }
        if (!hasSelect) { sql.add("SELECT *") }
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
            case Aliased(expr, alias) =>
                renderExpr(expr) + " AS " + quoteIdentifier(alias)
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

    public func hasUpsertSupport(): Bool { false }

    public func upsertSQL(_table: String, _columns: Array<String>, _conflictColumns: Array<String>): String { "" }

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

    public func hasReturningSupport(): Bool { false }

    public func hasJSONSupport(): Bool { false }

    public func migrator(db: DB): Migrator { SQLiteMigrator(db) }

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
