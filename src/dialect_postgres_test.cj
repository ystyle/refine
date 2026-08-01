package refine

import std.unittest.*
import std.unittest.testmacro.*

private func checkInt(v: Any, expected: Int64): Bool {
    match (v) {
        case i: Int64 => i == expected
        case _ => false
    }
}

private func checkStr(v: Any, expected: String): Bool {
    match (v) {
        case s: String => s == expected
        case _ => false
    }
}

@Test
public class PostgreSQLDialectTest {
    @TestCase
    public func testDialectName(): Unit {
        let dialect = PostgreSQLDialect()
        @Expect(dialect.name(), "postgresql")
    }

    @TestCase
    public func testQuoteIdentifier(): Unit {
        let dialect = PostgreSQLDialect()
        @Expect(dialect.quoteIdentifier("users"), "\"users\"")
        @Expect(dialect.quoteIdentifier("u.id"), "\"u.id\"")
        @Expect(dialect.quoteIdentifier("count"), "\"count\"")
    }

    @TestCase
    public func testRenderSelectStar(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([]))
        stmt.addClause(FromClause("users"))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT * FROM \"users\"")
        @Expect(params.size, 0)
    }

    @TestCase
    public func testRenderSelectWithWhere(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id"), Column("name")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(WhereClause([Binary(Column("age"), Gt, Value(18))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\", \"name\" FROM \"users\" WHERE \"age\" > $1")
        @Expect(params.size, 1)
        @Expect(checkInt(params[0], 18))
    }

    @TestCase
    public func testRenderMultipleParams(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(WhereClause([
            Binary(Column("name"), Eq, Value("Alice")),
            Binary(Column("age"), Gt, Value(18))
        ]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"users\" WHERE \"name\" = $1 AND \"age\" > $2")
        @Expect(params.size, 2)
        @Expect(checkStr(params[0], "Alice"))
        @Expect(checkInt(params[1], 18))
    }

    @TestCase
    public func testRenderOrderByLimit(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(OrderByClause([Column("name")]))
        stmt.addClause(LimitClause(10))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"users\" ORDER BY \"name\" LIMIT 10")
        @Expect(params.size, 0)
    }

    @TestCase
    public func testRenderGroupByHaving(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("dept"), FuncCall("COUNT", [Column("id")])]))
        stmt.addClause(FromClause("employees"))
        stmt.addClause(GroupByClause([Column("dept")]))
        stmt.addClause(HavingClause([Binary(FuncCall("COUNT", [Column("id")]), Gt, Value(5))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"dept\", COUNT(\"id\") FROM \"employees\" GROUP BY \"dept\" HAVING COUNT(\"id\") > $1")
        @Expect(params.size, 1)
        @Expect(checkInt(params[0], 5))
    }

    @TestCase
    public func testRenderJoin(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("u.id"), Column("u.name")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(JoinClause("orders", "o", Binary(Column("u.id"), Eq, Column("o.user_id"))))
        stmt.addClause(WhereClause([Binary(Column("u.age"), Gt, Value(18))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"u.id\", \"u.name\" FROM \"users\" LEFT JOIN \"orders\" \"o\" ON \"u.id\" = \"o.user_id\" WHERE \"u.age\" > $1")
        @Expect(params.size, 1)
        @Expect(checkInt(params[0], 18))
    }

    @TestCase
    public func testRenderAllClauseTypes(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([
            Binary(Column("a"), Eq, Value(1)),
            Binary(Column("b"), Gt, Value(2))
        ]))
        stmt.addClause(GroupByClause([Column("b")]))
        stmt.addClause(HavingClause([Binary(FuncCall("COUNT", [Column("c")]), Gt, Value(0))]))
        stmt.addClause(OrderByClause([Column("d")]))
        stmt.addClause(LimitClause(5))
        stmt.addClause(OffsetClause(10))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"t\" WHERE \"a\" = $1 AND \"b\" > $2 GROUP BY \"b\" HAVING COUNT(\"c\") > $3 ORDER BY \"d\" LIMIT 5 OFFSET 10")
        @Expect(params.size, 3)
        @Expect(checkInt(params[0], 1))
        @Expect(checkInt(params[1], 2))
        @Expect(checkInt(params[2], 0))
    }

    @TestCase
    public func testRenderBinOps(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("x")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Eq, Value(1))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"x\" FROM \"t\" WHERE \"a\" = $1")
    }

    @TestCase
    public func testRenderUnaryNot(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Unary(Not, Column("active"))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"t\" WHERE NOT \"active\"")
    }

    @TestCase
    public func testRenderRawExpr(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Raw("COUNT(*) AS cnt")]))
        stmt.addClause(FromClause("users"))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT COUNT(*) AS cnt FROM \"users\"")
    }

    @TestCase
    public func testRenderOffset(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(LimitClause(10))
        stmt.addClause(OffsetClause(20))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"users\" LIMIT 10 OFFSET 20")
    }

    @TestCase
    public func testRenderOrderedAndAliased(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Ordered(Column("id"), "DESC")]))
        stmt.addClause(FromClause("t"))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql.contains("DESC"), true)
        let stmt2 = Statement()
        stmt2.addClause(SelectClause([Aliased(Column("name"), "myname")]))
        stmt2.addClause(FromClause("t"))
        let (sql2, _) = dialect.render(stmt2)
        @Expect(sql2.contains("myname"), true)
    }

    @TestCase
    public func testRenderUnaryOps(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        let nullExpr = Unary(IsNull, Column("id"))
        stmt.addClause(WhereClause([nullExpr]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql.contains("IS NULL"), true)
        let stmt2 = Statement()
        stmt2.addClause(SelectClause([Column("id")]))
        stmt2.addClause(FromClause("t"))
        let notNullExpr = Unary(IsNotNull, Column("id"))
        stmt2.addClause(WhereClause([notNullExpr]))
        let (sql2, _) = dialect.render(stmt2)
        @Expect(sql2.contains("IS NOT NULL"), true)
    }

    @TestCase
    public func testRenderSubQuery(): Unit {
        let dialect = PostgreSQLDialect()
        let inner = Statement()
        inner.addClause(SelectClause([Column("id")]))
        inner.addClause(FromClause("t"))
        let outer = Statement()
        outer.addClause(SelectClause([Column("x")]))
        outer.addClause(FromClause("parent"))
        outer.addClause(WhereClause([Binary(Column("x"), In, SubQuery(inner))]))
        let (sql, _) = dialect.render(outer)
        @Expect(sql.contains("SELECT"), true)
        @Expect(sql.contains("parent"), true)
        @Expect(sql.contains("IN (SELECT"), true)
    }

    @TestCase
    public func testUpsertSQL(): Unit {
        let dialect = PostgreSQLDialect()
        @Expect(dialect.hasUpsertSupport(), true)
        let sql = dialect.upsertSQL("users", ["id", "name"], ["id"], [], [], "")
        @Expect(sql.contains("ON CONFLICT"), true)
        @Expect(sql.contains("INSERT INTO"), true)
    }

    @TestCase
    public func testUpsertSQLVersionAudit(): Unit {
        let dialect = PostgreSQLDialect()
        let sql = dialect.upsertSQL("users", ["id", "name", "created_at", "updated_at", "version"], ["id"], ["created_at"], ["updated_at"], "version")
        @Expect(sql.contains("\"users\".\"version\" = \"users\".\"version\" + 1"), true)
        @Expect(sql.contains("\"updated_at\" = EXCLUDED.\"updated_at\""), true)
        @Expect(sql.contains("\"created_at\" = EXCLUDED.\"created_at\""), false)
        @Expect(sql.contains("\"name\" = EXCLUDED.\"name\""), true)
    }

    @TestCase
    public func testRenderBinOpsNe(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Ne, Value(1))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql.contains("<>"), true)
    }

    @TestCase
    public func testRenderOrderByBeforeLimit(): Unit {
        let dialect = PostgreSQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Eq, Value(1))]))
        stmt.addClause(LimitClause(3))
        stmt.addClause(OffsetClause(0))
        stmt.addClause(OrderByClause([Column("id")]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"t\" WHERE \"a\" = $1 ORDER BY \"id\" LIMIT 3 OFFSET 0")
    }

    @TestCase
    public func testIsolationSQL(): Unit {
        let dialect = PostgreSQLDialect()
        @Expect(dialect.isolationSQL(IsolationLevel.Serializable), "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        @Expect(dialect.isolationSQL(IsolationLevel.ReadCommitted), "SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
        @Expect(dialect.isolationSQL(IsolationLevel.ReadUncommitted), "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")
        @Expect(dialect.isolationSQL(IsolationLevel.RepeatableRead), "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
    }
}
