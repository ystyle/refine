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
public class MySQLDialectTest {
    @TestCase
    public func testDialectName(): Unit {
        let dialect = MySQLDialect()
        @Expect(dialect.name(), "mysql")
    }

    @TestCase
    public func testQuoteIdentifier(): Unit {
        let dialect = MySQLDialect()
        @Expect(dialect.quoteIdentifier("users"), "`users`")
        @Expect(dialect.quoteIdentifier("u.id"), "`u.id`")
        @Expect(dialect.quoteIdentifier("count"), "`count`")
        // 回归（C9）：标识符内嵌反引号必须转义（` → ``），否则可逃逸标识符边界构造任意 SQL
        @Expect(dialect.quoteIdentifier("foo`bar"), "`foo``bar`")
        @Expect(dialect.quoteIdentifier("foo``bar"), "`foo````bar`")
    }

    // 回归（C9）：from(table) 表名来自 API 参数，内嵌反引号不得逃逸出标识符边界（封闭 SQL 注入通道）
    @TestCase
    public func testRenderEscapesInjectedTable(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users`; DROP TABLE users; --"))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `users``; DROP TABLE users; --`")
        @Expect(params.size, 0)
    }

    // 回归（C9）：updateWhere(setCols) 列名来自 API 参数，内嵌反引号不得逃逸（封闭 SQL 注入通道）
    @TestCase
    public func testRenderEscapesInjectedSetCol(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(UpdateClause("users", ["name` = 'admin' OR 1=1; --"], ["bob"]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "UPDATE `users` SET `name`` = 'admin' OR 1=1; --` = ?")
        @Expect(params.size, 1)
    }

