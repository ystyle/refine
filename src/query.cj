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
            // Task 2 后主查询不再含 include JOIN：LIMIT/OFFSET 作用于源表行，无展开放大，
            // 单页恰好返回 size 个主实体（旧 LEFT JOIN 方案的父子跨页拆分/页内去重局限已消除）。
            // ref_to 装配由 Task 3 批量分步查询完成；集合 include（has_many/ref_many）在 Task 4 接入。
            let columnMap = buildColumnMap(result.columnInfos, columnOffset)
            let mapper = this.mapper.getOrThrow()
            let entities: Array<T>
            if (hasCollectionInclude()) {
                entities = aggregateWithCollections(result, columnMap, mapper)
            } else {
                var list = ArrayList<T>()
                while (result.next()) {
                    let entity = mapper(result, columnMap)
                    runAfterFindHooks(entity)
                    list.add(entity)
                }
                entities = list.toArray()
            }
            assembleRefTo(exec, dialect, entities)
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
    // （ref_to 批量装配已在 Task 3 接入 all()/one()/page()，has_one/has_many/ref_many 在 Task 4-6 接入）。
    // batch 模式下无 JOIN 因此无列歧义，无需 qualify。此方法保留为 no-op，
    // 供 Task 3-6 在 all()/one()/page() 主查询之后挂接批量装配入口。
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
    // WHERE 的 IN 部分以 Raw + 末尾追加参数完成。
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

            // 2. 字段并集：同表多关系合并时取所有选中列
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

            // 3. 批量 SQL：SELECT <cols> FROM <table> WHERE "id" IN (?, ...)
            let bs = Statement()
            bs.addClause(Clause.SelectClause(cols.toArray()))
            bs.addClause(Clause.FromClause(targetTable))
            var placeholders = ArrayList<String>()
            for (_ in 0..ids.size) { placeholders.add("?") }
            let inSQL = dialect.quoteIdentifier("id") + " IN (" + String.join(placeholders.toArray(), delimiter: ", ") + ")"
            bs.addClause(Clause.WhereClause([Expr.Raw(inSQL)]))
            let (sql, baseParams) = dialect.render(bs)
            var params = ArrayList<Any>()
            for (p in baseParams) { params.add(p) }
            for (v in ids) { params.add(v) }
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
            let (sql, params) = dialect.render(stmt)
            Logger.logSQL(sql, params)
            let start = MonoTime.now()
            let result = exec.query(sql, params)
            let elapsed = MonoTime.now() - start
            Logger.logSlowQuery(sql, elapsed)
            let columnMap = buildColumnMap(result.columnInfos, columnOffset)
            let entities: Array<T>
            if (hasCollectionInclude()) {
                entities = aggregateWithCollections(result, columnMap, mapper)
            } else {
                var list = ArrayList<T>()
                while (result.next()) {
                    let entity = mapper(result, columnMap)
                    runAfterFindHooks(entity)
                    list.add(entity)
                }
                entities = list.toArray()
            }
            assembleRefTo(exec, dialect, entities)
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
            let hasCollection = hasCollectionInclude()
            let oneStmt = Statement()
            for (clause in stmt.clauses) {
                oneStmt.addClause(clause)
            }
            if (!hasCollection) {
                oneStmt.addClause(LimitClause(1))
            }
            let (sql, params) = dialect.render(oneStmt)
            Logger.logSQL(sql, params)
            let start = MonoTime.now()
            let result = exec.query(sql, params)
            let elapsed = MonoTime.now() - start
            Logger.logSlowQuery(sql, elapsed)
            let columnMap = buildColumnMap(result.columnInfos, columnOffset)
            var res: Option<T> = None
            if (hasCollection) {
                let all = aggregateWithCollections(result, columnMap, mapper)
                if (all.size > 0) { res = Some(all[0]) }
            } else {
                if (result.next()) {
                    let entity = mapper(result, columnMap)
                    runAfterFindHooks(entity)
                    res = Some(entity)
                }
            }
            match (res) {
                case Some(e) => assembleRefTo(exec, dialect, [e])
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
        let countStmt = Statement()
        // TODO(batch-include Task 4): 随批量装配实现删除——批量模式主查询无 JOIN，
        // COUNT(*) 天然正确，无需 COUNT(DISTINCT)。
        // 集合 include（has_many / ref_many）的 LEFT JOIN 会按子行展开，COUNT(*) 会放大 total。
        // 改为对源表主键去重计数，但仅支持单列 "id" 主键：复合主键 + 集合 include 时
        // COUNT(DISTINCT 单列) 结果不正确/未定义（all()/one() 同样受影响）。
        if (hasCollectionInclude()) {
            let sourceTable = getSourceTable()
            countStmt.addClause(SelectClause([Raw(
                "COUNT(DISTINCT " + dialect.quoteIdentifier(sourceTable) + "." + dialect.quoteIdentifier("id") + ")"
            )]))
        } else {
            countStmt.addClause(SelectClause([Raw("COUNT(*)")]))
        }
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

    // TODO(batch-include Task 4): 随批量装配实现删除
    private func hasCollectionInclude(): Bool {
        for (inc in included) {
            let (kind, _, _, _, _, _) = inc.resolve()
            if (kind == RelationKind.HasManyRel || kind == RelationKind.RefManyRel) {
                return true
            }
        }
        false
    }

    // TODO(batch-include Task 4): 随批量装配实现删除
    // I7: 用文档化 API getOrNull<T> 判空（SQL NULL → None），不再依赖驱动对 get<T>
    // 的异常边界行为（跨驱动未验证）。读作 String 对齐字符串主键目标；数字主键列驱动
    // 按字符串读出（现有 PG 集成测试已验证），此处只关心目标 id 是否为 NULL。
    private func isNullId(result: QueryResult, idx: Int64): Bool {
        match (result.getOrNull<String>(idx)) {
            case Some(_) => false
            case None => true
        }
    }

    // TODO(batch-include Task 4): 随批量装配实现删除
    private func aggregateWithCollections(
        result: QueryResult,
        columnMap: HashMap<String, Int64>,
        mapper: (QueryResult, HashMap<String, Int64>) -> T
    ): Array<T> {
        var map = HashMap<String, T>()
        // 单独维护插入序（首次出现该 id 时记录），保证返回顺序与 SQL 行序一致，
        // 不依赖 HashMap 迭代序（文档不保证顺序稳定）。
        var order = ArrayList<String>()
        var seen = HashMap<String, Bool>()
        let extractKey = this.keyExtractor.getOrThrow()
        while (result.next()) {
            let id = extractKey(result, columnMap)
            if (!map.contains(id)) {
                let entity = mapper(result, columnMap)
                runAfterFindHooks(entity)
                map[id] = entity
                order.add(id)
            }
            let entity = map.get(id).getOrThrow()
            for (inc in included) {
                let (kind, name, _, _, _, _) = inc.resolve()
                if (kind == RelationKind.HasManyRel || kind == RelationKind.RefManyRel) {
                    let prefix = name + "."
                    let idKey = prefix + "id"
                    let hasId = columnMap.contains(idKey)
                    if (hasId) {
                        let idx = columnMap.get(prefix + "id").getOrThrow()
                        if (isNullId(result, idx)) {
                        } else {
                            let stripped = stripPrefix(columnMap, prefix)
                            let targetId = result.get<String>(stripped.get("id").getOrThrow())
                            let seenKey = id + ":" + name + ":" + targetId
                            if (!seen.contains(seenKey)) {
                                seen[seenKey] = true
                                let target = inc.getTargetMapper()(result, stripped)
                                inc.getFieldSetter()(entity, target)
                            }
                        }
                    }
                }
            }
        }
        var entities = ArrayList<T>()
        for (id in order) {
            entities.add(map.get(id).getOrThrow())
        }
        entities.toArray()
    }
}

// TODO(batch-include Task 4): 随批量装配实现删除
func stripPrefix(
    cm: HashMap<String, Int64>,
    prefix: String
): HashMap<String, Int64> {
    var result = HashMap<String, Int64>()
    for ((key, value) in cm.toArray()) {
        if (key.startsWith(prefix)) {
            let stripped = key[prefix.size..]
            result[stripped] = value
        }
    }
    result
}
