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

    public func addJoinClause(table: String, alias: String, on: Expr): Unit {
        for (i in 0..clauses.size) {
            match (clauses[i]) {
                case Clause.WhereClause(_) | Clause.GroupByClause(_) | Clause.HavingClause(_) |
                     Clause.OrderByClause(_) | Clause.LimitClause(_) | Clause.OffsetClause(_) =>
                    clauses.add(Clause.JoinClause(table, alias, on), at: i)
                    return
                case _ => ()
            }
        }
        clauses.add(Clause.JoinClause(table, alias, on))
    }
}
