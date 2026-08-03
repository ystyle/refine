package refine

import std.collection.ArrayList

// M18: 三方言共享的渲染基类。
//
// render / renderBody / renderExpr / renderExprList / renderAndList / renderOp / renderUnaryOp
// 在三方言中完全一致，收敛到本基类统一实现；方言差异收敛到两类钩子：
//
//  1. open 钩子（提供 2/3 方言的共识默认，另一方言按需覆盖）：
//     - renderParam()       参数占位符，默认 "?"（SQLite/MySQL），PG 覆盖为 "$n" 并推进 paramIdx
//     - quoteIdentifier()   标识符引用，默认 ANSI 双引号（SQLite/PG），MySQL 覆盖为反引号
//     - hasLockSupport()    SELECT ... FOR UPDATE，默认 true（MySQL/PG），SQLite 覆盖为 false
//     - renderLimitOffset() LIMIT/OFFSET 段组装，默认原样追加（SQLite/PG），MySQL 覆盖裸 OFFSET 哨兵
//     - hasIsolationSupport() 事务隔离级别，默认 true（MySQL/PG），SQLite 覆盖为 false
//     - hasReturningSupport() RETURNING 支持，默认 false（SQLite/MySQL），PG 覆盖为 true
//  2. 抽象方法（三方言互不相同，子类必须实现）：
//     name / dataTypeOf / upsertSQL / migrator / defaultValueOf
//
// 共享能力位 hasUpsertSupport / hasJSONSupport / initialize 三方言一致，直接在本基类实现。
public abstract class AbstractDialect <: Dialect {
    // 渲染过程中的参数缓冲与 PG $n 编号游标（render() 每次重置）
    protected var params = ArrayList<Any>()
    protected var paramIdx: Int64 = 1

    // ── 方言差异钩子（open 默认实现，子类按需覆盖）──

    // 参数占位符：默认 "?"（SQLite/MySQL）；PG 覆盖为 "$n" 并推进 paramIdx。
    // renderBody 的 UPDATE SET 与 renderExpr 的 Value 分支共用，保证参数顺序与占位符一致。
    protected open func renderParam(): String {
        "?"
    }

    // 标识符引用：默认 ANSI 双引号（SQLite/PG）；MySQL 覆盖为反引号。
    // 内嵌引号必须转义（" → ""），否则可逃逸标识符边界构造任意 SQL（C9：封闭 SQL 注入通道）。
    public open func quoteIdentifier(name: String): String {
        "\"" + name.replace("\"", "\"\"") + "\""
    }

    // 是否支持 SELECT ... FOR UPDATE 行锁：默认 true（MySQL/PG）；SQLite 无行锁概念（单写者），覆盖为 false
    protected open func hasLockSupport(): Bool {
        true
    }

    // LIMIT/OFFSET 段组装（renderBody 选择分支尾部调用）：
    // 默认原样返回 limit 列表（SQLite/PG）；MySQL 覆盖为在裸 OFFSET（无 LIMIT）前补
    // `LIMIT 18446744073709551615` 哨兵（I3：MySQL 裸 OFFSET 是语法错误，LIMIT+OFFSET 并存时保持原样）。
    // UPDATE/DELETE 路径不经过此处，不受影响。
    protected open func renderLimitOffset(hasLimit: Bool, hasOffset: Bool, limit: ArrayList<String>): ArrayList<String> {
        limit
    }

    // ── 能力位（三方言一致的共享默认）──

    // upsert 与 json 已启用（SQLite ≥3.24 支持 ON CONFLICT，JSON1 自 3.38 起内建；MySQL/PG 原生支持）。
    // 后续引入连接抽象后，再按实际 SQLite 版本细化开关（见 audit I15 决策）。
    public func hasUpsertSupport(): Bool { true }
    public func hasJSONSupport(): Bool { true }

    // 事务隔离级别支持：默认 true（MySQL/PG）；SQLite 无事务隔离级别概念（单写者），覆盖为 false
    public open func hasIsolationSupport(): Bool { true }

    // RETURNING 支持：默认 false（SQLite/MySQL，save 走非 RETURNING 路径）；PG 覆盖为 true
    public open func hasReturningSupport(): Bool { false }

    public func initialize(db: DB): Unit {}

    // ── 共享渲染逻辑（三方言完全一致）──

    public func render(stmt: Statement): (String, Array<Any>) {
        params = ArrayList<Any>()
        paramIdx = 1
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
        var hasLimit = false
        var hasOffset = false
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
                    hasLimit = true
                    limit.add("LIMIT " + n.toString())
                case OffsetClause(n) =>
                    hasOffset = true
                    limit.add("OFFSET " + n.toString())
                case JoinClause(table, alias, on) =>
                    joins.add("LEFT JOIN " + quoteIdentifier(table) + " " + quoteIdentifier(alias) + " ON " + renderExpr(on))
                case UpdateClause(table, setCols, setVals) =>
                    var setParts = ArrayList<String>()
                    for (_si_ in 0..setCols.size) {
                        setParts.add(quoteIdentifier(setCols[_si_]) + " = " + renderParam())
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
            for (s in renderLimitOffset(hasLimit, hasOffset, limit)) { parts.add(s) }
            if (hasLock && hasLockSupport()) { parts.add("FOR UPDATE") }
        }
        String.join(parts.toArray(), delimiter: " ")
    }

    private func renderExpr(expr: Expr): String {
        match (expr) {
            case Column(n) => quoteIdentifier(n)
            case Value(v) =>
                params.add(v)
                renderParam()
            case Binary(l, op, r) =>
                renderExpr(l) + " " + renderOp(op) + " " + renderExpr(r)
            case Range(subject, low, high) =>
                renderExpr(subject) + " BETWEEN " + renderExpr(low) + " AND " + renderExpr(high)
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
            case Between => throw Exception("BinOp.Between 不是二元操作符：Binary(x, Between, y) 缺 AND high，改用 Expr.Range（Col.between(low, high)）")
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

    // ── 方言专属（三方言互不相同，子类必须实现）──

    public func name(): String
    public func dataTypeOf(st: StorageType): String
    public func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): (String, Int64)
    public func migrator(db: DB): Migrator
    public func defaultValueOf(st: StorageType): String
}
