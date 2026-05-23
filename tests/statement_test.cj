package refine

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class StatementTest {
    @TestCase
    public func testSelectClauseConstruction(): Unit {
        let clause = Clause.SelectClause([Expr.Column("id")])
        match (clause) {
            case Clause.SelectClause(cols) =>
                @Expect(cols.size, 1)
                match (cols[0]) {
                    case Expr.Column(n) => @Expect(n, "id")
                    case _ => @Fail("expected Column")
                }
            case _ => @Fail("expected SelectClause")
        }
    }

    @TestCase
    public func testFromClauseConstruction(): Unit {
        let clause = Clause.FromClause("users")
        match (clause) {
            case Clause.FromClause(t) => @Expect(t, "users")
            case _ => @Fail("expected FromClause")
        }
    }

    @TestCase
    public func testWhereClauseConstruction(): Unit {
        let clause = Clause.WhereClause([Expr.Binary(Expr.Column("age"), BinOp.Gt, Expr.Value(18))])
        match (clause) {
            case Clause.WhereClause(predicates) =>
                @Expect(predicates.size, 1)
                match (predicates[0]) {
                    case Expr.Binary(left, op, right) => @Expect(op, BinOp.Gt)
                    case _ => @Fail("expected Binary")
                }
            case _ => @Fail("expected WhereClause")
        }
    }

    @TestCase
    public func testGroupByClauseConstruction(): Unit {
        let clause = Clause.GroupByClause([Expr.Column("dept")])
        match (clause) {
            case Clause.GroupByClause(cols) =>
                @Expect(cols.size, 1)
                match (cols[0]) {
                    case Expr.Column(n) => @Expect(n, "dept")
                    case _ => @Fail("expected Column")
                }
            case _ => @Fail("expected GroupByClause")
        }
    }

    @TestCase
    public func testHavingClauseConstruction(): Unit {
        let clause = Clause.HavingClause([Expr.Binary(Expr.Column("count"), BinOp.Gt, Expr.Value(10))])
        match (clause) {
            case Clause.HavingClause(predicates) =>
                @Expect(predicates.size, 1)
            case _ => @Fail("expected HavingClause")
        }
    }

    @TestCase
    public func testOrderByClauseConstruction(): Unit {
        let clause = Clause.OrderByClause([Expr.Column("name")])
        match (clause) {
            case Clause.OrderByClause(cols) =>
                @Expect(cols.size, 1)
                match (cols[0]) {
                    case Expr.Column(n) => @Expect(n, "name")
                    case _ => @Fail("expected Column")
                }
            case _ => @Fail("expected OrderByClause")
        }
    }

    @TestCase
    public func testLimitClauseConstruction(): Unit {
        let clause = Clause.LimitClause(10)
        match (clause) {
            case Clause.LimitClause(n) => @Expect(n, 10)
            case _ => @Fail("expected LimitClause")
        }
    }

    @TestCase
    public func testOffsetClauseConstruction(): Unit {
        let clause = Clause.OffsetClause(100)
        match (clause) {
            case Clause.OffsetClause(n) => @Expect(n, 100)
            case _ => @Fail("expected OffsetClause")
        }
    }

    @TestCase
    public func testJoinClauseConstruction(): Unit {
        let clause = Clause.JoinClause("orders", "o", Expr.Binary(Expr.Column("u.id"), BinOp.Eq, Expr.Column("o.user_id")))
        match (clause) {
            case Clause.JoinClause(table, alias, onExpr) =>
                @Expect(table, "orders")
                @Expect(alias, "o")
                match (onExpr) {
                    case Expr.Binary(l, op, r) => @Expect(op, BinOp.Eq)
                    case _ => @Fail("expected Binary")
                }
            case _ => @Fail("expected JoinClause")
        }
    }

    @TestCase
    public func testDefaultStatementEmpty(): Unit {
        let stmt = Statement()
        @Expect(stmt.clauses.size, 0)
    }

    @TestCase
    public func testAddSingleClause(): Unit {
        let stmt = Statement()
        stmt.addClause(Clause.SelectClause([Expr.Column("id")]))
        @Expect(stmt.clauses.size, 1)
    }

    @TestCase
    public func testAddMultipleClausesOrder(): Unit {
        let stmt = Statement()
        stmt.addClause(Clause.SelectClause([Expr.Column("name")]))
        stmt.addClause(Clause.FromClause("users"))
        stmt.addClause(Clause.WhereClause([Expr.Column("active")]))

        @Expect(stmt.clauses.size, 3)
        match (stmt.clauses[0]) {
            case Clause.SelectClause(_) => ()
            case _ => @Fail("expected first clause to be SelectClause")
        }
        match (stmt.clauses[1]) {
            case Clause.FromClause(t) => @Expect(t, "users")
            case _ => @Fail("expected second clause to be FromClause")
        }
        match (stmt.clauses[2]) {
            case Clause.WhereClause(_) => ()
            case _ => @Fail("expected third clause to be WhereClause")
        }
    }

    @TestCase
    public func testIterateClauses(): Unit {
        let stmt = Statement()
        stmt.addClause(Clause.SelectClause([Expr.Column("a")]))
        stmt.addClause(Clause.FromClause("t"))

        var count = 0
        for (clause in stmt.clauses) {
            count += 1
        }
        @Expect(count, 2)
    }

    @TestCase
    public func testBuildSelectStatement(): Unit {
        let stmt = Statement()
        stmt.addClause(Clause.SelectClause([Expr.Column("id"), Expr.Column("name")]))
        stmt.addClause(Clause.FromClause("users"))
        stmt.addClause(Clause.WhereClause([Expr.Binary(Expr.Column("age"), BinOp.Gt, Expr.Value(18))]))
        stmt.addClause(Clause.OrderByClause([Expr.Column("name")]))
        stmt.addClause(Clause.LimitClause(10))

        @Expect(stmt.clauses.size, 5)
    }
}
