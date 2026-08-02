package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.time.MonoTime
import std.database.sql.QueryResult


class FieldOverrideRelation <: IRelation {
    private var inner: IRelation
    private var overrides: Array<Col<Any>>

    public init(inner: IRelation, fields: Array<Col<Any>>) {
        this.inner = inner
        this.overrides = fields
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        let (kind, name, table, fk, via, _) = inner.resolve()
        (kind, name, table, fk, via, overrides)
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any {
        inner.getTargetMapper()
    }

    public func getFieldSetter(): (Any, Any) -> Unit {
        inner.getFieldSetter()
    }

    public func getForeignKeyExtractor(): (Any) -> Any {
        inner.getForeignKeyExtractor()
    }

    public func getTargetIdExtractor(): (Any) -> Any {
        inner.getTargetIdExtractor()
    }

    public func withInclude(rel: IRelation): IRelation {
        FieldOverrideRelation(inner.withInclude(rel), overrides)
    }

    public func getNested(): Array<IRelation> {
        inner.getNested()
    }

    public func isBatchSupported(): Bool {
        inner.isBatchSupported()
    }

    public func getJunctionTargetCol(): String {
        inner.getJunctionTargetCol()
    }
}

public class Query<T> {
    var stmt: Statement
    var included: ArrayList<IRelation>
    var alias: String
    var executor: Option<ExecutionContext> = None
    var queryDialect: Option<Dialect> = None
    var mapper: Option<(QueryResult, HashMap<String, Int64>) -> T> = None
    var db: Option<DB> = None
    var columnOffset: Int64 = 0
    public var typeName: String = ""
    var ref: Option<Refine> = None
    var keyExtractor: Option<(QueryResult, HashMap<String, Int64>) -> String> = None
    // Task 4: has_many/has_one 批量装配需要主实体主键的「原始值」（Int64/String 上转 Any），
    // 由宏层生成（XxxRawIdFromResult）在 setKeyExtractor 处一并挂载。keyExtractor 输出
    // String（复合主键 ":" 拼接），无法直接作为批量 IN 的 SQL 参数原值，故单独存 rawId。
    // 复合主键主实体不挂载（None），集合 include 装配入口会抛带说明的 QueryException。
    var rawIdExtractor: Option<(QueryResult, HashMap<String, Int64>) -> Any> = None

    public init() {
        this.stmt = Statement()
        this.included = ArrayList<IRelation>()
        this.alias = ""
    }

    // I9: 拷贝当前 Query 的全部状态，供 Refine.all/one 在副本上执行 using()，
    // 保证调用方持有的 Query 不被执行上下文（queryDialect/columnOffset/executor）污染。
    // clauses/included 逐项拷贝：Statement 的 clauses 是可变 ArrayList，
    // Task 2 后 processIncluded 已是 no-op，但深拷贝隔离仍必要——批量装配（Task 3+）
    // 与执行路径可能在副本上追加/改写 clause，调用方持有的原 Query 必须不受影响；
    // clause 内部（Expr 数组）在现有代码中不会被原地修改，直接共享即可。
    // 注意：新增 Query 字段时必须同步更新此处 copy()，否则 Refine.all/one 副本会丢字段。
    public func copy(): Query<T> {
        let q = Query<T>()
        for (clause in stmt.clauses) {
            q.stmt.addClause(clause)
        }
        for (inc in included) {
            q.included.add(inc)
        }
        q.alias = alias
        q.executor = executor
        q.queryDialect = queryDialect
        q.mapper = mapper
        q.db = db
        q.columnOffset = columnOffset
        q.typeName = typeName
        q.ref = ref
        q.keyExtractor = keyExtractor
        q.rawIdExtractor = rawIdExtractor
        q
    }

    public func dialect(d: Dialect): Query<T> {
        this.queryDialect = Some(d)
        this
    }

    public func select(fields: Array<Expr>): Query<T> {
        stmt.addClause(Clause.SelectClause(fields))
        this
    }

    public func from(alias: String): Query<T> {
        this.alias = alias
        stmt.addClause(FromClause(alias))
        this
    }

    public func filter(predicates: Array<Expr>): Query<T> {
        stmt.addClause(WhereClause(predicates))
        this
    }

    public func filter(predicate: Expr): Query<T> {
        stmt.addClause(WhereClause([predicate]))
        this
    }

    public func order(fields: Array<Expr>): Query<T> {
        stmt.addClause(OrderByClause(fields))
        this
    }

    public func limit(n: Int64): Query<T> {
        stmt.addClause(LimitClause(n))
        this
    }

    public func offset(n: Int64): Query<T> {
        stmt.addClause(OffsetClause(n))
        this
    }

    public func groupBy(fields: Array<Expr>): Query<T> {
        stmt.addClause(GroupByClause(fields))
        this
    }

    public func having(predicates: Array<Expr>): Query<T> {
        stmt.addClause(HavingClause(predicates))
        this
    }

    public func forUpdate(): Query<T> {
        stmt.addClause(LockClause)
        this
    }

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

