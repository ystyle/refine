package refine

import std.collection.ArrayList

// M18: 三方言共享的渲染基类。
//
// render / renderBody / renderExpr / renderExprList / renderAndList / renderOp
// 在三方言中完全一致，收敛到本基类统一实现；方言差异收敛到两类钩子：
//
//  1. open 钩子（提供 2/3 方言的共识默认，另一方言按需覆盖）：
//     - renderParam(ctx)    参数占位符，默认 "?"（SQLite/MySQL），PG 覆盖为 "$n" 并推进 ctx.paramIdx
//     - quoteIdentifier()   标识符引用，默认 ANSI 双引号（SQLite/PG），MySQL 覆盖为反引号
//     - hasLockSupport()    SELECT ... FOR UPDATE，默认 true（MySQL/PG），SQLite 覆盖为 false
//     - renderLimitOffset() LIMIT/OFFSET 段组装，默认原样追加（SQLite/PG），MySQL 覆盖裸 OFFSET 哨兵
//     - hasIsolationSupport() 事务隔离级别，默认 true（MySQL/PG），SQLite 覆盖为 false
//     - hasReturningSupport() RETURNING 支持，默认 false（SQLite/MySQL），PG 覆盖为 true
//  2. 抽象方法（三方言互不相同，子类必须实现）：
//     name / dataTypeOf / upsertSQL / migrator / defaultValueOf
//
// 共享能力位 hasUpsertSupport / hasJSONSupport / initialize 三方言一致，直接在本基类实现。
//
// R-I4：渲染状态收敛为 RenderContext。render 的参数缓冲（params）与 PG $n 编号游标
// （paramIdx）曾经是 AbstractDialect 的实例字段：runtime 只构建一个 dialect 实例并被
// 连接池多线程共享，render() 重置后递归填充期间被其它线程的 render 交叉污染，产生错位的
// 参数与 PG $n 编号。收敛为 render() 每次新建的本地 RenderContext 并沿
// renderBody/renderExpr/renderExprList/renderAndList/renderParam 传递后，渲染过程不再触碰
// 任何实例状态，共享 dialect 实例天然并发安全。renderLimitOffset 只消费本地 limit 列表
// （无参数缓冲），quoteIdentifier/hasLockSupport/hasIsolationSupport/hasReturningSupport
// 为无状态，均不需要 ctx。
public abstract class AbstractDialect <: Dialect {
    // ── 方言差异钩子（open 默认实现，子类按需覆盖）──

    // 参数占位符：默认 "?"（SQLite/MySQL）；PG 覆盖为 "$n" 并推进 ctx.paramIdx。
    // renderBody 的 UPDATE SET 与 renderExpr 的 Value 分支共用，保证参数顺序与占位符一致。
    // ctx 承载单次渲染的本地状态（参数缓冲 + $n 编号游标），见文件头 R-I4 说明。
    protected open func renderParam(ctx: RenderContext): String {
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
    // 边界：该钩子仅覆盖尾部分页调整类差异（如 MySQL 裸 OFFSET 哨兵）；TOP 式分页（需改写 SELECT 头）
    // 或 ROWNUM 式（改变子句结构）需扩展基类签名或新增钩子。
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
        let ctx = RenderContext()
        (renderBody(ctx, stmt), ctx.params.toArray())
    }

