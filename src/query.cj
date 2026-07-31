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

    public func include(rel: IRelation): Query<T> {
        included.add(rel)
        let (kind, _, _, _, _, _) = rel.resolve()
        if (kind != RelationKind.HasManyRel && kind != RelationKind.RefManyRel) {
            match (this.mapper) {
                case Some(m) =>
                    this.mapper = Some(wrapMapper(m, rel))
                case None => ()
            }
        }
        this
    }

    public func include(rel: IRelation, fields: Array<Col<Any>>): Query<T> {
        included.add(FieldOverrideRelation(rel, fields))
        this
    }

    public func using(exec: ExecutionContext): Query<T> {
        this.executor = exec
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

    public func processIncluded(dialect: Dialect): Unit {
        if (included.size == 0) { return }
        var sourceTable = ""
        for (clause in stmt.clauses) {
            match (clause) {
                case Clause.FromClause(t) => sourceTable = t
                case _ => ()
            }
        }
        if (sourceTable == "") { return }
        var aliasFields = ArrayList<Expr>()
        for (i in 0..included.size) {
            let rel = included[i]
            let (kind, name, table, fk, via, fields) = rel.resolve()
            let prefix = name + "."
            let srcRef = Raw(dialect.quoteIdentifier(sourceTable) + "." + dialect.quoteIdentifier(fk))
            let tgtRef = Raw(dialect.quoteIdentifier(name) + "." + dialect.quoteIdentifier("id"))
            let srcId = Raw(dialect.quoteIdentifier(sourceTable) + "." + dialect.quoteIdentifier("id"))
            let tgtFk = Raw(dialect.quoteIdentifier(name) + "." + dialect.quoteIdentifier(fk))
            match (kind) {
                case RelationKind.RefToRel =>
                    stmt.addJoinClause(table, name, Binary(srcRef, Eq, tgtRef))
                case RelationKind.HasOneRel =>
                    stmt.addJoinClause(table, name, Binary(srcId, Eq, tgtFk))
                case RelationKind.HasManyRel =>
                    stmt.addJoinClause(table, name, Binary(srcId, Eq, tgtFk))
                case RelationKind.RefManyRel =>
                    let junctionVia = via.getOrThrow()
                    let srcFk = sourceTable + "_id"
                    let tgtFk = table + "_id"
                    let junctionAlias = name + "_junction"
                    let join1On = Binary(srcId, Eq,
                        Raw(dialect.quoteIdentifier(junctionAlias) + "." + dialect.quoteIdentifier(srcFk)))
                    stmt.addJoinClause(junctionVia, junctionAlias, join1On)
                    let join2On = Binary(
                        Raw(dialect.quoteIdentifier(junctionAlias) + "." + dialect.quoteIdentifier(tgtFk)),
                        Eq, tgtRef)
                    stmt.addJoinClause(table, name, join2On)
            }
            for (j in 0..fields.size) {
                let col = fields[j]
                let colRef = Raw(dialect.quoteIdentifier(name) + "." + dialect.quoteIdentifier(col.name))
                aliasFields.add(Aliased(colRef, prefix + col.name))
            }
        }
        if (aliasFields.size > 0) {
            for (i in 0..stmt.clauses.size) {
                match (stmt.clauses[i]) {
                    case Clause.SelectClause(fields) =>
                        var combined = ArrayList<Expr>()
                        for (f in fields) {
                            match (f) {
                                case Expr.Column(colName) =>
                                    combined.add(Raw(dialect.quoteIdentifier(sourceTable) + "." + dialect.quoteIdentifier(colName)))
                                case _ =>
                                    combined.add(f)
                            }
                        }
                        for (a in aliasFields) { combined.add(a) }
                        stmt.clauses[i] = SelectClause(combined.toArray())
                    case _ => ()
                }
            }
            // qualify WHERE column refs with sourceTable to avoid ambiguity after JOIN
            for (i in 0..stmt.clauses.size) {
                match (stmt.clauses[i]) {
                    case Clause.WhereClause(predicates) =>
                        var qualified = ArrayList<Expr>()
                        for (p in predicates) { qualified.add(qualifyExpr(p, sourceTable, dialect)) }
                        stmt.clauses[i] = WhereClause(qualified.toArray())
                    case _ => ()
                }
            }
        }
    }

    private func wrapMapper(
        baseMapper: (QueryResult, HashMap<String, Int64>) -> T,
        rel: IRelation
    ): (QueryResult, HashMap<String, Int64>) -> T {
        let (kind, name, _, _, _, _) = rel.resolve()
        let targetMapper = rel.getTargetMapper()
        let setter = rel.getFieldSetter()

        func wrapper(result: QueryResult, columnMap: HashMap<String, Int64>): T {
            let entity = baseMapper(result, columnMap)
            let prefix = name + "."
            if (columnMap.contains(prefix + "id")) {
                if (!isNullId(result, columnMap.get(prefix + "id").getOrThrow())) {
                    let stripped = stripPrefix(columnMap, prefix)
                    let target = targetMapper(result, stripped)
                    setter(entity, target)
                }
            }
            entity
        }
        wrapper
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
        let dialect = getDialect()
        processIncluded(dialect)
        let (sql, params) = dialect.render(stmt)
        Logger.logSQL(sql, params)
        let start = MonoTime.now()
        let result = exec.query(sql, params)
        let elapsed = MonoTime.now() - start
        Logger.logSlowQuery(sql, elapsed)
        let columnMap = buildColumnMap(result.columnInfos, columnOffset)
        if (hasCollectionInclude()) {
            let r = aggregateWithCollections(result, columnMap, mapper)
            closeExecutor(exec)
            return r
        }
        var entities = ArrayList<T>()
        while (result.next()) {
            try {
                let entity = mapper(result, columnMap)
                if (typeName != "") {
                    let s = Scope<T>(entity)
                    match (this.ref) {
                        case Some(rf) => rf.executeHooks(typeName, HookKind.AfterFind, s)
                        case None => executeHooks(typeName, HookKind.AfterFind, s)
                    }
                }
                entities.add(entity)
            } catch (_: Exception) {
                ()
            }
        }
        closeExecutor(exec)
        entities.toArray()
    }

    public func one(): Option<T> {
        match (this.mapper) {
            case Some(m) => one(m)
            case None => throw QueryException("No auto-mapper. Use findOne() or one(mapper).")
        }
    }

    public func one(mapper: (QueryResult, HashMap<String, Int64>) -> T): Option<T> {
        let exec = requireExecutor()
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
        if (hasCollection) {
            let all = aggregateWithCollections(result, columnMap, mapper)
            closeExecutor(exec)
            if (all.size > 0) { return Some(all[0]) }
            return None
        }
        var res: Option<T> = None
        if (result.next()) {
            let entity = mapper(result, columnMap)
                if (typeName != "") {
                    let s = Scope<T>(entity)
                    match (this.ref) {
                        case Some(rf) => rf.executeHooks(typeName, HookKind.AfterFind, s)
                        case None => executeHooks(typeName, HookKind.AfterFind, s)
                    }
                }
            res = Some(entity)
        }
        closeExecutor(exec)
        res
    }

    public func count(): Int64 {
        let exec = requireExecutor()
        let countStmt = Statement()
        countStmt.addClause(SelectClause([Raw("COUNT(*)")]))
        for (clause in stmt.clauses) {
            match (clause) {
                case FromClause(_) => countStmt.addClause(clause)
                case WhereClause(_) => countStmt.addClause(clause)
                case JoinClause(_, _, _) => countStmt.addClause(clause)
                case _ => ()
            }
        }
        let dialect = getDialect()
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
        closeExecutor(exec)
        cnt
    }

    public func exists(): Bool {
        count() > 0
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

    private func hasCollectionInclude(): Bool {
        for (inc in included) {
            let (kind, name, _, _, _, _) = inc.resolve()
            if (kind == RelationKind.HasManyRel || kind == RelationKind.RefManyRel) {
                return true
            }
        }
        false
    }

    private func isNullId(result: QueryResult, idx: Int64): Bool {
        try {
            let _ = result.get<String>(idx)
            false
        } catch (_: Exception) {
            true
        }
    }

    private func aggregateWithCollections(
        result: QueryResult,
        columnMap: HashMap<String, Int64>,
        mapper: (QueryResult, HashMap<String, Int64>) -> T
    ): Array<T> {
        var map = HashMap<String, T>()
        var seen = HashMap<String, Bool>()
        let extractKey = this.keyExtractor.getOrThrow()
        while (result.next()) {
            let id = extractKey(result, columnMap)
            if (!map.contains(id)) {
                let entity = mapper(result, columnMap)
                if (typeName != "") {
                    let s = Scope<T>(entity)
                    match (this.ref) {
                        case Some(rf) => rf.executeHooks(typeName, HookKind.AfterFind, s)
                        case None => executeHooks(typeName, HookKind.AfterFind, s)
                    }
                }
                map[id] = entity
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
        for ((_, entity) in map.toArray()) {
            entities.add(entity)
        }
        entities.toArray()
    }
}

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

func qualifyExpr(expr: Expr, table: String, dialect: Dialect): Expr {
    match (expr) {
        case Expr.Column(name) => Raw(dialect.quoteIdentifier(table) + "." + dialect.quoteIdentifier(name))
        case Expr.Binary(l, op, r) => Binary(qualifyExpr(l, table, dialect), op, qualifyExpr(r, table, dialect))
        case Expr.Unary(op, e) => Unary(op, qualifyExpr(e, table, dialect))
        case Expr.Aliased(e, alias) => Aliased(qualifyExpr(e, table, dialect), alias)
        case Expr.Ordered(e, dir) => Ordered(qualifyExpr(e, table, dialect), dir)
        case _ => expr
    }
}
