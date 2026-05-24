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

    public func `where`(predicates: Array<Expr>): Query<T> {
        stmt.addClause(WhereClause(predicates))
        this
    }

    public func `where`(predicate: Expr): Query<T> {
        stmt.addClause(WhereClause([predicate]))
        this
    }

    public func orderBy(fields: Array<Expr>): Query<T> {
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
        match (this.mapper) {
            case Some(m) =>
                this.mapper = Some(wrapMapper(m, rel))
            case None => ()
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
        this
    }

    private func processIncluded(dialect: Dialect): Unit {
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
                    stmt.addClause(JoinClause(table, name, Binary(srcRef, Eq, tgtRef)))
                case RelationKind.HasOneRel =>
                    stmt.addClause(JoinClause(table, name, Binary(srcId, Eq, tgtFk)))
                case RelationKind.HasManyRel =>
                    stmt.addClause(JoinClause(table, name, Binary(srcId, Eq, tgtFk)))
                case RelationKind.RefManyRel => ()
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
                        for (f in fields) { combined.add(f) }
                        for (a in aliasFields) { combined.add(a) }
                        stmt.clauses[i] = SelectClause(combined.toArray())
                        return
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
                let stripped = stripPrefix(columnMap, prefix)
                let target = targetMapper(result, stripped)
                setter(entity, target)
            }
            entity
        }
        wrapper
    }

    public func setMapper(m: (QueryResult, HashMap<String, Int64>) -> T): Unit {
        this.mapper = Some(m)
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
        var entities = ArrayList<T>()
        while (result.next()) {
            entities.add(mapper(result, columnMap))
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
        let oneStmt = Statement()
        for (clause in stmt.clauses) {
            oneStmt.addClause(clause)
        }
        oneStmt.addClause(LimitClause(1))
        let dialect = getDialect()
        processIncluded(dialect)
        let (sql, params) = dialect.render(oneStmt)
        Logger.logSQL(sql, params)
        let start = MonoTime.now()
        let result = exec.query(sql, params)
        let elapsed = MonoTime.now() - start
        Logger.logSlowQuery(sql, elapsed)
        let columnMap = buildColumnMap(result.columnInfos, columnOffset)
        var res: Option<T> = None
        if (result.next()) {
            res = Some(mapper(result, columnMap))
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

    private func getDialect(): Dialect {
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
