package refine

import std.unittest.*
import std.unittest.testmacro.*

private func checkInt(v: Any, expected: Int64): Bool {
    match (v) {
        case i: Int64 => i == expected
        case _ => false
    }
}

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
        // 回归（C9）：标识符内嵌引号必须转义（" → ""），否则可逃逸标识符边界构造任意 SQL
        @Expect(dialect.quoteIdentifier("foo\"bar"), "\"foo\"\"bar\"")
        @Expect(dialect.quoteIdentifier("foo\"\"bar"), "\"foo\"\"\"\"bar\"")
    }

    // 回归（C9）：from(table) 表名来自 API 参数，内嵌引号不得逃逸出标识符边界（封闭 SQL 注入通道）
    @TestCase
    public func testRenderEscapesInjectedTable(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users\"; DROP TABLE users; --"))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"users\"\"; DROP TABLE users; --\"")
        @Expect(params.size, 0)
    }

    // 回归（C9）：updateWhere(setCols) 列名来自 API 参数，内嵌引号不得逃逸（封闭 SQL 注入通道）
    @TestCase
    public func testRenderEscapesInjectedSetCol(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(UpdateClause("users", ["name\" = 'admin' OR 1=1; --"], ["bob"]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "UPDATE \"users\" SET \"name\"\" = 'admin' OR 1=1; --\" = ?")
        @Expect(params.size, 1)
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

    // 回归：软删实体 query() 自带 deleted_at 过滤 + 用户追加 filter() 会产生多个 WhereClause，
    // 必须 AND 连接而非重复 WHERE（修复前生成 `... WHERE deleted_at = ? WHERE user_id = ?` 语法错误）
    @TestCase
    public func testRenderMultipleWhereClauses(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("soft_posts"))
        stmt.addClause(WhereClause([Binary(Column("deleted_at"), Eq, Value(0))]))
        stmt.addClause(WhereClause([Binary(Column("user_id"), Eq, Value(7))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\" FROM \"soft_posts\" WHERE \"deleted_at\" = ? AND \"user_id\" = ?")
        @Expect(params.size, 2)
    }

    // 回归：单 WhereClause 多谓词（q.filter([a, b]) 数组过滤）必须 AND 拼接，
    // 修复前渲染成 `WHERE a = ? , b = ?` 非法 SQL
    @TestCase
    public func testRenderFilterArray(): Unit {
        let dialect = SQLiteDialect()
        let q = Query<Int64>()
        q.from("users")
        q.filter([
            Binary(Column("name"), Eq, Value("Alice")),
            Binary(Column("age"), Gt, Value(18))
        ])
        let (sql, params) = dialect.render(q.stmt)
        @Expect(sql, "SELECT * FROM \"users\" WHERE \"name\" = ? AND \"age\" > ?")
        @Expect(params.size, 2)
    }

    // 回归：HAVING 多谓词语义与 WHERE 相同（对分组过滤），必须 AND 拼接（对齐 PG renderAndList）
    @TestCase
    public func testRenderHavingMultiplePredicates(): Unit {
        let dialect = SQLiteDialect()
        let q = Query<Int64>()
        q.from("employees")
        q.groupBy([Column("dept")])
        q.having([
            Binary(FuncCall("COUNT", [Column("id")]), Gt, Value(5)),
            Binary(Column("dept"), Ne, Value("sales"))
        ])
        let (sql, params) = dialect.render(q.stmt)
        @Expect(sql, "SELECT * FROM \"employees\" GROUP BY \"dept\" HAVING COUNT(\"id\") > ? AND \"dept\" <> ?")
        @Expect(params.size, 2)
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
        @Expect(sqlite.hasJSONSupport(), true)
        @Expect(sqlite.hasIsolationSupport(), false)

        let mysql = MySQLDialect()
        @Expect(mysql.hasReturningSupport(), false)
        @Expect(mysql.hasJSONSupport(), true)
        @Expect(mysql.hasIsolationSupport(), true)

        let pg = PostgreSQLDialect()
        @Expect(pg.hasReturningSupport(), true)
        @Expect(pg.hasJSONSupport(), true)
        @Expect(pg.hasIsolationSupport(), true)
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

    // 回归：子查询渲染不得重置 params，外层参数不得丢失、不得重复
    @TestCase
    public func testRenderSubQueryWithParams(): Unit {
        let dialect = SQLiteDialect()
        let inner = Statement()
        inner.addClause(SelectClause([Column("id")]))
        inner.addClause(FromClause("t"))
        inner.addClause(WhereClause([Binary(Column("c"), Eq, Value(10))]))
        let outer = Statement()
        outer.addClause(SelectClause([Column("x")]))
        outer.addClause(FromClause("parent"))
        outer.addClause(WhereClause([
            Binary(Column("x"), Eq, Value(5)),
            Binary(Column("x"), In, SubQuery(inner))
        ]))
        let (sql, params) = dialect.render(outer)
        @Expect(sql, "SELECT \"x\" FROM \"parent\" WHERE \"x\" = ? AND \"x\" IN (SELECT \"id\" FROM \"t\" WHERE \"c\" = ?)")
        @Expect(params.size, 2)
        @Expect(checkInt(params[0], 5))
        @Expect(checkInt(params[1], 10))
    }

    @TestCase
    public func testUpsertSupport(): Unit {
        let dialect = SQLiteDialect()
        @Expect(dialect.hasUpsertSupport(), true)
        let (sql, extraCount) = dialect.upsertSQL("users", ["id", "name", "email"], ["id"], [], ["updated_at"], "version")
        @Expect(sql, "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES (?, ?, ?) ON CONFLICT (\"id\") DO UPDATE SET \"id\" = excluded.\"id\", \"name\" = excluded.\"name\", \"email\" = excluded.\"email\"")
        @Expect(extraCount, 0)
    }

    // SQLite upsert 使用 excluded.col（不区分大小写，对齐官方文档小写），不需要额外参数；
    // version 列冲突时自增（未限定列名引用原行；SQLite 的 DO UPDATE SET 不支持 table.col 限定符）
    @TestCase
    public func testUpsertSQLVersionCol(): Unit {
        let dialect = SQLiteDialect()
        let (sql, extraCount) = dialect.upsertSQL("users", ["id", "name", "version"], ["id"], [], [], "version")
        @Expect(sql, "INSERT INTO \"users\" (\"id\", \"name\", \"version\") VALUES (?, ?, ?) ON CONFLICT (\"id\") DO UPDATE SET \"id\" = excluded.\"id\", \"name\" = excluded.\"name\", \"version\" = \"version\" + 1")
        @Expect(extraCount, 0)
    }

    // SQLite upsert 审计创建列（created_at）冲突时不覆盖：不生成更新子句，无需额外参数
    @TestCase
    public func testUpsertSQLAuditCreateSkipped(): Unit {
        let dialect = SQLiteDialect()
        let (sql, extraCount) = dialect.upsertSQL("posts", ["id", "title", "created_at"], ["id"], ["created_at"], [], "")
        @Expect(sql, "INSERT INTO \"posts\" (\"id\", \"title\", \"created_at\") VALUES (?, ?, ?) ON CONFLICT (\"id\") DO UPDATE SET \"id\" = excluded.\"id\", \"title\" = excluded.\"title\"")
        @Expect(extraCount, 0)
    }

    // 回归（I15）：SQLite 复合主键冲突目标必须完整列出（ON CONFLICT ("pk1", "pk2")）
    @TestCase
    public func testUpsertSQLCompoundConflict(): Unit {
        let dialect = SQLiteDialect()
        let (sql, extraCount) = dialect.upsertSQL("order_tags", ["order_id", "tag_id", "quantity"], ["order_id", "tag_id"], [], [], "")
        @Expect(sql, "INSERT INTO \"order_tags\" (\"order_id\", \"tag_id\", \"quantity\") VALUES (?, ?, ?) ON CONFLICT (\"order_id\", \"tag_id\") DO UPDATE SET \"order_id\" = excluded.\"order_id\", \"tag_id\" = excluded.\"tag_id\", \"quantity\" = excluded.\"quantity\"")
        @Expect(extraCount, 0)
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
