package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.time.MonoTime
import std.database.sql.QueryResult

public class Query<T> {
    var stmt: Statement
    var included: ArrayList<IRelation>
    var alias: String
    var executor: Option<ExecutionContext> = None
    var queryDialect: Option<Dialect> = None

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

    public func using(exec: ExecutionContext): Query<T> {
        this.executor = exec
        this
    }

    public func all(mapper: (QueryResult, HashMap<String, Int64>) -> T): Array<T> {
        let exec = requireExecutor()
        let dialect = getDialect()
        let (sql, params) = dialect.render(stmt)
        Logger.logSQL(sql, params)
        let start = MonoTime.now()
        let result = exec.query(sql, params)
        let elapsed = MonoTime.now() - start
        Logger.logSlowQuery(sql, elapsed)
        let columnMap = buildColumnMap(result.columnInfos)
        var entities = ArrayList<T>()
        while (result.next()) {
            entities.add(mapper(result, columnMap))
        }
        entities.toArray()
    }

    public func one(mapper: (QueryResult, HashMap<String, Int64>) -> T): Option<T> {
        let exec = requireExecutor()
        let oneStmt = Statement()
        for (clause in stmt.clauses) {
            oneStmt.addClause(clause)
        }
        oneStmt.addClause(LimitClause(1))
        let dialect = getDialect()
        let (sql, params) = dialect.render(oneStmt)
        Logger.logSQL(sql, params)
        let start = MonoTime.now()
        let result = exec.query(sql, params)
        let elapsed = MonoTime.now() - start
        Logger.logSlowQuery(sql, elapsed)
        let columnMap = buildColumnMap(result.columnInfos)
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
            result.get<Int64>(0)
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
