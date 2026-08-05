package refine

import std.unittest.*
import std.unittest.testmacro.*

// R-M19: MariaDBDialect —— MySQLDialect 的 MariaDB 服务端变体。
// MariaDB 服务端不支持 MySQL 8.0.19+ 的 `AS new` 行别名（ERROR 1064），仅支持老语法
// `VALUES(col)` 在 DO UPDATE SET 里引用新插入行值。本组测试验证 MariaDBDialect 的
// upsertSQL 生成 MariaDB 合法语法，且其余行为全部继承 MySQLDialect。
@Test
public class MariaDBDialectTest {

    @TestCase
    public func testDialectName(): Unit {
        let dialect = MariaDBDialect()
        @Expect(dialect.name(), "mariadb")
    }

    // 普通 upsert：VALUES 列表后不加 AS new，非冲突列用 `col = VALUES(col)`（MariaDB 老语法）
    @TestCase
    public func testUpsertPlainUsesValuesFunction(): Unit {
        let dialect = MariaDBDialect()
        let (sql, extraCount) = dialect.upsertSQL("users", ["id", "name"], ["id"], [], [], "")
        @Expect(sql, "INSERT INTO `users` (`id`, `name`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `name` = VALUES(`name`)")
        @Expect(sql.contains("AS new"), false)
        @Expect(sql.contains("new.`name`"), false)
        @Expect(extraCount, 0)
    }

    // version 自增 + 审计更新列：MariaDB 用 VALUES(version) + 1（新插入值 + 1，与 MySQL
    // 的 new.col 语义等价）；审计更新列仍生成 `col = ?` 并计 extraParamCount。
    @TestCase
    public func testUpsertVersionAudit(): Unit {
        let dialect = MariaDBDialect()
        let (sql, extraCount) = dialect.upsertSQL("users", ["id", "name", "created_at", "updated_at", "version"], ["id"], ["created_at"], ["updated_at"], "version")
        @Expect(sql.contains("`version` = VALUES(`version`) + 1"), true)
        @Expect(sql.contains("`version` = `users`.`version` + 1"), false)
        @Expect(sql.contains("`updated_at` = ?"), true)
        @Expect(sql.contains("`created_at` = VALUES(`created_at`)"), false)
        @Expect(sql.contains("`name` = VALUES(`name`)"), true)
        @Expect(sql.contains("AS new"), false)
        @Expect(extraCount, 1)
    }

    // 只有 version 列的 upsert：version 自增不带审计参数
    @TestCase
    public func testUpsertVersionOnly(): Unit {
        let dialect = MariaDBDialect()
        let (sql, extraCount) = dialect.upsertSQL("users", ["id", "version"], ["id"], [], [], "version")
        @Expect(sql.contains("`version` = VALUES(`version`) + 1"), true)
        @Expect(sql.contains("AS new"), false)
        @Expect(extraCount, 0)
    }

    // 全冲突列（纯关联表直接 upsert）时 UPDATE SET 为空，用首列无操作更新保语法合法：
    // `col = VALUES(col)`（恒等赋值，MariaDB 语法合法，无 AS new 时的裸列歧义）
    @TestCase
    public func testUpsertAllColumnsAreConflictProducesValidNoop(): Unit {
        let dialect = MariaDBDialect()
        let (sql, extraCount) = dialect.upsertSQL("junc", ["a_id", "b_id"], ["a_id", "b_id"], [], [], "")
        @Expect(sql.contains("ON DUPLICATE KEY UPDATE `a_id` = VALUES(`a_id`)"), true)
        @Expect(sql.contains("AS new"), false)
        @Expect(extraCount, 0)
    }

    // 审计更新列计数与 MySQLDialect 对齐
    @TestCase
    public func testUpsertExtraParamCount(): Unit {
        let dialect = MariaDBDialect()
        let (_, c0) = dialect.upsertSQL("users", ["id", "name"], ["id"], [], [], "")
        @Expect(c0, 0)
        let (_, c1) = dialect.upsertSQL("users", ["id", "name", "updated_at"], ["id"], [], ["updated_at"], "")
        @Expect(c1, 1)
        let (_, c2) = dialect.upsertSQL("users", ["id", "version"], ["id"], [], ["version"], "version")
        @Expect(c2, 0)
        let (_, c3) = dialect.upsertSQL("users", ["id", "created_at", "updated_at"], ["id"], ["created_at", "updated_at"], ["updated_at"], "")
        @Expect(c3, 0)
        let (_, c4) = dialect.upsertSQL("users", ["id", "a", "b"], ["id"], [], ["a", "b"], "")
        @Expect(c4, 2)
    }

    // 继承 MySQLDialect：quoteIdentifier 反引号（含 C9 内嵌反引号转义）
    @TestCase
    public func testInheritsQuoteIdentifier(): Unit {
        let dialect = MariaDBDialect()
        @Expect(dialect.quoteIdentifier("users"), "`users`")
        @Expect(dialect.quoteIdentifier("foo`bar"), "`foo``bar`")
        @Expect(dialect.quoteIdentifier("foo``bar"), "`foo````bar`")
    }

    // 继承 MySQLDialect：dataTypeOf 存储类型映射
    @TestCase
    public func testInheritsDataTypeOf(): Unit {
        let dialect = MariaDBDialect()
        @Expect(dialect.dataTypeOf(StorageType.Integer), "BIGINT")
        @Expect(dialect.dataTypeOf(StorageType.Float), "DOUBLE")
        @Expect(dialect.dataTypeOf(StorageType.Text), "TEXT")
        @Expect(dialect.dataTypeOf(StorageType.Bytes), "LONGBLOB")
        @Expect(dialect.dataTypeOf(StorageType.Timestamp), "DATETIME(6)")
    }

    // 继承 MySQLDialect：I3 裸 OFFSET（无 LIMIT）补 LIMIT 18446744073709551615 哨兵
    @TestCase
    public func testInheritsLimitOffsetSentinel(): Unit {
        let dialect = MariaDBDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id")]))
        stmt.addClause(FromClause("users"))
        stmt.addClause(OffsetClause(20))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT `id` FROM `users` LIMIT 18446744073709551615 OFFSET 20")
    }

    // 继承：hasUpsertSupport / hasJSONSupport / initialize
    @TestCase
    public func testInheritsCapabilityFlags(): Unit {
        let dialect = MariaDBDialect()
        @Expect(dialect.hasUpsertSupport(), true)
        @Expect(dialect.hasJSONSupport(), true)
        @Expect(dialect.hasIsolationSupport(), true)
        dialect.initialize(DB(MockDatasource()))
    }

    // 继承：migrator 返回 MySQLMigrator（MariaDB 建表/迁移语法与 MySQL 一致）
    @TestCase
    public func testInheritsMigrator(): Unit {
        let dialect = MariaDBDialect()
        let db = DB(MockDatasource(), 1)
        let m = dialect.migrator(db)
        match (m) {
            case _: MySQLMigrator => ()
            case _ => @Fail("expected MySQLMigrator for MariaDB dialect")
        }
    }

    // R-M19: 作为 Dialect 接口类型使用时动态派发（DetectServerDialect 返回 Dialect）
    @TestCase
    public func testDialectDispatch(): Unit {
        let d: Dialect = MariaDBDialect()
        @Expect(d.name(), "mariadb")
        let (sql, _) = d.upsertSQL("users", ["id", "name"], ["id"], [], [], "")
        @Expect(sql.contains("AS new"), false)
        @Expect(sql.contains("VALUES(`name`)"), true)
    }
}