    private func renderBody(ctx: RenderContext, stmt: Statement): String {
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
                    else { select.add("SELECT " + renderExprList(ctx, fields)) }
                case FromClause(table) =>
                    from.add("FROM " + quoteIdentifier(table))
                case WhereClause(predicates) =>
                    let prefix = if (whereAdded) { "AND " } else { "WHERE " }
                    whereAdded = true
                    whereClause.add(prefix + renderAndList(ctx, predicates))
                case OrderByClause(fields) =>
                    orderBy.add("ORDER BY " + renderExprList(ctx, fields))
                case GroupByClause(fields) =>
                    groupBy.add("GROUP BY " + renderExprList(ctx, fields))
                case HavingClause(predicates) =>
                    having.add("HAVING " + renderAndList(ctx, predicates))
                case LimitClause(n) =>
                    hasLimit = true
                    limit.add("LIMIT " + n.toString())
                case OffsetClause(n) =>
                    hasOffset = true
                    limit.add("OFFSET " + n.toString())
                case JoinClause(table, alias, on) =>
                    joins.add("LEFT JOIN " + quoteIdentifier(table) + " " + quoteIdentifier(alias) + " ON " + renderExpr(ctx, on))
                case UpdateClause(table, setCols, setVals) =>
                    var setParts = ArrayList<String>()
                    for (_si_ in 0..setCols.size) {
                        setParts.add(quoteIdentifier(setCols[_si_]) + " = " + renderParam(ctx))
                        ctx.params.add(setVals[_si_])
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

    private func renderExpr(ctx: RenderContext, expr: Expr): String {
        match (expr) {
            case Column(n) => quoteIdentifier(n)
            case Value(v) =>
                ctx.params.add(v)
                renderParam(ctx)
            case Binary(l, op, r) =>
                renderExpr(ctx, l) + " " + renderOp(op) + " " + renderExpr(ctx, r)
            case Range(subject, low, high) =>
                renderExpr(ctx, subject) + " BETWEEN " + renderExpr(ctx, low) + " AND " + renderExpr(ctx, high)
            case Unary(op, e) =>
                // F4: IS NULL / IS NOT NULL 必须后置（`"col" IS NULL`）——修复前渲染成
                // `IS NULL "col"`（NOT 前缀、IS NULL 后缀混在一起），SQLite/MySQL/PG
                // 真实执行均语法错误（PG "syntax error at or near NULL"）。此前 Int64 软删
                // 走 Binary Eq 0、col.isTrue() 未落地，该路径从未被真实 SQL 触发。
                match (op) {
                    case Not => "NOT " + renderExpr(ctx, e)
                    case IsNull => renderExpr(ctx, e) + " IS NULL"
                    case IsNotNull => renderExpr(ctx, e) + " IS NOT NULL"
                }
            case FuncCall(n, args) =>
                n + "(" + renderExprList(ctx, args) + ")"
            case Raw(s) => s
            case Ordered(expr, dir) =>
                renderExpr(ctx, expr) + " " + dir
            case Aliased(expr, alias) =>
                renderExpr(ctx, expr) + " AS " + quoteIdentifier(alias)
            case SubQuery(s) =>
                "(" + renderBody(ctx, s) + ")"
        }
    }

    private func renderExprList(ctx: RenderContext, exprs: Array<Expr>): String {
        if (exprs.size == 0) { return "" }
        var parts = ArrayList<String>()
        for (e in exprs) {
            parts.add(renderExpr(ctx, e))
        }
        String.join(parts.toArray(), delimiter: ", ")
    }

    private func renderAndList(ctx: RenderContext, exprs: Array<Expr>): String {
        if (exprs.size == 0) { return "" }
        var parts = ArrayList<String>()
        for (e in exprs) {
            parts.add(renderExpr(ctx, e))
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

    // ── 方言专属（三方言互不相同，子类必须实现）──

    public func name(): String
    public func dataTypeOf(st: StorageType): String
    public func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): (String, Int64)
    public func migrator(db: DB): Migrator
    public func defaultValueOf(st: StorageType): String
}

// 单次 render() 调用的本地渲染状态（参数缓冲 + PG $n 编号游标），见文件头 R-I4 说明。
// 必须 public：PostgreSQLDialect（独立包外）覆盖 protected open renderParam(ctx) 需要引用该类型。
public class RenderContext {
    var params: ArrayList<Any> = ArrayList<Any>()
    var paramIdx: Int64 = 1

    public init() {}
}
