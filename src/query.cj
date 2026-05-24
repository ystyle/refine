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
                case FromClause(t) => sourceTable = t
                case _ => ()
            }
        }
        if (sourceTable == "") { return }
        var selectIdx: Int64 = -1
        for (i in 0..stmt.clauses.size) {
            match (stmt.clauses[i]) {
                case SelectClause(_) => selectIdx = i
                case _ => ()
            }
        }
        for (i in 0..included.size) {
            let rel = included[i]
            let (kind, name, table, fk, via, fields) = rel.resolve()
            let prefix = name + "."
            let srcRef = Raw(dialect.quoteIdentifier(sourceTable) + "." + dialect.quoteIdentifier(fk))
            let tgtRef = Raw(dialect.quoteIdentifier(table) + "." + dialect.quoteIdentifier("id"))
            let srcId = Raw(dialect.quoteIdentifier(sourceTable) + "." + dialect.quoteIdentifier("id"))
            let tgtFk = Raw(dialect.quoteIdentifier(table) + "." + dialect.quoteIdentifier(fk))
            match (kind) {
                case RelationKind.RefToRel =>
                    let onExpr = Binary(srcRef, Eq, tgtRef)
                    stmt.addClause(JoinClause(table, name, onExpr))
                case RelationKind.HasOneRel =>
                    let onExpr = Binary(srcId, Eq, tgtFk)
                    stmt.addClause(JoinClause(table, name, onExpr))
                case RelationKind.HasManyRel =>
                    let onExpr = Binary(srcId, Eq, tgtFk)
                    stmt.addClause(JoinClause(table, name, onExpr))
                case RelationKind.RefManyRel => ()
            }
            var aliasFields = ArrayList<Expr>()
            for (j in 0..fields.size) {
                let col = fields[j]
                let colRef = Raw(dialect.quoteIdentifier(table) + "." + dialect.quoteIdentifier(col.name))
                aliasFields.add(Aliased(colRef, prefix + col.name))
            }
            if (selectIdx >= 0) {
                match (stmt.clauses[selectIdx]) {
                    case SelectClause(existing) =>
                        var combined = ArrayList<Expr>()
                        for (e in existing) { combined.add(e) }
                        for (a in aliasFields) { combined.add(a) }
                        stmt.clauses[selectIdx] = SelectClause(combined.toArray())
                    case _ => ()
                }
            } else {
                stmt.addClause(SelectClause(aliasFields.toArray()))
                selectIdx = stmt.clauses.size - 1
            }
        }
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
        if (result.next()) {
            Some(mapper(result, columnMap))
        } else {
            None
        }
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
        if (result.next()) {
            result.get<Int64>(0 + columnOffset)
        } else {
            0
        }
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
}