    public func updateWhere(setCols: Array<String>, setVals: Array<Any>): Int64 {
        rejectJoin("updateWhere")
        if (setCols.size != setVals.size) { throw QueryException("setCols and setVals must have same size") }
        if (setCols.size == 0) { throw QueryException("no columns to update") }
        let table = requireTable()
        let updater = Statement()
        updater.addClause(UpdateClause(table, setCols, setVals))
        // JOIN 已由 rejectJoin 在上游拒绝
        for (clause in stmt.clauses) {
            match (clause) {
                case WhereClause(_) => updater.addClause(clause)
                case _ => ()
            }
        }
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            let (sql, params) = dialect.render(updater)
            Logger.logSQL(sql, params)
            let result = exec.execute(sql, params)
            result.rowCount
        } finally {
            closeExecutor(exec)
        }
    }

    public func deleteWhere(): Int64 {
        rejectJoin("deleteWhere")
        let table = requireTable()
        let deleter = Statement()
        deleter.addClause(DeleteClause(table))
        // JOIN 已由 rejectJoin 在上游拒绝
        for (clause in stmt.clauses) {
            match (clause) {
                case WhereClause(_) => deleter.addClause(clause)
                case _ => ()
            }
        }
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            let (sql, params) = dialect.render(deleter)
            Logger.logSQL(sql, params)
            let result = exec.execute(sql, params)
            result.rowCount
        } finally {
            closeExecutor(exec)
        }
    }

    private func getSourceTable(): String {
        for (clause in stmt.clauses) {
            match (clause) {
                case Clause.FromClause(t) => return t
                case _ => ()
            }
        }
        ""
    }

    private func requireTable(): String {
        let t = getSourceTable()
        if (t == "") {
            throw QueryException("No table set. Call from() before updateWhere/deleteWhere.")
        }
        t
    }

    // 回归（I4）：updateWhere/deleteWhere 的 dialect 渲染只输出 UPDATE/DELETE + WHERE，
    // JOIN 会被静默丢弃（且 ON 参数仍进 params 导致 PG $n 错位），有误更新/误删除风险。
    // 构建器层直接拒绝：带 JOIN 的查询禁止用于 updateWhere/deleteWhere。
    private func rejectJoin(operation: String): Unit {
        for (clause in stmt.clauses) {
            match (clause) {
                case JoinClause(_, _, _) => throw QueryException(operation + " does not support JOIN")
                case _ => ()
            }
        }
    }

    public func include(rel: IRelation): Query<T> {
        included.add(rel)
        this
    }

    public func include(rel: IRelation, fields: Array<Col<Any>>): Query<T> {
        let override = FieldOverrideRelation(rel, fields)
        included.add(override)
        this
    }

    public func using(exec: ExecutionContext): Query<T> {
        this.executor = exec
        this.queryDialect = Some(exec.getDialect())
        this.columnOffset = exec.getParamOffset()
        this
    }

    public func using(database: DB): Query<T> {
        this.db = Some(database)
        this.executor = Some(database.session())
        this
    }

    public func using(rf: Refine): Query<T> {
        this.executor = Some(rf.session())
        this.queryDialect = Some(rf.getDialect())
        this.columnOffset = rf.getParamOffset()
        this.ref = Some(rf)
        this
    }

    // Task 2: 主查询分离——include 不再生成 LEFT JOIN/别名 SELECT/限定（qualify）。
    // 主查询只渲染源表自身（无 JOIN），include 预加载改由批量分步查询协议完成：
    // ref_to（Task 3）、has_one/has_many（Task 4）、ref_many（Task 5）均已接入
    // all()/one()/page()，经 assembleIncludes 按各自协议批量装配。此方法保留为 no-op 挂接入口。
    public func processIncluded(dialect: Dialect): Unit {
        ()
    }

    // Task 3: ref_to 批量装配。主查询返回实体后调用：
    //   1. 按目标表分组（保持 rels 顺序），同表多个 ref_to 关系合并为一条批量查询；
    //   2. 收集各实体外键值（getForeignKeyExtractor），去重并过滤 0/"" 未设置值；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT <字段并集> FROM <目标表> WHERE "id" IN (?, ...)` 批量取目标；
    //   5. 目标 id → 实体 映射，按各关系 fk 值命中回填（未命中保持未挂载，不抛错）。
    // Task 6 扩展：返回各关系实际装配到的目标实体数组（按关系去重——同一目标实体被
    // 多个主实体引用时只收集一次），供嵌套 include 递归装配下一层关联使用。
    // E 泛型：顶层为 Array<T>（主查询实体），嵌套层为 Array<Any>（上一层装配结果）。
    // 批量 SQL 采用手写占位符（与 relation_gen.cj 一致）：IN 列表不是 Expr 模型的一部分
    // （Expr.Value 数组渲染为单个参数，无法展开为 ?,?,...），且在 scope 内不允许改动
    // 三方言 renderExpr 为 IN 列表新增变体，故 SELECT/FROM 走 Statement 机器，
    // WHERE 的 IN 部分由 buildInClause 手写占位符生成。
    private func assembleRefTo<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rels: Array<IRelation>
    ): ArrayList<(IRelation, Array<Any>)> {
        let result = ArrayList<(IRelation, Array<Any>)>()
        if (rels.size == 0 || entities.size == 0) { return result }

        var groups = ArrayList<(String, ArrayList<IRelation>)>()
        for (inc in rels) {
            let (kind, _, targetTable, _, _, _) = inc.resolve()
            if (kind != RelationKind.RefToRel) { continue }
            var found = false
            for (i in 0..groups.size) {
                if (groups[i][0] == targetTable) {
                    groups[i][1].add(inc)
                    found = true
                    break
                }
            }
            if (!found) {
                let rels2 = ArrayList<IRelation>()
                rels2.add(inc)
                groups.add((targetTable, rels2))
            }
        }

        for (i in 0..groups.size) {
            let targetTable = groups[i][0]
            let rels2 = groups[i][1]

            // 1. 收集该目标表全部 fk 值（跨关系去重、过滤 0/""）
            var ids = ArrayList<Any>()
            var seen = HashMap<String, Bool>()
            for (rel in rels2) {
                let extractor = rel.getForeignKeyExtractor()
                for (entity in entities) {
                    let v = extractor(entity)
                    if (isEmptyFk(v)) { continue }
                    let key = fkKey(v)
                    if (!seen.contains(key)) {
                        seen[key] = true
                        ids.add(v)
                    }
                }
            }
            if (ids.size == 0) { continue }

            // 2. 字段并集 + 强制目标主键列（装配查表与回填都用），批量查询
            let cols = buildBatchSelectCols(rels2, ["id"])
            let (inSQL, inParams) = buildInClause(dialect, "id", ids.toArray())
            let result2 = execBatchQuery(exec, dialect, targetTable, cols, inSQL, inParams)

            // 3. 目标 id → 实体 映射（同表关系共享同一目标 RowMapper）
            let columnMap = buildColumnMap(result2.columnInfos, exec.getParamOffset())
            let idIdx = columnMap.get("id").getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels2[0].getTargetMapper()
            var targetMap = HashMap<String, Any>()
            while (result2.next()) {
                let idKey = if (isStringPk) {
                    result2.get<String>(idIdx)
                } else {
                    result2.get<Int64>(idIdx).toString()
                }
                targetMap[idKey] = targetMapper(result2, columnMap)
            }

            // 4. 回填：fk 命中即挂载，未命中（目标被删）保持未挂载；同时收集该关系
            //    装配到的目标实体（按 fkKey 去重：多个主实体引用同一目标只收集一次）。
            for (rel in rels2) {
                let extractor = rel.getForeignKeyExtractor()
                let setter = rel.getFieldSetter()
                var targets = ArrayList<Any>()
                var targetSeen = HashMap<String, Bool>()
                for (entity in entities) {
                    let v = extractor(entity)
                    if (isEmptyFk(v)) { continue }
                    let key = fkKey(v)
                    match (targetMap.get(key)) {
                        case Some(t) =>
                            setter(entity, t)
                            if (!targetSeen.contains(key)) {
                                targetSeen[key] = true
                                targets.add(t)
                            }
                        case None => ()
                    }
                }
                result.add((rel, targets.toArray()))
            }
        }
        result
    }

    // 构建 `col IN (?, ?...)` 子句。契约：返回的 (fragment, params) 必须一体追加——
    // 本 WHERE 子句内不能再有其它 Value 占位符（否则 render 收集的参数顺序会与占位符错位）。
    // 批量装配目前只有 IN 列表一个参数源，此契约在 Task 4/5 复用批量装配时同样成立。
    private func buildInClause(dialect: Dialect, col: String, ids: Array<Any>): (String, Array<Any>) {
        buildInClauseCol(dialect.quoteIdentifier(col), ids)
    }

    // buildInClause 的通用形态：colSQL 是调用方已构造好的列引用片段（可带表限定，
    // 如 SQLite 的 `"post_tags"."postWithRel_id"`），仅负责生成占位符与参数。
    // Task 5 ref_many junction 查询的 IN 列在中间表上且需表限定，不能经 quoteIdentifier 二次转义。
    private func buildInClauseCol(colSQL: String, ids: Array<Any>): (String, Array<Any>) {
        var placeholders = ArrayList<String>()
        for (_ in 0..ids.size) { placeholders.add("?") }
        (colSQL + " IN (" + String.join(placeholders.toArray(), delimiter: ", ") + ")", ids)
    }

    // 批量 SELECT 的字段并集 + 强制列：同表多关系合并时取所有选中列；forced 为必须选中的列
    // （目标主键 id、has_many/has_one 的 fk 分组键），即使不在字段子集里也强制前置。
    // 取舍：合并查询按「并集」SELECT，共享目标实体携带并集列值（非某关系声明的子集），属预期行为。
    private func buildBatchSelectCols(rels: ArrayList<IRelation>, forced: Array<String>): Array<Expr> {
        var fieldNames = ArrayList<String>()
        var seenField = HashMap<String, Bool>()
        for (rel in rels) {
            let (_, _, _, _, _, fields) = rel.resolve()
            for (c in fields) {
                if (!seenField.contains(c.name)) {
                    seenField[c.name] = true
                    fieldNames.add(c.name)
                }
            }
        }
        var cols = ArrayList<Expr>()
        var selected = HashMap<String, Bool>()
        for (name in forced) {
            cols.add(Expr.Column(name))
            selected[name] = true
        }
        for (name in fieldNames) {
            if (!selected.contains(name)) {
                selected[name] = true
                cols.add(Expr.Column(name))
            }
        }
        cols.toArray()
    }

    // 执行批量 IN 查询：SELECT <cols> FROM <table> WHERE <inSQL>，返回结果集。
    // inSQL/inParams 必须由 buildInClause 一体生成（本 WHERE 内无其它 Value 占位符），
    // SELECT/FROM 走 Statement 机器、WHERE 的 IN 部分手写占位符（见 assembleRefTo 注释）。
    private func execBatchQuery(
        exec: ExecutionContext,
        dialect: Dialect,
        targetTable: String,
        cols: Array<Expr>,
        inSQL: String,
        inParams: Array<Any>
    ): QueryResult {
        let bs = Statement()
        bs.addClause(Clause.SelectClause(cols))
        bs.addClause(Clause.FromClause(targetTable))
        bs.addClause(Clause.WhereClause([Expr.Raw(inSQL)]))
        let (sql, baseParams) = dialect.render(bs)
        var params = ArrayList<Any>()
        for (p in baseParams) { params.add(p) }
        for (v in inParams) { params.add(v) }
        Logger.logSQL(sql, params.toArray())
        exec.query(sql, params.toArray())
    }

    private func isEmptyFk(v: Any): Bool {
        match (v) {
            case i: Int64 => i == 0
            case s: String => s == ""
            case _ => false
        }
    }

    private func fkKey(v: Any): String {
        match (v) {
            case i: Int64 => i.toString()
            case s: String => s
            case _ => throw QueryException("unsupported foreign key value type for batch ref_to")
        }
    }

    private func fkIsString(v: Any): Bool {
        match (v) {
            case _: String => true
            case _ => false
        }
    }

    public func setMapper(m: (QueryResult, HashMap<String, Int64>) -> T): Unit {
        this.mapper = Some(m)
    }

    public func setKeyExtractor(k: (QueryResult, HashMap<String, Int64>) -> String): Unit {
        this.keyExtractor = Some(k)
    }

    // Task 4: 主实体主键原始值提取器（宏层 XxxRawIdFromResult 生成，随 query() 挂载）。
    public func setRawIdExtractor(r: (QueryResult, HashMap<String, Int64>) -> Any): Unit {
        this.rawIdExtractor = Some(r)
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

    private func aggregateInt(fn: String, col: Col<Int64>): Int64 {
        aggregate(fn, col.name, 0, { r, o => r.getOrNull<Int64>(0 + o) })
    }

    private func aggregateFloat(fn: String, col: Col<Int64>): Float64 {
        aggregate(fn, col.name, 0.0, { r, o => r.getOrNull<Float64>(0 + o) })
    }

    private func aggregateFloat(fn: String, col: Col<Float64>): Float64 {
        aggregate(fn, col.name, 0.0, { r, o => r.getOrNull<Float64>(0 + o) })
    }

    private func aggregate<R>(fn: String, colName: String, zero: R, read: (QueryResult, Int64) -> ?R): R {
        let exec = requireExecutor()
        try {
            let aggStmt = Statement()
            aggStmt.addClause(SelectClause([Raw(fn + "(" + colName + ")")]))
            copyDataClauses(stmt, aggStmt)
            let dialect = getDialect()
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

    private func requireExecutor(): ExecutionContext {
        match (this.executor) {
            case Some(e) => e
            case None => throw QueryException(
                "No execution context set. Call using(session) or using(tx) before executing the query."
            )
        }
    }

    public func getDialect(): Dialect {
        match (this.queryDialect) {
            case Some(d) => d
            case None => SQLiteDialect()
        }
    }

    private func closeExecutor(exec: ExecutionContext): Unit {
        match (exec) {
            case s: Session => s.close()
            case _ => ()
        }
    }

    private func runAfterFindHooks(entity: T): Unit {
        if (typeName != "") {
            match (this.ref) {
                case Some(rf) =>
                    let s = Scope<T>(entity)
                    let err = rf.executeHooks(typeName, HookKind.AfterFind, s)
                    match (err) {
                        case Some(e) => throw e
                        case None => ()
                    }
                case None => ()   // 裸 Query 无 Refine 绑定，不触发 AfterFind
            }
        }
    }

    // 主查询映射循环：逐行 mapper + AfterFind hook + 收集 rawId（集合 include 需要主实体主键），
    // 返回 (entities, rawIds) 两个按索引对齐的数组；无集合 include 时 rawIds 为空。
    private func mapMainResult(
        result: QueryResult,
        columnMap: HashMap<String, Int64>,
        mapper: (QueryResult, HashMap<String, Int64>) -> T
    ): (Array<T>, Array<Any>) {
        let collectIds = needsCollectionAssembly()
        var list = ArrayList<T>()
        var rawIds = ArrayList<Any>()
        while (result.next()) {
            let entity = mapper(result, columnMap)
            runAfterFindHooks(entity)
            list.add(entity)
            if (collectIds) { rawIds.add(collectRawId(result, columnMap)) }
        }
        (list.toArray(), rawIds.toArray())
    }

    // Task 6: 嵌套 include 递归深度上限。正常 include 链（withInclude 链式构建）受
    // clone-on-write 约束天然无环且深度有限，但深度守卫是防御性保障：用户自定义 IRelation
    // 实现（getNested 自引用形成环）或未来 API 演化可能产生无限递归，深度超过该值即抛
    // QueryException 终止（避免栈溢出 / 死循环）。16 层足够覆盖任何实际嵌套场景。
    private let MaxNestedDepth: Int64 = 16

    // 批量装配调度：统一递归引擎入口（Task 6 起 ref_to / has_one / has_many / ref_many
    // 与嵌套 include 共用同一条递归路径，见 assembleRecursive）。顶层 rels = included，
    // depth = 0；rawIds 与 entities 按索引对齐，仅在 needsCollectionAssembly() 时有意义。
    private func assembleIncludes(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<T>,
        rawIds: Array<Any>
    ): Unit {
        assembleRecursive(exec, dialect, entities, included.toArray(), rawIds, 0)
    }

    // Task 6: 嵌套 include 统一装配引擎（递归）。对 entities（E 泛型：顶层为 Array<T>
    // 主实体、嵌套层为 Array<Any> 上一层装配结果）装配 rels 中声明的关联，并递归装配
    // 各关联目标实体的嵌套 include（rel.getNested()）。按 kind 分派三条协议：
    //   ref_to 组 → 读实体 fk（getForeignKeyExtractor）→ `WHERE 目标."id" IN (fk 集合)`
    //   has_one/has_many 组 → 读实体原始主键（mainIds，与 entities 按索引对齐）
    //     → `WHERE 目标."fk" IN (主键集合)`
    //   ref_many 组 → junction 中间表批量查询
    // 三条协议各返回 (relation, 该关系装配到的目标实体数组)；对每条声明了嵌套的关系，
    // 用父关系 getTargetIdExtractor 读目标实体主键作为下一层 mainIds，递归下一层。
    // 深度超过 MaxNestedDepth 抛 QueryException（含 include 环时终止递归）。
    private func assembleRecursive<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rels: Array<IRelation>,
        mainIds: Array<Any>,
        depth: Int64
    ): Unit {
        if (depth > MaxNestedDepth) {
            throw QueryException("nested include exceeds max depth " + MaxNestedDepth.toString() +
                "; check for include cycles")
        }
        if (rels.size == 0 || entities.size == 0) { return }

        // 1. 按 kind 分组（保持各组内 rels 顺序；ref_to → 集合 → ref_many 三条协议依次执行）
        var refToRels = ArrayList<IRelation>()
        var collRels = ArrayList<IRelation>()
        var refManyRels = ArrayList<IRelation>()
        for (rel in rels) {
            let (kind, _, _, _, _, _) = rel.resolve()
            match (kind) {
                case RelationKind.RefToRel => refToRels.add(rel)
                case RelationKind.RefManyRel => refManyRels.add(rel)
                case RelationKind.HasOneRel | RelationKind.HasManyRel => collRels.add(rel)
            }
        }

        // 2. 三条协议依次装配，收集各关系装配到的目标实体
        var pairs = ArrayList<(IRelation, Array<Any>)>()
        let refToPairs = assembleRefTo(exec, dialect, entities, refToRels.toArray())
        for (p in refToPairs) { pairs.add(p) }
        if (collRels.size > 0 || refManyRels.size > 0) {
            let collPairs = assembleCollections(exec, dialect, entities, mainIds, collRels.toArray())
            for (p in collPairs) { pairs.add(p) }
            let refManyPairs = assembleRefMany(exec, dialect, entities, mainIds, refManyRels.toArray())
            for (p in refManyPairs) { pairs.add(p) }
        }

        // 3. 递归装配各关系的嵌套 include（目标实体为空时下一层早退，不产生额外查询）
        for ((rel, targets) in pairs) {
            let nested = rel.getNested()
            if (nested.size == 0) { continue }
            let targetIds = collectTargetIds(rel, targets)
            assembleRecursive(exec, dialect, targets, nested, targetIds, depth + 1)
        }
    }

    // 递归层的 mainIds：用父关系 getTargetIdExtractor 逐目标读取主键，与 targets 按索引对齐。
    private func collectTargetIds(rel: IRelation, targets: Array<Any>): Array<Any> {
        let extractor = rel.getTargetIdExtractor()
        var ids = ArrayList<Any>()
        for (t in targets) { ids.add(extractor(t)) }
        ids.toArray()
    }

    // 是否有需要批量装配的集合 include（has_one / has_many / ref_many）。
    // ref_many 走 junction 中间表（Task 5 接入，与 has 系共用主实体原始主键 rawIds），
    // 故同样判定为需要收集 rawIds（旧 JOIN 路径的 hasCollectionInclude 已删除）。
    private func needsCollectionAssembly(): Bool {
        for (inc in included) {
            let (kind, _, _, _, _, _) = inc.resolve()
            if (kind == RelationKind.HasManyRel || kind == RelationKind.HasOneRel ||
                kind == RelationKind.RefManyRel) {
                return true
            }
        }
        false
    }

    // 集合 include 装配前置守卫：批量 has_many/has_one/ref_many 需要主实体单列主键的
    // 原始值（rawIdExtractor，宏层随 query() 挂载）。复合主键主实体或手工构造的 Query
    // 未挂载时，主查询执行前就抛带说明的 QueryException（计划 D6 限制），避免发无意义的主查询。
    private func requireCollectionIdSupport(): Unit {
        if (!needsCollectionAssembly()) { return }
        match (this.rawIdExtractor) {
            case Some(_) => ()
            case None => throw QueryException(
                "batch collection include (has_many/has_one/ref_many) requires a single-column primary key" +
                " on the main entity (type=" + typeName + "); composite primary key / missing raw id extractor" +
                " not supported"
            )
        }
    }

    // 主查询映射循环内逐行收集主实体主键原始值（与实体列表按索引对齐）。前置守卫保证
    // needsCollectionAssembly() 为 true 时 rawIdExtractor 必然已挂载。
    private func collectRawId(result: QueryResult, columnMap: HashMap<String, Int64>): Any {
        this.rawIdExtractor.getOrThrow()(result, columnMap)
    }

    // Task 4: has_one/has_many 批量装配。主查询返回实体后调用：
    //   1. 按 (目标表, fk) 分组（has_one 与 has_many 共享同一 fk 可合并一条批量查询）；
    //   2. 收集主实体主键原始值（rawIds，与 entities 按索引对齐），去重并过滤 0/""；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT <目标主键 + fk + 字段并集> FROM <目标表> WHERE <fk> IN (?, ...)` 批量取目标，
    //      fk 列不在字段子集里也必须强制选中（分组键）；
    //   5. 按 fk 值分组建 HashMap<FK, Array<TargetEntity>>；
    //   6. 回填：主实体按各自主键命中分组，has_many 逐个 add、has_one 取组内第一条。
    //      fk 不匹配任何主实体（脏数据/查询边界）的组不会被装配，主实体不受影响。
    // Task 6 扩展：返回各关系实际装配到的目标实体数组（has_many 取组内全部、has_one 取
    // 每条已装配实体的 ts[0]），供嵌套 include 递归装配下一层关联。rawIds 顶层来自
    // rawIdExtractor（主查询映射循环收集）、嵌套层来自父关系的 getTargetIdExtractor。
    private func assembleCollections<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rawIds: Array<Any>,
        rels: Array<IRelation>
    ): ArrayList<(IRelation, Array<Any>)> {
        let result = ArrayList<(IRelation, Array<Any>)>()
        if (rels.size == 0 || entities.size == 0) { return result }
        if (rawIds.size != entities.size) {
            throw QueryException("internal error: rawId collection size mismatch in assembleCollections")
        }

        // 1. 按 (目标表, fk) 分组 has_one/has_many 关系
        var groups = ArrayList<(String, String, ArrayList<IRelation>)>()
        for (inc in rels) {
            let (kind, _, targetTable, fk, _, _) = inc.resolve()
            if (kind != RelationKind.HasManyRel && kind != RelationKind.HasOneRel) { continue }
            var found = false
            for (i in 0..groups.size) {
                if (groups[i][0] == targetTable && groups[i][1] == fk) {
                    groups[i][2].add(inc)
                    found = true
                    break
                }
            }
            if (!found) {
                let rels2 = ArrayList<IRelation>()
                rels2.add(inc)
                groups.add((targetTable, fk, rels2))
            }
        }
        if (groups.size == 0) { return result }

        // 2. 收集主实体 id（去重、过滤 0/"" 未设置值）
        var ids = ArrayList<Any>()
        var seen = HashMap<String, Bool>()
        for (id in rawIds) {
            if (isEmptyFk(id)) { continue }
            let key = fkKey(id)
            if (!seen.contains(key)) {
                seen[key] = true
                ids.add(id)
            }
        }
        if (ids.size == 0) { return result }

        for (i in 0..groups.size) {
            let targetTable = groups[i][0]
            let fk = groups[i][1]
            let rels2 = groups[i][2]

            // 3. 字段并集 + 强制目标主键 id + 强制 fk 分组键（fk 不在字段子集里也必须选中）
            let cols = buildBatchSelectCols(rels2, ["id", fk])

            // 4. 批量查询：SELECT <cols> FROM <table> WHERE <fk> IN (?, ...)
            let (inSQL, inParams) = buildInClause(dialect, fk, ids.toArray())
            let result2 = execBatchQuery(exec, dialect, targetTable, cols, inSQL, inParams)

            // 5. 按 fk 值分组成目标实体列表（fk 类型跟随主实体主键：Int64 或 String）。
            //    可空 fk 的脏行（驱动返回 NULL）用 getOrNull 判空跳过，不抛异常（旧 isNullId 防御）。
            let columnMap = buildColumnMap(result2.columnInfos, exec.getParamOffset())
            let fkIdx = columnMap.get(fk).getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels2[0].getTargetMapper()
            var groupMap = HashMap<String, ArrayList<Any>>()
            while (result2.next()) {
                let keyOpt: Option<String> = if (isStringPk) {
                    match (result2.getOrNull<String>(fkIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                } else {
                    match (result2.getOrNull<Int64>(fkIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                }
                match (keyOpt) {
                    case Some(key) =>
                        var group = match (groupMap.get(key)) {
                            case Some(g) => g
                            case None =>
                                let ng = ArrayList<Any>()
                                groupMap[key] = ng
                                ng
                        }
                        group.add(targetMapper(result2, columnMap))
                    case None => ()
                }
            }

            // 6. 回填：has_many 逐目标 add；has_one 取组内第一条（重复 fk 时取先读到的行）。
            //    同时收集该关系装配到的目标实体（has_many 取组内全部、has_one 取 ts[0]）。
            for (rel in rels2) {
                let (kind, _, _, _, _, _) = rel.resolve()
                let setter = rel.getFieldSetter()
                var targets = ArrayList<Any>()
                for (ei in 0..entities.size) {
                    let rawId = rawIds[ei]
                    if (isEmptyFk(rawId)) { continue }
                    let key = fkKey(rawId)
                    match (groupMap.get(key)) {
                        case Some(ts) =>
                            if (kind == RelationKind.HasManyRel) {
                                for (t in ts) { setter(entities[ei], t); targets.add(t) }
                            } else {
                                setter(entities[ei], ts[0])
                                targets.add(ts[0])
                            }
                        case None => ()
                    }
                }
                result.add((rel, targets.toArray()))
            }
        }
        result
    }

    // Task 5: ref_many 批量装配（多对多，经 junction 中间表）。主查询返回实体后调用：
    //   1. 按 (via 中间表, 目标表) 分组，同组多个 ref_many 关系合并为一条批量查询；
    //   2. 复用主实体主键原始值（rawIds，与 entities 按索引对齐），去重并过滤 0/""；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT 目标表."id", 目标表.<字段...>, 中间表."<源表>_id" FROM 中间表 JOIN 目标表
    //      ON 中间表."<目标类>_id" = 目标表."id" WHERE 中间表."<源表>_id" IN (?, ...)` 批量取
    //      关联目标，目标列不带表限定（targetMapper 按列名读，中间表 schema 只有两列无同名列可裸读），
    //      中间表源 id 列强制选中（分组键）。反向同名情形：若目标实体恰好有名为
    //      `<源表>_id` 的字段，SELECT 中该目标列先于中间表源 id 列出现，buildColumnMap 对同名
    //      键「后写覆盖」（std HashMap.add 语义），分组键 srcCol 取到最后写入的中间表列索引、
    //      仍正确，但该假设的目标字段会错读到中间表源 id 值（target 表出现 `<源表>_id` 字段极罕见）；
    //   5. 按中间表源 id 值分组建 HashMap<srcId, Array<TargetEntity>>；
    //   6. 回填：主实体按各自主键命中分组，逐个 add。孤儿行（中间表行指向已删目标）
    //      由 INNER JOIN 天然排除，不装配、不抛错。
    // Task 6 扩展：返回各关系实际装配到的目标实体数组（逐目标 add 时收集），
    // 供嵌套 include 递归装配下一层关联。
    // 中间表列名与 buildJunctionSchema / relation_gen.cj 一致：
    //   源列 = <源表名>_id（源表名取主查询 FROM，getSourceTable），
    //   目标列 = lowerTableName(目标类) + "_id"（由宏层随 RefMany 构造传入，
    //            @Table 覆盖目标表名时目标列名仍基于类名，见 getJunctionTargetCol）。
    // SQL 手写（quoteIdentifier + 占位符，对齐 relation_gen.cj 的 ref_many 单行查询风格）：
    // junction JOIN 语义必须是 INNER JOIN（孤儿行跳过），而 Statement/方言渲染只支持
    // LEFT JOIN 且 FromClause 无别名，无法表达该 JOIN；IN 列带表限定也超出 buildInClause。
    private func assembleRefMany<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rawIds: Array<Any>,
        rels: Array<IRelation>
    ): ArrayList<(IRelation, Array<Any>)> {
        let result = ArrayList<(IRelation, Array<Any>)>()
        if (rels.size == 0 || entities.size == 0) { return result }
        if (rawIds.size != entities.size) {
            throw QueryException("internal error: rawId collection size mismatch in assembleRefMany")
        }
        let sourceTable = getSourceTable()
        // 手写 Query 未设 FROM 却 include 了 ref_many 是用户错误：junction 源列
        // `<源表>_id` 无从推导，静默跳过会留下未装配的空关联列表，故 fail-fast
        // （风格同 requireCollectionIdSupport）。
        if (sourceTable == "") {
            throw QueryException(
                "ref_many include requires a source table. Call from() before executing the query."
            )
        }

        // 1. 按 (via 中间表, 目标表) 分组。分组键不含关系名/源表：若两个不同类 @Table
        //    映射到同一表且声明同一 via（极罕见），会误合并为一条批量查询——视为已知限制。
        var groups = ArrayList<(String, String, ArrayList<IRelation>)>()
        for (inc in rels) {
            let (kind, _, targetTable, _, via, _) = inc.resolve()
            if (kind != RelationKind.RefManyRel) { continue }
            let viaTable = via.getOrThrow()
            var found = false
            for (i in 0..groups.size) {
                if (groups[i][0] == viaTable && groups[i][1] == targetTable) {
                    groups[i][2].add(inc)
                    found = true
                    break
                }
            }
            if (!found) {
                let rels2 = ArrayList<IRelation>()
                rels2.add(inc)
                groups.add((viaTable, targetTable, rels2))
            }
        }
        if (groups.size == 0) { return result }

        // 2. 收集主实体 id（去重、过滤 0/"" 未设置值），同 assembleCollections
        var ids = ArrayList<Any>()
        var seen = HashMap<String, Bool>()
        for (id in rawIds) {
            if (isEmptyFk(id)) { continue }
            let key = fkKey(id)
            if (!seen.contains(key)) {
                seen[key] = true
                ids.add(id)
            }
        }
        if (ids.size == 0) { return result }

        let srcCol = sourceTable + "_id"

        for (i in 0..groups.size) {
            let viaTable = groups[i][0]
            let targetTable = groups[i][1]
            let rels2 = groups[i][2]

            // 3. 目标字段并集 + 强制目标主键 id；另强制中间表源 id 列（分组键）
            let cols = buildBatchSelectCols(rels2, ["id"])
            let tgtCol = rels2[0].getJunctionTargetCol()
            if (tgtCol == "") {
                throw QueryException("ref_many relation '" + rels2[0].resolve()[1] +
                    "' has empty junction target column; RefMany requires junctionTargetCol")
            }

            // 4. 手写 junction 批量查询（INNER JOIN 语义见方法注释）
            var selectParts = ArrayList<String>()
            for (c in cols) {
                match (c) {
                    case Expr.Column(name) =>
                        selectParts.add(dialect.quoteIdentifier(targetTable) + "." + dialect.quoteIdentifier(name))
                    case _ => throw QueryException("internal error: batch select contains non-column expr")
                }
            }
            selectParts.add(dialect.quoteIdentifier(viaTable) + "." + dialect.quoteIdentifier(srcCol))
            let srcColSQL = dialect.quoteIdentifier(viaTable) + "." + dialect.quoteIdentifier(srcCol)
            let (inSQL, inParams) = buildInClauseCol(srcColSQL, ids.toArray())
            let sql = "SELECT " + String.join(selectParts.toArray(), delimiter: ", ") +
                " FROM " + dialect.quoteIdentifier(viaTable) +
                " JOIN " + dialect.quoteIdentifier(targetTable) +
                " ON " + dialect.quoteIdentifier(viaTable) + "." + dialect.quoteIdentifier(tgtCol) +
                " = " + dialect.quoteIdentifier(targetTable) + "." + dialect.quoteIdentifier("id") +
                " WHERE " + inSQL
            Logger.logSQL(sql, inParams)
            let result2 = exec.query(sql, inParams)

            // 5. 按中间表源 id 值分组成目标实体列表（源 id 类型跟随主实体主键：Int64 或 String）。
            //    INNER JOIN 已排除孤儿行；中间表源 id 列非空，getOrNull 仅防御。
            let columnMap = buildColumnMap(result2.columnInfos, exec.getParamOffset())
            let srcIdx = columnMap.get(srcCol).getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels2[0].getTargetMapper()
            var groupMap = HashMap<String, ArrayList<Any>>()
            while (result2.next()) {
                let keyOpt: Option<String> = if (isStringPk) {
                    match (result2.getOrNull<String>(srcIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                } else {
                    match (result2.getOrNull<Int64>(srcIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                }
                match (keyOpt) {
                    case Some(key) =>
                        var group = match (groupMap.get(key)) {
                            case Some(g) => g
                            case None =>
                                let ng = ArrayList<Any>()
                                groupMap[key] = ng
                                ng
                        }
                        group.add(targetMapper(result2, columnMap))
                    case None => ()
                }
            }

            // 6. 回填：逐目标 add；同时收集该关系装配到的目标实体
            for (rel in rels2) {
                let setter = rel.getFieldSetter()
                var targets = ArrayList<Any>()
                for (ei in 0..entities.size) {
                    let rawId = rawIds[ei]
                    if (isEmptyFk(rawId)) { continue }
                    let key = fkKey(rawId)
                    match (groupMap.get(key)) {
                        case Some(ts) =>
                            for (t in ts) { setter(entities[ei], t); targets.add(t) }
                        case None => ()
                    }
                }
                result.add((rel, targets.toArray()))
            }
        }
        result
    }
}
