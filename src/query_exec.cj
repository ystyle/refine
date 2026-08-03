package refine

import std.collection.HashMap
import std.time.MonoTime
import std.database.sql.QueryResult

// M20: Query<T> 执行方法组——分页 / 全量查询 / 单条 / 计数 / exists / 聚合。
// 通过 extend 从 query.cj 核心类中按职责拆出。extend 不能访问被扩展类型
// 的 private 成员，故所调用的类内成员（requireExecutor/getDialect/closeExecutor
// 及 query_batch.cj 的 assembleIncludes/mapMainResult/requireCollectionIdSupport）
// 为包级可见；本文件内只在本块使用的方法（copyDataClauses/countWith/聚合内部）
// 为 private（扩展内 private 仅同块可见）。
extend<T> Query<T> {

    public func page(page: Int64, size: Int64): Page<T> {
        if (page < 1) { throw QueryException("page must be >= 1") }
        if (size < 1) { throw QueryException("size must be >= 1") }
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            processIncluded(dialect)
            requireCollectionIdSupport()
            let total = countWith(exec, dialect)
            let pager = Statement()
            for (clause in stmt.clauses) {
                match (clause) {
                    case LimitClause(_) | OffsetClause(_) => ()
                    case _ => pager.addClause(clause)
                }
            }
            pager.addClause(LimitClause(size))
            pager.addClause(OffsetClause((page - 1) * size))
            let (sql, params) = dialect.render(pager)
            Logger.logSQL(sql, params)
            let result = exec.query(sql, params)
            // 主查询无 include JOIN：LIMIT/OFFSET 作用于源表行，单页恰好返回 size 个主实体。
            let columnMap = buildColumnMap(result.columnInfos, columnOffset)
            let (entities, rawIds) = mapMainResult(result, columnMap, this.mapper.getOrThrow())
            // 批量装配在 AfterFind hook 之后执行（同 all()：hook 读关联字段为未装配状态）。
            assembleIncludes(exec, dialect, entities, rawIds)
            Page(entities, total, page, size)
        } finally {
            closeExecutor(exec)
        }
    }

    public func all(): Array<T> {
        match (this.mapper) {
            case Some(m) => all(m)
            case None => throw QueryException("No auto-mapper. Use findAll() or all(mapper).")
        }
    }

    public func all(mapper: (QueryResult, HashMap<String, Int64>) -> T): Array<T> {
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            processIncluded(dialect)
            requireCollectionIdSupport()
            let (sql, params) = dialect.render(stmt)
            Logger.logSQL(sql, params)
            let start = MonoTime.now()
            let result = exec.query(sql, params)
            let elapsed = MonoTime.now() - start
            Logger.logSlowQuery(sql, elapsed)
            let columnMap = buildColumnMap(result.columnInfos, columnOffset)
            let (entities, rawIds) = mapMainResult(result, columnMap, mapper)
            // 批量装配在 AfterFind hook 之后执行：主映射循环内先跑 runAfterFindHooks，
            // hook 内读取关联字段（如 entity.author）为未装配状态（None）——批量架构的固有取舍，
            // 旧 LEFT JOIN 方案在 hook 前已完成 ref_to 装配。
            assembleIncludes(exec, dialect, entities, rawIds)
            entities
        } finally {
            closeExecutor(exec)
        }
    }

    public func one(): Option<T> {
        match (this.mapper) {
            case Some(m) => one(m)
            case None => throw QueryException("No auto-mapper. Use findOne() or one(mapper).")
        }
    }

    public func one(mapper: (QueryResult, HashMap<String, Int64>) -> T): Option<T> {
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            processIncluded(dialect)
            requireCollectionIdSupport()
            let oneStmt = Statement()
            for (clause in stmt.clauses) {
                oneStmt.addClause(clause)
            }
            oneStmt.addClause(LimitClause(1))
            let (sql, params) = dialect.render(oneStmt)
            Logger.logSQL(sql, params)
            let start = MonoTime.now()
            let result = exec.query(sql, params)
            let elapsed = MonoTime.now() - start
            Logger.logSlowQuery(sql, elapsed)
            let columnMap = buildColumnMap(result.columnInfos, columnOffset)
            let (entities, rawIds) = mapMainResult(result, columnMap, mapper)
            var res: Option<T> = None
            if (entities.size > 0) { res = Some(entities[0]) }
            // 批量装配在 AfterFind hook 之后执行（同 all()：hook 读关联字段为未装配状态）。
            match (res) {
                case Some(_) => assembleIncludes(exec, dialect, entities, rawIds)
                case None => ()
            }
            res
        } finally {
            closeExecutor(exec)
        }
    }

    public func count(): Int64 {
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            countWith(exec, dialect)
        } finally {
            closeExecutor(exec)
        }
    }

    // countWith/exists()/aggregate 复用的数据子句拷贝：仅保留 FROM/WHERE/JOIN。
    private func copyDataClauses(source: Statement, target: Statement): Unit {
        for (clause in source.clauses) {
            match (clause) {
                case FromClause(_) | WhereClause(_) | JoinClause(_, _, _) => target.addClause(clause)
                case _ => ()
            }
        }
    }

    private func countWith(exec: ExecutionContext, dialect: Dialect): Int64 {
        // 批量模式主查询无 include JOIN：COUNT(*) 天然正确，无需 COUNT(DISTINCT id)
        // （旧 LEFT JOIN 方案的子行展开放大 total 问题已随 JOIN 移除而消除）。
        let countStmt = Statement()
        countStmt.addClause(SelectClause([Raw("COUNT(*)")]))
        copyDataClauses(stmt, countStmt)
        let (sql, params) = dialect.render(countStmt)
        Logger.logSQL(sql, params)
        let start = MonoTime.now()
        let result = exec.query(sql, params)
        let elapsed = MonoTime.now() - start
        Logger.logSlowQuery(sql, elapsed)
        var cnt: Int64 = 0
        if (result.next()) {
            cnt = result.get<Int64>(0 + columnOffset)
        }
        cnt
    }

    public func exists(): Bool {
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            let existsStmt = Statement()
            existsStmt.addClause(SelectClause([Raw("1")]))
            copyDataClauses(stmt, existsStmt)
            existsStmt.addClause(LimitClause(1))
            let (sql, params) = dialect.render(existsStmt)
            Logger.logSQL(sql, params)
            let result = exec.query(sql, params)
            result.next()
        } finally {
            closeExecutor(exec)
        }
    }

    public func sum(col: Col<Int64>): Int64 { aggregateInt("SUM", col) }
    public func sum(col: Col<Float64>): Float64 { aggregateFloat("SUM", col) }
    public func avg(col: Col<Int64>): Float64 { aggregateFloat("AVG", col) }
    public func avg(col: Col<Float64>): Float64 { aggregateFloat("AVG", col) }
    public func min(col: Col<Int64>): Int64 { aggregateInt("MIN", col) }
    public func max(col: Col<Int64>): Int64 { aggregateInt("MAX", col) }
    // M8: min/max 对 String 列合法（字典序），String 聚合读取器返回空串作零值
    public func min(col: Col<String>): String { aggregateString("MIN", col) }
    public func max(col: Col<String>): String { aggregateString("MAX", col) }

    private func aggregateInt(fn: String, col: Col<Int64>): Int64 {
        aggregate(fn, col.name, 0, { r, o => r.getOrNull<Int64>(0 + o) })
    }

    private func aggregateFloat(fn: String, col: Col<Int64>): Float64 {
        aggregate(fn, col.name, 0.0, { r, o => r.getOrNull<Float64>(0 + o) })
    }

    private func aggregateFloat(fn: String, col: Col<Float64>): Float64 {
        aggregate(fn, col.name, 0.0, { r, o => r.getOrNull<Float64>(0 + o) })
    }

    private func aggregateString(fn: String, col: Col<String>): String {
        aggregate(fn, col.name, "", { r, o => r.getOrNull<String>(0 + o) })
    }

    private func aggregate<R>(fn: String, colName: String, zero: R, read: (QueryResult, Int64) -> ?R): R {
        let exec = requireExecutor()
        try {
            let aggStmt = Statement()
            // M8: 聚合列名经方言 quoteIdentifier 引号化（修复前 Raw(fn + "(" + colName + ")")
            // 拼裸列名，与 C9 标识符通道同源——列名含特殊字符时会被拼进 SQL 文本）
            let dialect = getDialect()
            aggStmt.addClause(SelectClause([Raw(fn + "(" + dialect.quoteIdentifier(colName) + ")")]))
            copyDataClauses(stmt, aggStmt)
            let (sql, params) = dialect.render(aggStmt)
            Logger.logSQL(sql, params)
            let result = exec.query(sql, params)
            var value = zero
            if (result.next()) {
                match (read(result, columnOffset)) {
                    case Some(v) => value = v
                    case None => ()
                }
            }
            value
        } finally {
            closeExecutor(exec)
        }
    }
}
