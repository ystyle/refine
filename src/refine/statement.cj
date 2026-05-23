package refine

import std.collection.ArrayList

public enum Clause {
    | SelectClause(Array<Expr>)
    | FromClause(String)
    | WhereClause(Array<Expr>)
    | GroupByClause(Array<Expr>)
    | HavingClause(Array<Expr>)
    | OrderByClause(Array<Expr>)
    | LimitClause(Int64)
    | OffsetClause(Int64)
    | JoinClause(String, String, Expr)
}

public struct Statement {
    var clauses: ArrayList<Clause> = ArrayList<Clause>()

    public func addClause(clause: Clause): Unit {
        clauses.add(clause)
    }
}
