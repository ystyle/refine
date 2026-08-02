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

    public func withInclude(rel: IRelation): IRelation {
        FieldOverrideRelation(inner.withInclude(rel), overrides)
    }

    public func getNested(): Array<IRelation> {
        inner.getNested()
    }

    public func isBatchSupported(): Bool {
        inner.isBatchSupported()
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
            let mapper = this.mapper.getOrThrow()
            let collectIds = needsCollectionAssembly()
            var list = ArrayList<T>()
            var rawIds = ArrayList<Any>()
            while (result.next()) {
                let entity = mapper(result, columnMap)
                runAfterFindHooks(entity)
                list.add(entity)
                if (collectIds) { rawIds.add(collectRawId(result, columnMap)) }
            }
            let entities = list.toArray()
            // 批量装配在 AfterFind hook 之后执行（同 all()：hook 读关联字段为未装配状态）。
            assembleRefTo(exec, dialect, entities)
            if (collectIds) { assembleCollections(exec, dialect, entities, rawIds.toArray()) }
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

    private func runQuery(target: Statement): Array<T> {
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            let (sql, params) = dialect.render(target)
            Logger.logSQL(sql, params)
            let result = exec.query(sql, params)
            let columnMap = buildColumnMap(result.columnInfos, columnOffset)
            var entities = ArrayList<T>()
            while (result.next()) {
                let entity = this.mapper.getOrThrow()(result, columnMap)
                entities.add(entity)
            }
            entities.toArray()
        } finally {
            closeExecutor(exec)
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
    // 主查询只渲染源表自身（无 JOIN），include 预加载改由批量分步查询协议完成
    // （ref_to 批量装配 Task 3、has_one/has_many 批量装配 Task 4 已接入 all()/one()/page()，
    // ref_many 在 Task 5 接入）。此方法保留为 no-op 挂接入口。
    public func processIncluded(dialect: Dialect): Unit {
        ()
    }

    // Task 3: ref_to 批量装配。主查询返回实体后调用：
    //   1. 按目标表分组（保持 included 顺序），同表多个 ref_to 关系合并为一条批量查询；
    //   2. 收集各实体外键值（getForeignKeyExtractor），去重并过滤 0/"" 未设置值；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT <字段并集> FROM <目标表> WHERE "id" IN (?, ...)` 批量取目标；
    //   5. 目标 id → 实体 映射，按各关系 fk 值命中回填（未命中保持未挂载，不抛错）。
    // 批量 SQL 采用手写占位符（与 relation_gen.cj 一致）：IN 列表不是 Expr 模型的一部分
    // （Expr.Value 数组渲染为单个参数，无法展开为 ?,?,...），且在 scope 内不允许改动
    // 三方言 renderExpr 为 IN 列表新增变体，故 SELECT/FROM 走 Statement 机器，
    // WHERE 的 IN 部分由 buildInClause 手写占位符生成。
    private func assembleRefTo(exec: ExecutionContext, dialect: Dialect, entities: Array<T>): Unit {
        if (included.size == 0 || entities.size == 0) { return }

        var groups = ArrayList<(String, ArrayList<IRelation>)>()
        for (inc in included) {
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
                let rels = ArrayList<IRelation>()
                rels.add(inc)
                groups.add((targetTable, rels))
            }
        }

        for (i in 0..groups.size) {
            let targetTable = groups[i][0]
            let rels = groups[i][1]

            // 1. 收集该目标表全部 fk 值（跨关系去重、过滤 0/""）
            var ids = ArrayList<Any>()
            var seen = HashMap<String, Bool>()
            for (rel in rels) {
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

            // 2. 字段并集：同表多关系合并时取所有选中列。取舍：合并查询按「并集」SELECT，
            //    共享 identity-map 实体携带所有选中关系列的值——某关系只声明了子集列，
            //    但其目标实体仍带并集中其它关系选中的列（非该关系声明的子集），属预期行为。
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
            cols.add(Expr.Column("id"))   // 强制选中目标主键，装配查表与回填都用
            for (name in fieldNames) {
                if (name != "id") { cols.add(Expr.Column(name)) }
            }

            // 3. 批量 SQL：SELECT <cols> FROM <table> WHERE <col> IN (?, ...)
            let bs = Statement()
            bs.addClause(Clause.SelectClause(cols.toArray()))
            bs.addClause(Clause.FromClause(targetTable))
            let (inSQL, inParams) = buildInClause(dialect, "id", ids.toArray())
            bs.addClause(Clause.WhereClause([Expr.Raw(inSQL)]))
            let (sql, baseParams) = dialect.render(bs)
            var params = ArrayList<Any>()
            for (p in baseParams) { params.add(p) }
            for (v in inParams) { params.add(v) }
            Logger.logSQL(sql, params.toArray())
            let result = exec.query(sql, params.toArray())

            // 4. 目标 id → 实体 映射（同表关系共享同一目标 RowMapper）
            let columnMap = buildColumnMap(result.columnInfos, exec.getParamOffset())
            let idIdx = columnMap.get("id").getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels[0].getTargetMapper()
            var targetMap = HashMap<String, Any>()
            while (result.next()) {
                let idKey = if (isStringPk) {
                    result.get<String>(idIdx)
                } else {
                    result.get<Int64>(idIdx).toString()
                }
                targetMap[idKey] = targetMapper(result, columnMap)
            }

            // 5. 回填：fk 命中即挂载，未命中（目标被删）保持未挂载
            for (rel in rels) {
                let extractor = rel.getForeignKeyExtractor()
                let setter = rel.getFieldSetter()
                for (entity in entities) {
                    let v = extractor(entity)
                    if (isEmptyFk(v)) { continue }
                    let key = fkKey(v)
                    match (targetMap.get(key)) {
                        case Some(t) => setter(entity, t)
                        case None => ()
                    }
                }
            }
        }
    }

    // 构建 `col IN (?, ?...)` 子句。契约：返回的 (fragment, params) 必须一体追加——
    // 本 WHERE 子句内不能再有其它 Value 占位符（否则 render 收集的参数顺序会与占位符错位）。
    // 批量装配目前只有 IN 列表一个参数源，此契约在 Task 4/5 复用批量装配时同样成立。
    private func buildInClause(dialect: Dialect, col: String, ids: Array<Any>): (String, Array<Any>) {
        var placeholders = ArrayList<String>()
        for (_ in 0..ids.size) { placeholders.add("?") }
        let sql = dialect.quoteIdentifier(col) + " IN (" + String.join(placeholders.toArray(), delimiter: ", ") + ")"
        (sql, ids)
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
            let collectIds = needsCollectionAssembly()
            var list = ArrayList<T>()
            var rawIds = ArrayList<Any>()
            while (result.next()) {
                let entity = mapper(result, columnMap)
                runAfterFindHooks(entity)
                list.add(entity)
                if (collectIds) { rawIds.add(collectRawId(result, columnMap)) }
            }
            let entities = list.toArray()
            // 批量装配在 AfterFind hook 之后执行：主映射循环内先跑 runAfterFindHooks，
            // hook 内读取关联字段（如 entity.author）为未装配状态（None）——批量架构的固有取舍，
            // 旧 LEFT JOIN 方案在 hook 前已完成 ref_to 装配。
            assembleRefTo(exec, dialect, entities)
            if (collectIds) { assembleCollections(exec, dialect, entities, rawIds.toArray()) }
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
            let collectIds = needsCollectionAssembly()
            var res: Option<T> = None
            var rawIds = ArrayList<Any>()
            if (result.next()) {
                let entity = mapper(result, columnMap)
                runAfterFindHooks(entity)
                res = Some(entity)
                if (collectIds) { rawIds.add(collectRawId(result, columnMap)) }
            }
            // 批量装配在 AfterFind hook 之后执行（同 all()：hook 读关联字段为未装配状态）。
            match (res) {
                case Some(e) =>
                    assembleRefTo(exec, dialect, [e])
                    if (collectIds) { assembleCollections(exec, dialect, [e], rawIds.toArray()) }
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

    // 是否有需要批量装配的集合 include（has_one / has_many）。ref_many 走 junction
    // 中间表（Task 5 接入），此处不判定 RefManyRel（旧 JOIN 路径的 hasCollectionInclude 已删除）。
    private func needsCollectionAssembly(): Bool {
        for (inc in included) {
            let (kind, _, _, _, _, _) = inc.resolve()
            if (kind == RelationKind.HasManyRel || kind == RelationKind.HasOneRel) {
                return true
            }
        }
        false
    }

    // 集合 include 装配前置守卫：批量 has_many/has_one 需要主实体单列主键的原始值
    // （rawIdExtractor，宏层随 query() 挂载）。复合主键主实体或手工构造的 Query 未挂载
    // 时，主查询执行前就抛带说明的 QueryException（计划 D6 限制），避免发无意义的主查询。
    private func requireCollectionIdSupport(): Unit {
        if (!needsCollectionAssembly()) { return }
        match (this.rawIdExtractor) {
            case Some(_) => ()
            case None => throw QueryException(
                "batch has_many/has_one include requires a single-column primary key on the main entity" +
                " (type=" + typeName + "); composite primary key / missing raw id extractor not supported"
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
    //   2. 收集主实体主键原始值（rawIds，映射循环内已按实体对齐收集），去重并过滤 0/""；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT <目标主键 + fk + 字段并集> FROM <目标表> WHERE <fk> IN (?, ...)` 批量取目标，
    //      fk 列不在字段子集里也必须强制选中（分组键）；
    //   5. 按 fk 值分组建 HashMap<FK, Array<TargetEntity>>；
    //   6. 回填：主实体按各自主键命中分组，has_many 逐个 add、has_one 取组内第一条。
    //      fk 不匹配任何主实体（脏数据/查询边界）的组不会被装配，主实体不受影响。
    private func assembleCollections(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<T>,
        rawIds: Array<Any>
    ): Unit {
        if (included.size == 0 || entities.size == 0) { return }
        if (rawIds.size != entities.size) {
            throw QueryException("internal error: rawId collection size mismatch in assembleCollections")
        }

        // 1. 按 (目标表, fk) 分组 has_one/has_many 关系
        var groups = ArrayList<(String, String, ArrayList<IRelation>)>()
        for (inc in included) {
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
                let rels = ArrayList<IRelation>()
                rels.add(inc)
                groups.add((targetTable, fk, rels))
            }
        }
        if (groups.size == 0) { return }

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
        if (ids.size == 0) { return }

        for (i in 0..groups.size) {
            let targetTable = groups[i][0]
            let fk = groups[i][1]
            let rels = groups[i][2]

            // 3. 字段并集 + 强制目标主键 id + 强制 fk 分组键（fk 不在字段子集里也必须选中）
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
            cols.add(Expr.Column("id"))
            cols.add(Expr.Column(fk))
            for (name in fieldNames) {
                if (name != "id" && name != fk) { cols.add(Expr.Column(name)) }
            }

            // 4. 批量 SQL：SELECT <cols> FROM <table> WHERE <fk> IN (?, ...)
            let bs = Statement()
            bs.addClause(Clause.SelectClause(cols.toArray()))
            bs.addClause(Clause.FromClause(targetTable))
            let (inSQL, inParams) = buildInClause(dialect, fk, ids.toArray())
            bs.addClause(Clause.WhereClause([Expr.Raw(inSQL)]))
            let (sql, baseParams) = dialect.render(bs)
            var params = ArrayList<Any>()
            for (p in baseParams) { params.add(p) }
            for (v in inParams) { params.add(v) }
            Logger.logSQL(sql, params.toArray())
            let result = exec.query(sql, params.toArray())

            // 5. 按 fk 值分组成目标实体列表（fk 类型跟随主实体主键：Int64 或 String）
            let columnMap = buildColumnMap(result.columnInfos, exec.getParamOffset())
            let fkIdx = columnMap.get(fk).getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels[0].getTargetMapper()
            var groupMap = HashMap<String, ArrayList<Any>>()
            while (result.next()) {
                let key = if (isStringPk) {
                    fkKey(result.get<String>(fkIdx))
                } else {
                    fkKey(result.get<Int64>(fkIdx))
                }
                var group = match (groupMap.get(key)) {
                    case Some(g) => g
                    case None =>
                        let ng = ArrayList<Any>()
                        groupMap[key] = ng
                        ng
                }
                group.add(targetMapper(result, columnMap))
            }

            // 6. 回填：has_many 逐目标 add；has_one 取组内第一条（重复 fk 时取先读到的行）
            for (rel in rels) {
                let (kind, _, _, _, _, _) = rel.resolve()
                let setter = rel.getFieldSetter()
                for (ei in 0..entities.size) {
                    let rawId = rawIds[ei]
                    if (isEmptyFk(rawId)) { continue }
                    let key = fkKey(rawId)
                    match (groupMap.get(key)) {
                        case Some(ts) =>
                            if (kind == RelationKind.HasManyRel) {
                                for (t in ts) { setter(entities[ei], t) }
                            } else {
                                setter(entities[ei], ts[0])
                            }
                        case None => ()
                    }
                }
            }
        }
    }
}
