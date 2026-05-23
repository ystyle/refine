package refine

import std.collection.ArrayList

public class Query<T> {
    var stmt: Statement
    var included: ArrayList<IRelation>
    var alias: String

    public init() {
        this.stmt = Statement()
        this.included = ArrayList<IRelation>()
        this.alias = ""
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
}
