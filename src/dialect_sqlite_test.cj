package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class DialectTest {
    @TestCase
    public func testDialectName(): Unit {
        let dialect = SQLiteDialect()
        @Expect(dialect.name(), "sqlite")
    }

    @TestCase
    public func testQuoteIdentifier(): Unit {
        let dialect = SQLiteDialect()
        @Expect(dialect.quoteIdentifier("users"), "\"users\"")
        @Expect(dialect.quoteIdentifier("u.id"), "\"u.id\"")
        @Expect(dialect.quoteIdentifier("count"), "\"count\"")
    }

    @TestCase
    public func testRenderSelectStar(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([]))
        stmt.addClause(FromClause("users"))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT * FROM \"users\"")
        @Expect(params.size, 0)
    }

    @TestCase
    public func testRenderSelectWithWhere(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id"), Column("name")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(WhereClause([Binary(Column("age"), Gt, Value(18))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\", \"name\" FROM \"users\" WHERE \"age\" > ?")
        @Expect(params.size, 1)
    }

    @TestCase
    public func testRenderOrderByLimit(): Unit {
        let dialect = SQLiteDialect()
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
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("dept"), FuncCall("COUNT", [Column("id")])]))
        stmt.addClause(FromClause("employees"))
        stmt.addClause(GroupByClause([Column("dept")]))
        stmt.addClause(HavingClause([Binary(FuncCall("COUNT", [Column("id")]), Gt, Value(5))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"dept\", COUNT(\"id\") FROM \"employees\" GROUP BY \"dept\" HAVING COUNT(\"id\") > ?")
        @Expect(params.size, 1)
    }

    @TestCase
    public func testRenderJoin(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("u.id"), Column("u.name")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(JoinClause("orders", "o", Binary(Column("u.id"), Eq, Column("o.user_id"))))
        stmt.addClause(WhereClause([Binary(Column("u.age"), Gt, Value(18))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"u.id\", \"u.name\" FROM \"users\" LEFT JOIN \"orders\" \"o\" ON \"u.id\" = \"o.user_id\" WHERE \"u.age\" > ?")
        @Expect(params.size, 1)
    }

    @TestCase
    public func testRenderAllClauseTypes(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Eq, Value(1))]))
        stmt.addClause(GroupByClause([Column("b")]))
        stmt.addClause(HavingClause([Binary(FuncCall("COUNT", [Column("c")]), Gt, Value(0))]))
        stmt.addClause(OrderByClause([Column("d")]))
        stmt.addClause(LimitClause(5))
        stmt.addClause(OffsetClause(10))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"t\" WHERE \"a\" = ? GROUP BY \"b\" HAVING COUNT(\"c\") > ? ORDER BY \"d\" LIMIT 5 OFFSET 10")
        @Expect(params.size, 2)
    }

    @TestCase
    public func testRenderBinOps(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("x")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Eq, Value(1))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"x\" FROM \"t\" WHERE \"a\" = ?")
    }

    @TestCase
    public func testRenderUnaryNot(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Unary(Not, Column("active"))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"t\" WHERE NOT \"active\"")
    }

    @TestCase
    public func testRenderRawExpr(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Raw("COUNT(*) AS cnt")]))
        stmt.addClause(FromClause("users"))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT COUNT(*) AS cnt FROM \"users\"")
    }

    @TestCase
    public func testRenderOffset(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(LimitClause(10))
        stmt.addClause(OffsetClause(20))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"users\" LIMIT 10 OFFSET 20")
    }

    @TestCase
    public func testSQLiteDataTypeOf(): Unit {
        let d = SQLiteDialect()
        @Expect(d.dataTypeOf(StorageType.Integer), "INTEGER")
        @Expect(d.dataTypeOf(StorageType.Float), "REAL")
        @Expect(d.dataTypeOf(StorageType.Decimal), "NUMERIC")
        @Expect(d.dataTypeOf(StorageType.`Bool`), "INTEGER")
        @Expect(d.dataTypeOf(StorageType.String), "TEXT")
        @Expect(d.dataTypeOf(StorageType.Text), "TEXT")
        @Expect(d.dataTypeOf(StorageType.Json), "TEXT")
        @Expect(d.dataTypeOf(StorageType.Bytes), "BLOB")
        @Expect(d.dataTypeOf(StorageType.Timestamp), "TEXT")
    }

    @TestCase
    public func testMySQLDataTypeOf(): Unit {
        let d = MySQLDialect()
        @Expect(d.dataTypeOf(StorageType.Integer), "BIGINT")
        @Expect(d.dataTypeOf(StorageType.Float), "DOUBLE")
        @Expect(d.dataTypeOf(StorageType.Decimal), "DECIMAL(65,30)")
        @Expect(d.dataTypeOf(StorageType.`Bool`), "TINYINT(1)")
        @Expect(d.dataTypeOf(StorageType.String), "VARCHAR(255)")
        @Expect(d.dataTypeOf(StorageType.Text), "TEXT")
        @Expect(d.dataTypeOf(StorageType.Json), "JSON")
        @Expect(d.dataTypeOf(StorageType.Bytes), "LONGBLOB")
        @Expect(d.dataTypeOf(StorageType.Timestamp), "DATETIME(6)")
    }

    @TestCase
    public func testPostgreSQLDataTypeOf(): Unit {
        let d = PostgreSQLDialect()
        @Expect(d.dataTypeOf(StorageType.Integer), "BIGINT")
        @Expect(d.dataTypeOf(StorageType.Float), "DOUBLE PRECISION")
        @Expect(d.dataTypeOf(StorageType.Decimal), "DECIMAL")
        @Expect(d.dataTypeOf(StorageType.`Bool`), "BOOLEAN")
        @Expect(d.dataTypeOf(StorageType.String), "VARCHAR(255)")
        @Expect(d.dataTypeOf(StorageType.Text), "TEXT")
        @Expect(d.dataTypeOf(StorageType.Json), "JSONB")
        @Expect(d.dataTypeOf(StorageType.Bytes), "BYTEA")
        @Expect(d.dataTypeOf(StorageType.Timestamp), "TIMESTAMP")
    }

    @TestCase
    public func testDialectFeatureFlags(): Unit {
        let sqlite = SQLiteDialect()
        @Expect(sqlite.hasReturningSupport(), false)
        @Expect(sqlite.hasJSONSupport(), false)

        let mysql = MySQLDialect()
        @Expect(mysql.hasReturningSupport(), false)
        @Expect(mysql.hasJSONSupport(), true)

        let pg = PostgreSQLDialect()
        @Expect(pg.hasReturningSupport(), true)
        @Expect(pg.hasJSONSupport(), true)
    }

    @TestCase
    public func testRenderOrderedAndAliased(): Unit {
        let dialect = SQLiteDialect()
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
        let dialect = SQLiteDialect()
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
        let dialect = SQLiteDialect()
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
    public func testUpsertSupport(): Unit {
        let dialect = SQLiteDialect()
        @Expect(dialect.hasUpsertSupport(), false)
    }

    @TestCase
    public func testInitializeAndDefaultValue(): Unit {
        let dialect = SQLiteDialect()
        dialect.initialize(DB(MockDatasource()))
        @Expect(dialect.defaultValueOf(StorageType.Integer), "")
    }

    @TestCase
    public func testRenderBinOpsNe(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Ne, Value(1))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql.contains("<>"), true)
    }

    @TestCase
    public func testRenderOrderByBeforeLimit(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Eq, Value(1))]))
        stmt.addClause(LimitClause(3))
        stmt.addClause(OffsetClause(0))
        stmt.addClause(OrderByClause([Column("id")]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"t\" WHERE \"a\" = ? ORDER BY \"id\" LIMIT 3 OFFSET 0")
    }
}
