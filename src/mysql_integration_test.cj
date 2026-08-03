package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.QueryResult
import std.unittest.*
import std.unittest.testmacro.*
import refine.macros.*
import mariadb.cdbc.*

func tryMySQL(): Option<Refine> {
    try {
        Some(Refine.open("mariadb://127.0.0.1:3306", [
            ("username", "root"),
            ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
            ("database", "refine_test")
        ]))
    } catch (_: Exception) {
        None
    }
}

struct ISchema <: TableSchema {
    var t: String
    var c: Array<ColumnDef>
    var i: Array<IndexDef>
    public init(name: String, cols: Array<ColumnDef>, idxs: Array<IndexDef>) {
        this.t = name; this.c = cols; this.i = idxs
    }
    public func tableName(): String { t }
    public func columns(): Array<ColumnDef> { c }
    public func indexes(): Array<IndexDef> { i }
}

@Test
public class MySQLIntegrationTest {

    @TestCase
    public func testColumnDefSQL(): Unit {
        let d = MySQLDialect()
        let sql1 = MySQLMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, true, false), d)
        @Expect(sql1, "`id` BIGINT AUTO_INCREMENT PRIMARY KEY")
        let sql2 = MySQLMigrator.columnDefSQL(ColumnDef("name", StorageType.Text, false, false, false), d)
        @Expect(sql2, "`name` TEXT NOT NULL")
        let sql3 = MySQLMigrator.columnDefSQL(ColumnDef("bio", StorageType.Text, false, false, true), d)
        @Expect(sql3, "`bio` TEXT")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let d = MySQLDialect()
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
        let schema = ISchema("test_tbl", cols, [])
        let sql = MySQLMigrator.createTableSQL(schema, d)
        @Expect(sql.contains("CREATE TABLE IF NOT EXISTS"), true)
        @Expect(sql.contains("test_tbl"), true)
        @Expect(sql.contains("AUTO_INCREMENT PRIMARY KEY"), true)
    }

    @TestCase
    public func testMigratorHasTable(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let m = rf.migrator()
                @Expect(m.hasTable("information_schema.TABLES"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorCreateDropTable(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = ISchema("__test_my_mig", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                @Expect(m.hasTable("__test_my_mig"), true)
                m.dropTable(schema)
                @Expect(m.hasTable("__test_my_mig"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddColumn(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = ISchema("__test_my_col", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                m.addColumn("__test_my_col", ColumnDef("extra", StorageType.Text, false, false, true))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddIndex(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_idx", cols, [IndexDef("idx_name", ["name"])])
                let m = rf.migrator()
                m.createTable(schema)
                m.addIndex("__test_my_idx", IndexDef("idx_name2", ["name"]))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAutoMigrate(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.Text, false, false, false)]
                let schema = ISchema("__test_my_auto", cols, [])
                let m = rf.migrator()
                m.autoMigrate([schema])
                @Expect(m.hasTable("__test_my_auto"), true)
                m.autoMigrate([schema])
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testAlterColumnReal(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let m = rf.migrator()
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_alt", cols, [])
                m.createTable(schema)
                m.alterColumn("__test_my_alt",
                    ColumnDef("val", StorageType.String, false, false, false),
                    ColumnDef("val", StorageType.Text, false, false, true))
                rf.transaction { tx: Tx =>
                    let r = tx.query("SELECT DATA_TYPE, IS_NULLABLE FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ? AND COLUMN_NAME = ?", ["__test_my_alt", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(1), "text")
                        @Expect(r.get<String>(2), "YES")
                    } else {
                        @Expect(true, false)
                    }
                }
                m.dropTable(schema)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testAutoMigrateAddOnlyLeavesExistingColumn(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let m = rf.migrator()
                let oldCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_alt2", oldCols, [])
                m.createTable(schema)
                let newCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.Text, false, false, true),
                               ColumnDef("extra", StorageType.Integer, false, false, true)]
                let newSchema = ISchema("__test_my_alt2", newCols, [])
                m.autoMigrate([newSchema])
                rf.transaction { tx: Tx =>
                    // 只加语义：已存在列即使类型/可空性不同也不被修改
                    let r = tx.query("SELECT DATA_TYPE, IS_NULLABLE FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ? AND COLUMN_NAME = ?", ["__test_my_alt2", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(1), "varchar")
                        @Expect(r.get<String>(2), "NO")
                    } else {
                        @Expect(true, false)
                    }
                    // 缺失列仍被补充
                    let r2 = tx.query("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ? AND COLUMN_NAME = ?", ["__test_my_alt2", "extra"])
                    if (r2.next()) {
                        @Expect(r2.get<Int64>(1), 1)
                    } else {
                        @Expect(true, false)
                    }
                }
                m.dropTable(schema)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorDropColumn(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_drop", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                m.dropColumn("__test_my_drop", "name")
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    // ─── R-C2: 窄整数/单精度浮点字段真实 MySQL 写路径回归 ─────────────────────
    // 修复前 dispatchSet 对 UInt8/UInt16/UInt32/UInt64/Int8/Int16/Float32 落 setNull：
    // 可空列静默写 NULL、NOT NULL 列报错——静默数据损坏。修复后按存储表示换算
    // （整数 → set<Int64>、Float32 → set<Float64>）。真实 MySQL 链路 save 后直查列值，
    // 验证绑定类型与换算结果都正确（而非 NULL 或类型错位）。
    @TestCase
    public func testNarrowNumericFieldsSaveCorrectly(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `narrowfield`", [])
                }
                rf.migrator().autoMigrate([NarrowFieldSchema()])
                let e = NarrowField()
                e.u8 = 200
                e.u16 = 60000
                e.u32 = 4000000000
                e.u64 = 9000000000
                e.i8 = -5
                e.i16 = -1000
                e.f32 = 1.5
                rf.transaction { tx: Tx => tx.save(e) }
                @Expect(e.id > 0, true)
                rf.transaction { tx: Tx =>
                    let r = tx.query("SELECT `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `f32` FROM `narrowfield` WHERE `id` = ?", [e.id])
                    if (r.next()) {
                        // 用 ORM 的列映射（含 paramOffset）取列索引，PG/MariaDB 驱动索引基数不同
                        let cm = buildColumnMap(r.columnInfos, tx.getParamOffset())
                        @Expect(r.get<Int64>(cm.get("u8").getOrThrow()), 200)
                        @Expect(r.get<Int64>(cm.get("u16").getOrThrow()), 60000)
                        @Expect(r.get<Int64>(cm.get("u32").getOrThrow()), 4000000000)
                        @Expect(r.get<Int64>(cm.get("u64").getOrThrow()), 9000000000)
                        @Expect(r.get<Int64>(cm.get("i8").getOrThrow()), -5)
                        @Expect(r.get<Int64>(cm.get("i16").getOrThrow()), -1000)
                        @Expect(r.get<Float64>(cm.get("f32").getOrThrow()), 1.5)
                    } else {
                        @Expect(true, false)
                    }
                }
                rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS `narrowfield`", []) }
                rf.close()
            case None => @Expect(true, true)
        }
    }
}

// ─── Query 集成测试 ────────────────────────────────────

@Refine
@Table["__q_users"]
class QUser {
    var id: Int64 = 0
    var name: String = ""
}

@Test
public class QueryIntegrationTest {
    static var qrf: Option<Refine> = None

    @BeforeAll
    static func setupClass(): Unit {
        qrf = tryMySQL()
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("CREATE TABLE IF NOT EXISTS __q_users (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL)", [])
                }
            case None => ()
        }
    }

    @AfterAll
    static func teardownClass(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS __q_users", [])
                }
            case None => ()
        }
    }

    @TestCase
    public func testAllWithFilter(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (id, name) VALUES (1, 'Alice')", [])
                    tx.execute("INSERT INTO __q_users (id, name) VALUES (2, 'Bob')", [])
                }
                let users = QUser.query().using(rf).filter(QUser.col().name == "Alice").all()
                @Expect(users.size, 1)
                @Expect(users[0].name, "Alice")
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testOneWithFilter(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (id, name) VALUES (10, 'Target')", [])
                }
                let user = QUser.query().using(rf).filter(QUser.col().name == "Target").one()
                @Expect(user.isSome(), true)
                @Expect(user.getOrThrow().name, "Target")
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testCount(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    for (i in 0..3) {
                        tx.execute("INSERT INTO __q_users (name) VALUES ('U" + i.toString() + "')", [])
                    }
                }
                let cnt = QUser.query().using(rf).count()
                @Expect(cnt >= 3, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testExists(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('ExistsTest')", [])
                }
                @Expect(QUser.query().using(rf).filter(QUser.col().name == "ExistsTest").exists(), true)
                @Expect(QUser.query().using(rf).filter(QUser.col().name == "NonExistent").exists(), false)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testOrderLimitOffset(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    for (i in 0..5) {
                        tx.execute("INSERT INTO __q_users (name) VALUES ('U" + i.toString() + "')", [])
                    }
                }
                let users = QUser.query().using(rf).order([QUser.col().id.desc()]).limit(3).offset(1).all()
                @Expect(users.size, 3)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testFilterAndOr(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('A')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('B')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('C')", [])
                }
                let users = QUser.query().using(rf)
                    .filter((QUser.col().name == "A").or(QUser.col().name == "C")).all()
                @Expect(users.size, 2)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testFilterLike(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('HelloWorld')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('HelloThere')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('Other')", [])
                }
                let users = QUser.query().using(rf)
                    .filter(QUser.col().name.like("%Hello%")).all()
                @Expect(users.size, 2)
            case None => @Expect(true, true)
        }
    }
}

// ─── batch include 真实 MySQL 集成测试 ──────────────────
// 批量 include（分步查询）在真实 MySQL 上的端到端验证。实体复用 macro_test.cj 的
// 共享 fixture（Nested*/CustomTag*/PostWithRel/SameTableRef*，同 package 可直接引用），
// 表名 = 类名小写首字母（如 NestedPost -> nestedPost），迁移建表与批量装配读路径
// 均走 MySQLDialect 的反引号 quoteIdentifier。写入用带反引号的 raw INSERT（与 PG
// 集成测试的引号 SQL 对应）。查询次数在单元层用 mock 断言，此处只断言装配后的数据。

@Test
public class MySQLIncludeIntegrationTest {

    private static func setupNested(rf: Refine): Unit {
        rf.transaction { tx: Tx =>
            tx.execute("DROP TABLE IF EXISTS `nestedComment`", [])
            tx.execute("DROP TABLE IF EXISTS `nestedSkill`", [])
            tx.execute("DROP TABLE IF EXISTS `nestedUser_tags`", [])
            tx.execute("DROP TABLE IF EXISTS `nestedTag`", [])
            tx.execute("DROP TABLE IF EXISTS `nestedProfile`", [])
            tx.execute("DROP TABLE IF EXISTS `nestedUser`", [])
            tx.execute("DROP TABLE IF EXISTS `nestedPost`", [])
        }
    }

    @TestCase
    public func testIncludeRefTo(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                rf.migrator().autoMigrate([NestedPostSchema(), NestedUserSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedPost` (`title`, `user_id`) VALUES (?, ?)", ["p1", uid]) }
                let found = NestedPost.query().include(NestedPostRel.author).using(rf).filter(NestedPost.col().title == "p1").one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                @Expect(post.title, "p1")
                match (post.author) {
                    case Some(a) =>
                        @Expect(a.id, uid)
                        @Expect(a.name, "Alice")
                    case None => @Expect(true, false)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testIncludeRefToNullAuthorNoCrash(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                rf.migrator().autoMigrate([NestedPostSchema(), NestedUserSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedPost` (`title`, `user_id`) VALUES (?, ?)", ["OrphanPost", 999999]) }
                let found = NestedPost.query().include(NestedPostRel.author).using(rf).filter(NestedPost.col().title == "OrphanPost").one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                @Expect(post.title, "OrphanPost")
                @Expect(post.user_id, 999999)
                @Expect(post.author.isNone(), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testIncludeHasMany(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                rf.migrator().autoMigrate([NestedUserSchema(), NestedCommentSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `nestedComment` (`body`, `user_id`) VALUES (?, ?)", ["c1", uid])
                    tx.execute("INSERT INTO `nestedComment` (`body`, `user_id`) VALUES (?, ?)", ["c2", uid])
                }
                let found = NestedUser.query().include(NestedUserRel.comments).using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(found.isSome(), true)
                let user = found.getOrThrow()
                @Expect(user.comments.size, 2)
                let bodies = [user.comments[0].body, user.comments[1].body]
                @Expect(bodies.contains("c1") && bodies.contains("c2"), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testIncludeRefMany(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `custom_post_tags`", [])
                    tx.execute("DROP TABLE IF EXISTS `custom_tag_posts`", [])
                    tx.execute("DROP TABLE IF EXISTS `custom_tags`", [])
                }
                let m = rf.migrator()
                m.autoMigrate([CustomTagSchema(), CustomTagPostSchema(), CustomTagPost_TagsJunctionSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `custom_tags` (`name`) VALUES (?)", ["red"]) }
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `custom_tags` (`name`) VALUES (?)", ["blue"]) }
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `custom_tag_posts` (`title`) VALUES (?)", ["p1"]) }
                let post = CustomTagPost.query().using(rf).filter(CustomTagPost.col().title == "p1").one()
                @Expect(post.isSome(), true)
                let p = post.getOrThrow()
                let tagAll = CustomTag.query().using(rf).all()
                @Expect(tagAll.size, 2)
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `custom_post_tags` (`custom_tag_posts_id`, `customTag_id`) VALUES (?, ?)", [p.id, tagAll[0].id])
                    tx.execute("INSERT INTO `custom_post_tags` (`custom_tag_posts_id`, `customTag_id`) VALUES (?, ?)", [p.id, tagAll[1].id])
                    tx.execute("INSERT INTO `custom_post_tags` (`custom_tag_posts_id`, `customTag_id`) VALUES (?, ?)", [p.id, 999999])
                }
                let found = CustomTagPost.query().include(CustomTagPostRel.tags).using(rf).filter(CustomTagPost.col().title == "p1").one()
                @Expect(found.isSome(), true)
                let fp = found.getOrThrow()
                @Expect(fp.tags.size, 2)
                let names = [fp.tags[0].name, fp.tags[1].name]
                @Expect(names.contains("red") && names.contains("blue"), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testNestedIncludeRefToThenHasOne(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                let m = rf.migrator()
                m.autoMigrate([NestedPostSchema(), NestedUserSchema(), NestedProfileSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `nestedProfile` (`bio`, `user_id`) VALUES (?, ?)", ["engineer", uid])
                    tx.execute("INSERT INTO `nestedPost` (`title`, `user_id`) VALUES (?, ?)", ["p1", uid])
                }
                let found = NestedPost.query()
                    .include(NestedPostRel.author.withInclude(NestedUserRel.profile))
                    .using(rf)
                    .filter(NestedPost.col().title == "p1")
                    .one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                @Expect(post.title, "p1")
                match (post.author) {
                    case Some(a) =>
                        @Expect(a.id, uid)
                        @Expect(a.name, "Alice")
                        match (a.profile) {
                            case Some(p) =>
                                @Expect(p.bio, "engineer")
                                @Expect(p.user_id, uid)
                            case None => @Expect(true, false)
                        }
                    case None => @Expect(true, false)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testIncludeAllStringPath(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                let m = rf.migrator()
                m.autoMigrate([NestedPostSchema(), NestedUserSchema(), NestedProfileSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `nestedProfile` (`bio`, `user_id`) VALUES (?, ?)", ["engineer", uid])
                    tx.execute("INSERT INTO `nestedPost` (`title`, `user_id`) VALUES (?, ?)", ["p1", uid])
                }
                let found = NestedPost.query()
                    .includeAll(["author.profile"])
                    .using(rf)
                    .filter(NestedPost.col().title == "p1")
                    .one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                @Expect(post.title, "p1")
                match (post.author) {
                    case Some(a) =>
                        @Expect(a.id, uid)
                        @Expect(a.name, "Alice")
                        match (a.profile) {
                            case Some(p) =>
                                @Expect(p.bio, "engineer")
                                @Expect(p.user_id, uid)
                            case None => @Expect(true, false)
                        }
                    case None => @Expect(true, false)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testNestedRefToThenRefMany(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                let m = rf.migrator()
                m.autoMigrate([NestedPostSchema(), NestedUserSchema(), NestedTagSchema(), NestedUser_TagsJunctionSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `nestedTag` (`name`) VALUES (?)", ["t1"])
                    tx.execute("INSERT INTO `nestedPost` (`title`, `user_id`) VALUES (?, ?)", ["p1", uid])
                }
                let tag = NestedTag.query().using(rf).filter(NestedTag.col().name == "t1").one()
                @Expect(tag.isSome(), true)
                let tid = tag.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `nestedUser_tags` (`nestedUser_id`, `nestedTag_id`) VALUES (?, ?)", [uid, tid])
                }
                let found = NestedPost.query()
                    .include(NestedPostRel.author.withInclude(NestedUserRel.tags))
                    .using(rf)
                    .filter(NestedPost.col().title == "p1")
                    .one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                match (post.author) {
                    case Some(a) =>
                        @Expect(a.id, uid)
                        @Expect(a.name, "Alice")
                        @Expect(a.tags.size, 1)
                        @Expect(a.tags[0].id, tid)
                        @Expect(a.tags[0].name, "t1")
                    case None => @Expect(true, false)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // 混合 include 无笛卡尔积：PostWithRel（postWithRel）同时 include author
    // （ref_to user）与 comments（has_many comment）。2 个主行 × 各 3 条评论，
    // 批量协议返回 2 行主实体（而非 6 行），每行带 3 条评论 + 装配好的 author。
    @TestCase
    public func testMixedHasManyRefToNoCartesian(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `comment`", [])
                    tx.execute("DROP TABLE IF EXISTS `user`", [])
                    tx.execute("DROP TABLE IF EXISTS `postWithRel`", [])
                }
                let m = rf.migrator()
                m.autoMigrate([PostWithRelSchema(), UserSchema(), CommentSchema()])
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `user` (`name`, `email`) VALUES (?, ?)", ["AuthorA", "a@x.com"])
                    tx.execute("INSERT INTO `user` (`name`, `email`) VALUES (?, ?)", ["AuthorB", "b@x.com"])
                }
                let users = User.query().using(rf).order([User.col().id.asc()]).all()
                @Expect(users.size, 2)
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `postWithRel` (`title`, `user_id`, `post_id`) VALUES (?, ?, 0)", ["p1", users[0].id])
                    tx.execute("INSERT INTO `postWithRel` (`title`, `user_id`, `post_id`) VALUES (?, ?, 0)", ["p2", users[1].id])
                }
                let posts = PostWithRel.query().using(rf).order([PostWithRel.col().id.asc()]).all()
                @Expect(posts.size, 2)
                rf.transaction { tx: Tx =>
                    for (i in 0..3) {
                        tx.execute("INSERT INTO `comment` (`body`, `post_id`) VALUES (?, ?)", ["p1c" + i.toString(), posts[0].id])
                        tx.execute("INSERT INTO `comment` (`body`, `post_id`) VALUES (?, ?)", ["p2c" + i.toString(), posts[1].id])
                    }
                }
                let found = PostWithRel.query()
                    .include(PostWithRelRel.author)
                    .include(PostWithRelRel.comments)
                    .using(rf)
                    .order([PostWithRel.col().id.asc()])
                    .all()
                @Expect(found.size, 2)
                @Expect(found[0].comments.size, 3)
                @Expect(found[1].comments.size, 3)
                match (found[0].author) {
                    case Some(a) => @Expect(a.id, users[0].id)
                    case None => @Expect(true, false)
                }
                match (found[1].author) {
                    case Some(a) => @Expect(a.id, users[1].id)
                    case None => @Expect(true, false)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // 同表多 ref 合并：SameTableRefPost 的 author/editor 两个 ref_to 指向同一目标表
    // sameTableRefUser。合并为单条批量查询后分别回填，此处验证两者都正确装配。
    @TestCase
    public func testSameTableRefsBothPopulate(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `sameTableRefPost`", [])
                    tx.execute("DROP TABLE IF EXISTS `sameTableRefUser`", [])
                }
                let m = rf.migrator()
                m.autoMigrate([SameTableRefPostSchema(), SameTableRefUserSchema()])
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `sameTableRefUser` (`name`, `email`) VALUES (?, ?)", ["Alice", "a@x.com"])
                    tx.execute("INSERT INTO `sameTableRefUser` (`name`, `email`) VALUES (?, ?)", ["Eve", "e@x.com"])
                }
                let users = SameTableRefUser.query().using(rf).order([SameTableRefUser.col().id.asc()]).all()
                @Expect(users.size, 2)
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `sameTableRefPost` (`title`, `author_id`, `editor_id`) VALUES (?, ?, ?)", ["t1", users[0].id, users[1].id])
                }
                let found = SameTableRefPost.query()
                    .include(SameTableRefPostRel.author)
                    .include(SameTableRefPostRel.editor)
                    .using(rf)
                    .filter(SameTableRefPost.col().title == "t1")
                    .one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                match (post.author) {
                    case Some(a) =>
                        @Expect(a.id, users[0].id)
                        @Expect(a.name, "Alice")
                    case None => @Expect(true, false)
                }
                match (post.editor) {
                    case Some(e) =>
                        @Expect(e.id, users[1].id)
                        @Expect(e.name, "Eve")
                    case None => @Expect(true, false)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testPageWithHasManyInclude(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                rf.migrator().autoMigrate([NestedUserSchema(), NestedCommentSchema()])
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["U1"])
                    tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["U2"])
                }
                let users = NestedUser.query().using(rf).order([NestedUser.col().id.asc()]).all()
                @Expect(users.size, 2)
                rf.transaction { tx: Tx =>
                    for (i in 0..3) {
                        tx.execute("INSERT INTO `nestedComment` (`body`, `user_id`) VALUES (?, ?)", ["u1c" + i.toString(), users[0].id])
                        tx.execute("INSERT INTO `nestedComment` (`body`, `user_id`) VALUES (?, ?)", ["u2c" + i.toString(), users[1].id])
                    }
                }
                let pg = NestedUser.query()
                    .include(NestedUserRel.comments)
                    .using(rf)
                    .filter(NestedUser.col().id.anyOf([users[0].id, users[1].id]))
                    .page(1, 10)
                @Expect(pg.total, 2)
                @Expect(pg.items.size, 2)
                for (u in pg.items) { @Expect(u.comments.size, 3) }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testEmptyHasManyRelation(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                setupNested(rf)
                rf.migrator().autoMigrate([NestedUserSchema(), NestedCommentSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO `nestedUser` (`name`) VALUES (?)", ["Lonely"]) }
                let found = NestedUser.query().include(NestedUserRel.comments).using(rf).filter(NestedUser.col().name == "Lonely").one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().comments.size, 0)
                rf.close()
            case None => @Expect(true, true)
        }
    }
}