    @TestCase
    public func testRenderSelectStar(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([]))
        stmt.addClause(FromClause("users"))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT * FROM `users`")
        @Expect(params.size, 0)
    }

    @TestCase
    public func testRenderSelectWithWhere(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id"), Column("name")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(WhereClause([Binary(Column("age"), Gt, Value(18))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `id`, `name` FROM `users` WHERE `age` > ?")
        @Expect(params.size, 1)
    }

    // 回归：软删实体 query() 自带 deleted_at 过滤 + 用户追加 filter() 会产生多个 WhereClause，
    // 必须 AND 连接而非重复 WHERE（修复前生成 `... WHERE deleted_at = ? WHERE user_id = ?` 语法错误）
    @TestCase
    public func testRenderMultipleWhereClauses(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("soft_posts"))
        stmt.addClause(WhereClause([Binary(Column("deleted_at"), Eq, Value(0))]))
        stmt.addClause(WhereClause([Binary(Column("user_id"), Eq, Value(7))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `soft_posts` WHERE `deleted_at` = ? AND `user_id` = ?")
        @Expect(params.size, 2)
    }

    // 回归：单 WhereClause 多谓词（q.filter([a, b]) 数组过滤）必须 AND 拼接，
    // 修复前渲染成 `WHERE a = ? , b = ?` 非法 SQL
    @TestCase
    public func testRenderFilterArray(): Unit {
        let dialect = MySQLDialect()
        let q = Query<Int64>()
        q.from("users")
        q.filter([
            Binary(Column("name"), Eq, Value("Alice")),
            Binary(Column("age"), Gt, Value(18))
        ])
        let (sql, params) = dialect.render(q.stmt)
        @Expect(sql, "SELECT * FROM `users` WHERE `name` = ? AND `age` > ?")
        @Expect(params.size, 2)
    }

    // 回归：HAVING 多谓词语义与 WHERE 相同（对分组过滤），必须 AND 拼接（对齐 PG renderAndList）
    @TestCase
    public func testRenderHavingMultiplePredicates(): Unit {
        let dialect = MySQLDialect()
        let q = Query<Int64>()
        q.from("employees")
        q.groupBy([Column("dept")])
        q.having([
            Binary(FuncCall("COUNT", [Column("id")]), Gt, Value(5)),
            Binary(Column("dept"), Ne, Value("sales"))
        ])
        let (sql, params) = dialect.render(q.stmt)
        @Expect(sql, "SELECT * FROM `employees` GROUP BY `dept` HAVING COUNT(`id`) > ? AND `dept` <> ?")
        @Expect(params.size, 2)
    }

    @TestCase
    public func testRenderOrderByLimit(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(OrderByClause([Column("name")]))
        stmt.addClause(LimitClause(10))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `users` ORDER BY `name` LIMIT 10")
        @Expect(params.size, 0)
    }

    @TestCase
    public func testRenderGroupByHaving(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("dept"), FuncCall("COUNT", [Column("id")])]))
        stmt.addClause(FromClause("employees"))
        stmt.addClause(GroupByClause([Column("dept")]))
        stmt.addClause(HavingClause([Binary(FuncCall("COUNT", [Column("id")]), Gt, Value(5))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `dept`, COUNT(`id`) FROM `employees` GROUP BY `dept` HAVING COUNT(`id`) > ?")
        @Expect(params.size, 1)
    }

    @TestCase
    public func testRenderJoin(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("u.id"), Column("u.name")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(JoinClause("orders", "o", Binary(Column("u.id"), Eq, Column("o.user_id"))))
        stmt.addClause(WhereClause([Binary(Column("u.age"), Gt, Value(18))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `u.id`, `u.name` FROM `users` LEFT JOIN `orders` `o` ON `u.id` = `o.user_id` WHERE `u.age` > ?")
        @Expect(params.size, 1)
    }

    @TestCase
    public func testRenderAllClauseTypes(): Unit {
        let dialect = MySQLDialect()
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
        @Expect(sql, "SELECT `id` FROM `t` WHERE `a` = ? GROUP BY `b` HAVING COUNT(`c`) > ? ORDER BY `d` LIMIT 5 OFFSET 10")
        @Expect(params.size, 2)
    }

    @TestCase
    public func testRenderOrderByBeforeLimit(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Eq, Value(1))]))
        // clauses added in wrong order: LIMIT before ORDER BY
        stmt.addClause(LimitClause(3))
        stmt.addClause(OffsetClause(0))
        stmt.addClause(OrderByClause([Column("id")]))
        let (sql, _) = dialect.render(stmt)
        // render must reorder: ORDER BY before LIMIT/OFFSET
        @Expect(sql, "SELECT `id` FROM `t` WHERE `a` = ? ORDER BY `id` LIMIT 3 OFFSET 0")
    }

    @TestCase
    public func testRenderBinOps(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("x")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Eq, Value(1))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT `x` FROM `t` WHERE `a` = ?")
    }

    @TestCase
    public func testRenderUnaryNot(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Unary(Not, Column("active"))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `t` WHERE NOT `active`")
    }

    @TestCase
    public func testRenderRawExpr(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Raw("COUNT(*) AS cnt")]))
        stmt.addClause(FromClause("users"))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT COUNT(*) AS cnt FROM `users`")
    }

    @TestCase
    public func testRenderOffset(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(LimitClause(10))
        stmt.addClause(OffsetClause(20))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `users` LIMIT 10 OFFSET 20")
    }

    // 回归（I3）：MySQL 裸 OFFSET（无 LIMIT）是语法错误，必须补 `LIMIT 18446744073709551615` 哨兵
    @TestCase
    public func testRenderOffsetWithoutLimitAddsSentinel(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(OffsetClause(20))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `users` LIMIT 18446744073709551615 OFFSET 20")
    }

    // 回归（I3）：LIMIT + OFFSET 并存时不得插入哨兵
    @TestCase
    public func testRenderLimitOffsetNoSentinel(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(LimitClause(10))
        stmt.addClause(OffsetClause(20))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql.contains("18446744073709551615"), false)
        @Expect(sql, "SELECT `id` FROM `users` LIMIT 10 OFFSET 20")
    }

    @TestCase
    public func testRenderUnaryOps(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        let notNull = Unary(IsNull, Column("id"))
        stmt.addClause(WhereClause([notNull]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql.contains("IS NULL"), true)
    }

    @TestCase
    public func testRenderUpsert(): Unit {
        let dialect = MySQLDialect()
        @Expect(dialect.hasUpsertSupport(), true)
        let (sql, extraCount) = dialect.upsertSQL("users", ["id", "name"], ["id"], [], [], "")
        @Expect(sql.contains("ON DUPLICATE KEY UPDATE"), true)
        @Expect(sql.contains("INSERT INTO"), true)
        @Expect(extraCount, 0)
    }

    @TestCase
    public func testRenderUpsertVersionAudit(): Unit {
        let dialect = MySQLDialect()
        let (sql, extraCount) = dialect.upsertSQL("users", ["id", "name", "created_at", "updated_at", "version"], ["id"], ["created_at"], ["updated_at"], "version")
        @Expect(sql.contains("`version` = `version` + 1"), true)
        @Expect(sql.contains("`updated_at` = ?"), true)
        @Expect(sql.contains("`created_at` = VALUES(`created_at`)"), false)
        @Expect(sql.contains("`name` = VALUES(`name`)"), true)
        @Expect(extraCount, 1)
    }

    @TestCase
    public func testUpsertExtraParamCount(): Unit {
        let dialect = MySQLDialect()
        // 无审计更新列 → 0
        let (_, c0) = dialect.upsertSQL("users", ["id", "name"], ["id"], [], [], "")
        @Expect(c0, 0)
        // 审计更新列在 columns 中 → 每个生成 `col = ?` 计 1
        let (_, c1) = dialect.upsertSQL("users", ["id", "name", "updated_at"], ["id"], [], ["updated_at"], "")
        @Expect(c1, 1)
        // version 列即使出现在审计更新列中也被排除（生成 `col = col + 1` 而非 `?`）
        let (_, c2) = dialect.upsertSQL("users", ["id", "version"], ["id"], [], ["version"], "version")
        @Expect(c2, 0)
        // auditCreate 列即使出现在审计更新列中也跳过 update 子句（不生成 `?`）
        let (_, c3) = dialect.upsertSQL("users", ["id", "created_at", "updated_at"], ["id"], ["created_at", "updated_at"], ["updated_at"], "")
        @Expect(c3, 0)
        // 多个审计更新列依次计数
        let (_, c4) = dialect.upsertSQL("users", ["id", "a", "b"], ["id"], [], ["a", "b"], "")
        @Expect(c4, 2)
        // 审计更新列不在 columns 中 → 不生成 `?`
        let (_, c5) = dialect.upsertSQL("users", ["id", "name"], ["id"], [], ["updated_at"], "")
        @Expect(c5, 0)
    }

    // M14: 主键/冲突列不进入 DO UPDATE SET（pk 冲突时不会变化，写入纯噪音）
    @TestCase
    public func testUpsertSkipsPrimaryKeyInUpdateSet(): Unit {
        let dialect = MySQLDialect()
        let (sql, _) = dialect.upsertSQL("users", ["id", "name", "email"], ["id"], [], [], "")
        @Expect(sql.contains("`id` = VALUES(`id`)"), false)
        @Expect(sql.contains("`name` = VALUES(`name`)"), true)
        @Expect(sql.contains("`email` = VALUES(`email`)"), true)
    }

    // 复合主键：两个冲突列都不应进入 DO UPDATE SET
    @TestCase
    public func testUpsertSkipsAllConflictColumnsInUpdateSet(): Unit {
        let dialect = MySQLDialect()
        let (sql, _) = dialect.upsertSQL("order_tags", ["order_id", "tag_id", "quantity"], ["order_id", "tag_id"], [], [], "")
        @Expect(sql.contains("`order_id` = VALUES(`order_id`)"), false)
        @Expect(sql.contains("`tag_id` = VALUES(`tag_id`)"), false)
        @Expect(sql.contains("`quantity` = VALUES(`quantity`)"), true)
    }

    // 全部列都是冲突列（纯关联表直接 upsert）时 UPDATE SET 为空：
    // MySQL 的 ON DUPLICATE KEY UPDATE 必须至少一条赋值，用首列无操作更新保语法合法
    @TestCase
    public func testUpsertAllColumnsAreConflictProducesValidNoop(): Unit {
        let dialect = MySQLDialect()
        let (sql, extraCount) = dialect.upsertSQL("junc", ["a_id", "b_id"], ["a_id", "b_id"], [], [], "")
        @Expect(sql.contains("ON DUPLICATE KEY UPDATE `a_id` = `a_id`"), true)
        @Expect(extraCount, 0)
    }

    @TestCase
    public func testRenderSubQuery(): Unit {
        let dialect = MySQLDialect()
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
        let dialect = MySQLDialect()
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
        @Expect(sql, "SELECT `x` FROM `parent` WHERE `x` = ? AND `x` IN (SELECT `id` FROM `t` WHERE `c` = ?)")
        @Expect(params.size, 2)
        @Expect(checkInt(params[0], 5))
        @Expect(checkInt(params[1], 10))
    }

    @TestCase
    public func testRenderBinOpsNe(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Ne, Value(1))]))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql.contains("<>"), true)
    }

    // I16: Between 用 Expr.Range（三操作数）渲染成 `BETWEEN ? AND ?`，参数按 low/high 顺序绑定
    @TestCase
    public func testRenderBetween(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Expr.Range(Column("age"), Value(18), Value(65))]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `t` WHERE `age` BETWEEN ? AND ?")
        @Expect(params.size, 2)
        @Expect(checkInt(params[0], 18))
        @Expect(checkInt(params[1], 65))
    }

    // I16: Col.between 便捷方法生成 Expr.Range，渲染与 Range 一致
    @TestCase
    public func testRenderColBetween(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Col<Int64>("age").between(18, 65)]))
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `t` WHERE `age` BETWEEN ? AND ?")
        @Expect(params.size, 2)
    }

    // I16: Col.inSubquery 便捷方法生成 IN (SELECT ...)
    @TestCase
    public func testRenderInSubqueryCol(): Unit {
        let dialect = MySQLDialect()
        let inner = Statement()
        inner.addClause(SelectClause([Column("id")]))
        inner.addClause(FromClause("t"))
        let outer = Statement()
        outer.addClause(SelectClause([Column("x")]))
        outer.addClause(FromClause("parent"))
        outer.addClause(WhereClause([Col<Int64>("x").inSubquery(inner)]))
        let (sql, _) = dialect.render(outer)
        @Expect(sql, "SELECT `x` FROM `parent` WHERE `x` IN (SELECT `id` FROM `t`)")
    }

    // I16: 直接构造 Binary(x, Between, y) 是坏 SQL（缺 AND high），渲染必须拒绝并指引 between()
    @TestCase
    public func testRenderBetweenBinaryRejected(): Unit {
        let dialect = MySQLDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("t"))
        stmt.addClause(WhereClause([Binary(Column("a"), Between, Value(1))]))
        try {
            let _ = dialect.render(stmt)
            @Fail("expected Between binary rejection")
        } catch (e: Exception) {
            @Expect(e.message.contains("between"), true)
        }
    }

    @TestCase
    public func testRenderOrderedAndAliased(): Unit {
        let dialect = MySQLDialect()
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
    public func testInitializeAndDefaultValue(): Unit {
        let dialect = MySQLDialect()
        dialect.initialize(DB(MockDatasource()))
        // I5: defaultValueOf 按存储类型返回默认值字面量（不再是空串死方法）
        @Expect(dialect.defaultValueOf(StorageType.Integer), "0")
    }
}
