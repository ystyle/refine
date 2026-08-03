package refine

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import refine.macros.*
import pgsql.*

func tryPostgres(): Option<Refine> {
    try {
        Some(Refine.open("postgres://127.0.0.1:5432", [
            ("username", "postgres"),
            ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
            ("database", "test"),
            ("sslmode", "disable")
        ]))
    } catch (_: Exception) {
        None
    }
}

struct PgSchema <: TableSchema {
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
public class PostgreSQLIntegrationTest {

    @TestCase
    public func testColumnDefSQL(): Unit {
        let d = PostgreSQLDialect()
        let sql1 = PostgreSQLMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, true, false), d)
        @Expect(sql1, "\"id\" BIGSERIAL PRIMARY KEY")
        let sql2 = PostgreSQLMigrator.columnDefSQL(ColumnDef("name", StorageType.String, false, false, false), d)
        @Expect(sql2, "\"name\" VARCHAR(255) NOT NULL")
        let sql3 = PostgreSQLMigrator.columnDefSQL(ColumnDef("bio", StorageType.Text, false, false, true), d)
        @Expect(sql3, "\"bio\" TEXT")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let d = PostgreSQLDialect()
        let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                    ColumnDef("name", StorageType.String, false, false, false)]
        let schema = PgSchema("test_tbl", cols, [])
        let sql = PostgreSQLMigrator.createTableSQL(schema, d)
        @Expect(sql.contains("CREATE TABLE IF NOT EXISTS"), true)
        @Expect(sql.contains("\"test_tbl\""), true)
        @Expect(sql.contains("BIGSERIAL PRIMARY KEY"), true)
    }

    @TestCase
    public func testAlterColumnReal(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let m = rf.migrator()
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.String, false, false, false)]
                let schema = PgSchema("__test_pg_alt", cols, [])
                m.createTable(schema)
                m.alterColumn("__test_pg_alt",
                    ColumnDef("val", StorageType.String, false, false, false),
                    ColumnDef("val", StorageType.Text, false, false, true))
                rf.transaction { tx: Tx =>
                    let r = tx.query("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_name = ? AND column_name = ?", ["__test_pg_alt", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(0), "text")
                        @Expect(r.get<String>(1), "YES")
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
        match (tryPostgres()) {
            case Some(rf) =>
                let m = rf.migrator()
                let oldCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.String, false, false, false)]
                let schema = PgSchema("__test_pg_alt2", oldCols, [])
                m.createTable(schema)
                let newCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.Text, false, false, true),
                               ColumnDef("extra", StorageType.Integer, false, false, true)]
                let newSchema = PgSchema("__test_pg_alt2", newCols, [])
                m.autoMigrate([newSchema])
                rf.transaction { tx: Tx =>
                    // 只加语义：已存在列即使类型/可空性不同也不被修改
                    let r = tx.query("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_name = ? AND column_name = ?", ["__test_pg_alt2", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(0), "character varying")
                        @Expect(r.get<String>(1), "NO")
                    } else {
                        @Expect(true, false)
                    }
                    // 缺失列仍被补充
                    let r2 = tx.query("SELECT COUNT(*) FROM information_schema.columns WHERE table_name = ? AND column_name = ?", ["__test_pg_alt2", "extra"])
                    if (r2.next()) {
                        @Expect(r2.get<Int64>(0), 1)
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
    public func testMigratorHasTable(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let m = rf.migrator()
                @Expect(m.hasTable("information_schema.tables"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorCreateDropTable(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = PgSchema("__test_pg_mig", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                @Expect(m.hasTable("__test_pg_mig"), true)
                m.dropTable(schema)
                @Expect(m.hasTable("__test_pg_mig"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddColumn(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = PgSchema("__test_pg_col", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                m.addColumn("__test_pg_col", ColumnDef("extra", StorageType.Text, false, false, true))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddIndex(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
                let schema = PgSchema("__test_pg_idx", cols, [IndexDef("idx_name", ["name"])])
                let m = rf.migrator()
                m.createTable(schema)
                m.addIndex("__test_pg_idx", IndexDef("idx_name2", ["name"]))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAutoMigrate(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.Text, false, false, false)]
                let schema = PgSchema("__test_pg_auto", cols, [])
                let m = rf.migrator()
                m.autoMigrate([schema])
                @Expect(m.hasTable("__test_pg_auto"), true)
                m.autoMigrate([schema])
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testAutoMigrateWithEntitySchema(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgpost\"", [])
                }
                rf.migrator().autoMigrate([PgPostSchema()])
                @Expect(rf.migrator().hasTable("pgpost"), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testSaveAutoIncrementReturnsId(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgpost\"", [])
                }
                rf.migrator().autoMigrate([PgPostSchema()])
                let p = PgPost()
                p.title = "RETURNING"
                p.content = "Body"
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testCrudRoundtrip(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgpost\"", [])
                }
                rf.migrator().autoMigrate([PgPostSchema()])
                let p = PgPost()
                p.title = "Roundtrip"
                p.content = "C1"
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)

                let found = PgPost.query().using(rf).filter(PgPost.col().id == p.id).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().title, "Roundtrip")

                found.getOrThrow().content = "C2"
                rf.transaction { tx: Tx => tx.update(found.getOrThrow()) }
                let updated = PgPost.query().using(rf).filter(PgPost.col().id == p.id).one()
                @Expect(updated.getOrThrow().content, "C2")

                rf.transaction { tx: Tx => tx.delete(updated.getOrThrow()) }
                let gone = PgPost.query().using(rf).filter(PgPost.col().id == p.id).one()
                @Expect(gone.isNone(), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testSaveStringPkWithUlid(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgevent\"", [])
                }
                rf.migrator().autoMigrate([PgEventSchema()])
                rf.setIdGenerator(UlidIdGenerator())
                let ev = PgEvent()
                ev.name = "deploy"
                ev.payload = "v1"
                rf.transaction { tx: Tx => tx.save(ev) }
                @Expect(ev.id != "", true)
                @Expect(ev.id.size, 26)
                let found = PgEvent.query().using(rf).filter(PgEvent.col().id == ev.id).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().name, "deploy")
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testBatchSaveStringPk(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgevent\"", [])
                }
                rf.migrator().autoMigrate([PgEventSchema()])
                rf.setIdGenerator(UlidIdGenerator())
                let e1 = PgEvent(); e1.name = "a"
                let e2 = PgEvent(); e2.name = "b"
                rf.transaction { tx: Tx => tx.batchSave([e1, e2]) }
                @Expect(e1.id != "" && e2.id != "", true)
                @Expect(e1.id != e2.id, true)
                let all = PgEvent.query().using(rf).all()
                @Expect(all.size >= 2, true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── I2: 驼峰表名/列名全程保留大小写（迁移建表 + 查询映射回读）──────────────────
    // 注：宏层写路径（INSERT/UPDATE/DELETE）生成未加引号的标识符，PG 会折叠为小写，
    // 无法命中引号原样建出的驼峰表/列（属独立于 I2 的既有限制）。此处用引号 SQL 直接
    // 写入数据，验证 I2 覆盖的迁移建表 + 方言查询渲染 + mapper 驼峰列映射整条链路。

    @TestCase
    public func testCamelCaseRoundtrip(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"camelPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"camelUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([CamelUserSchema(), CamelPostSchema()])
                @Expect(m.hasTable("camelUser"), true)
                @Expect(m.hasTable("camelPost"), true)
                let userParams: Array<Any> = ["Alice"]
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"camelUser\" (\"displayName\") VALUES (?)", userParams) }
                let u = CamelUser.query().using(rf).filter(CamelUser.col().displayName == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                let postParams: Array<Any> = ["Post", uid]
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"camelPost\" (\"title\", \"authorId\") VALUES (?, ?)", postParams) }
                let found = CamelPost.query().using(rf).filter(CamelPost.col().authorId == uid).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().title, "Post")
                @Expect(found.getOrThrow().authorId, uid)
                let users = CamelUser.query().using(rf).filter(CamelUser.col().displayName == "Alice").all()
                @Expect(users.size, 1)
                @Expect(users[0].displayName, "Alice")
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── I19: 宏写路径标识符方言感知引号化，驼峰实体 PG 可读可写 ───────────────────
    // 修复前：宏层写路径把裸表名/列名烘焙进编译期字符串，PG 折叠小写，tx.save/update/
    // delete 无法命中引号原样建出的驼峰表/列（I2 测试只能用引号 SQL 手工写入）。
    // 修复后：写路径 SQL 经 dialect.quoteIdentifier 生成，下面直接走 tx 写 API 端到端验证。

    @TestCase
    public func testCamelCaseWritePathRoundtrip(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"camelPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"camelUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([CamelUserSchema(), CamelPostSchema()])
                @Expect(m.hasTable("camelUser"), true)
                @Expect(m.hasTable("camelPost"), true)

                // save：驼峰表/列 INSERT 直接命中（此前此处需手工引号 SQL）
                let u = CamelUser()
                u.displayName = "Alice"
                rf.transaction { tx: Tx => tx.save(u) }
                @Expect(u.id > 0, true)
                let uid = u.id
                let p = CamelPost()
                p.title = "Post"
                p.authorId = uid
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)

                // 回读验证
                let found = CamelUser.query().using(rf).filter(CamelUser.col().id == uid).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().displayName, "Alice")
                let postFound = CamelPost.query().using(rf).filter(CamelPost.col().authorId == uid).one()
                @Expect(postFound.isSome(), true)
                @Expect(postFound.getOrThrow().title, "Post")

                // update：驼峰 SET / WHERE 列
                let up = found.getOrThrow()
                up.displayName = "Alice2"
                rf.transaction { tx: Tx => tx.update(up) }
                let afterUpdate = CamelUser.query().using(rf).filter(CamelUser.col().id == uid).one()
                @Expect(afterUpdate.isSome(), true)
                @Expect(afterUpdate.getOrThrow().displayName, "Alice2")

                // delete：驼峰 WHERE 主键
                rf.transaction { tx: Tx => tx.delete(afterUpdate.getOrThrow()) }
                let gone = CamelUser.query().using(rf).filter(CamelUser.col().id == uid).one()
                @Expect(gone.isNone(), true)

                // batchSave + batchUpdate：驼峰批量写路径（batchSave 不回填自增 id，经查询取回）
                let u2 = CamelUser(); u2.displayName = "B"
                let u3 = CamelUser(); u3.displayName = "C"
                rf.transaction { tx: Tx => tx.batchSave([u2, u3]) }
                let savedB = CamelUser.query().using(rf).filter(CamelUser.col().displayName == "B").one()
                let savedC = CamelUser.query().using(rf).filter(CamelUser.col().displayName == "C").one()
                @Expect(savedB.isSome() && savedC.isSome(), true)
                let b = savedB.getOrThrow()
                let c = savedC.getOrThrow()
                b.displayName = "B2"
                c.displayName = "C2"
                rf.transaction { tx: Tx => tx.batchUpdate([b, c]) }
                let all = CamelUser.query().using(rf).filter(CamelUser.col().id == b.id).all()
                @Expect(all.size, 1)
                @Expect(all[0].displayName, "B2")

                // 收尾（非软删实体 delete 即物理删除）
                rf.transaction { tx: Tx => tx.delete(b) }
                rf.transaction { tx: Tx => tx.delete(c) }
                rf.transaction { tx: Tx => tx.delete(postFound.getOrThrow()) }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── I2: include 保留别名大小写，批量 ref_to 装配按外键 IN 回填 ───────────────────
    // batch include Task 3：主查询后按 fk（authorId）IN 批量查询 camelUser 回填 authorProfile。
    @TestCase
    public func testCamelCaseIncludeRefTo(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"camelPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"camelUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([CamelUserSchema(), CamelPostSchema()])
                let userParams: Array<Any> = ["Alice"]
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"camelUser\" (\"displayName\") VALUES (?)", userParams) }
                let u = CamelUser.query().using(rf).filter(CamelUser.col().displayName == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                let postParams: Array<Any> = ["Post", uid]
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"camelPost\" (\"title\", \"authorId\") VALUES (?, ?)", postParams) }
                let found = CamelPost.query().include(CamelPostRel.authorProfile).using(rf).filter(CamelPost.col().authorId == uid).one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                @Expect(post.title, "Post")
                match (post.authorProfile) {
                    case Some(a) =>
                        @Expect(a.id, uid)
                        @Expect(a.displayName, "Alice")
                    case None => @Expect(true, false)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // batch include Task 3：authorId 指向不存在的用户时，批量 IN 查询无匹配
    // → authorProfile 保持 None、不崩溃（旧 LEFT JOIN 目标侧全 NULL 路径已移除）。
    @TestCase
    public func testCamelCaseIncludeRefToNullAuthorNoCrash(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"camelPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"camelUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([CamelUserSchema(), CamelPostSchema()])
                // authorId=999999 无对应 camelUser → 批量查询空结果
                let postParams: Array<Any> = ["OrphanPost", 999999]
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"camelPost\" (\"title\", \"authorId\") VALUES (?, ?)", postParams) }
                let found = CamelPost.query().include(CamelPostRel.authorProfile).using(rf).filter(CamelPost.col().title == "OrphanPost").one()
                @Expect(found.isSome(), true)
                let post = found.getOrThrow()
                @Expect(post.title, "OrphanPost")
                @Expect(post.authorId, 999999)
                @Expect(post.authorProfile.isNone(), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── batch include Task 5：ref_many junction 批量装配（真实 PG） ───────────────────
    // CustomTagPost(@Table custom_tag_posts) → CustomTag(@Table custom_tags) via custom_post_tags。
    // 中间表列名验证：源列 custom_tag_posts_id、目标列 customTag_id——@Table 覆盖目标表名
    // 时目标列仍基于目标「类名」（customTag_id 而非 custom_tags_id），装配 SQL 必须命中前者。
    // 中间表行用带引号的 raw INSERT 写入（读路径不依赖宏层写路径）。
    @TestCase
    public func testRefManyIncludeAssembles(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"custom_post_tags\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"custom_tag_posts\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"custom_tags\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([CustomTagSchema(), CustomTagPostSchema(), CustomTagPost_TagsJunctionSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"custom_tags\" (\"name\") VALUES (?)", ["red"]) }
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"custom_tags\" (\"name\") VALUES (?)", ["blue"]) }
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"custom_tag_posts\" (\"title\") VALUES (?)", ["p1"]) }
                let post = CustomTagPost.query().using(rf).filter(CustomTagPost.col().title == "p1").one()
                @Expect(post.isSome(), true)
                let p = post.getOrThrow()
                let tagAll = CustomTag.query().using(rf).all()
                @Expect(tagAll.size, 2)
                // post 关联两个真实 tag + 一个孤儿中间表行（指向不存在 tag id 999999）
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"custom_post_tags\" (\"custom_tag_posts_id\", \"customTag_id\") VALUES (?, ?)", [p.id, tagAll[0].id])
                    tx.execute("INSERT INTO \"custom_post_tags\" (\"custom_tag_posts_id\", \"customTag_id\") VALUES (?, ?)", [p.id, tagAll[1].id])
                    tx.execute("INSERT INTO \"custom_post_tags\" (\"custom_tag_posts_id\", \"customTag_id\") VALUES (?, ?)", [p.id, 999999])
                }
                let found = CustomTagPost.query().include(CustomTagPostRel.tags).using(rf).filter(CustomTagPost.col().title == "p1").one()
                @Expect(found.isSome(), true)
                let fp = found.getOrThrow()
                // 孤儿行被 INNER JOIN 跳过，只装配 2 个真实 tag
                @Expect(fp.tags.size, 2)
                let names = [fp.tags[0].name, fp.tags[1].name]
                @Expect(names.contains("red") && names.contains("blue"), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── batch include Task 6：嵌套 include 递归装配（真实 PG） ───────────────────
    // NestedPost.author（ref_to NestedUser）withInclude NestedUser.profile（has_one
    // NestedProfile）：主查询 + author 批量 + profile 批量三次查询，Post.author.profile
    // 逐级装配（嵌套层 profile 批量查询的 IN 主键集合来自 author 目标实体的 id）。
    @TestCase
    public func testNestedIncludeRefToThenHasOne(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"nestedSkill\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedComment\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedProfile\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedUser\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedPost\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([NestedPostSchema(), NestedUserSchema(), NestedProfileSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"nestedUser\" (\"name\") VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"nestedProfile\" (\"bio\", \"user_id\") VALUES (?, ?)", ["engineer", uid])
                    tx.execute("INSERT INTO \"nestedPost\" (\"title\", \"user_id\") VALUES (?, ?)", ["p1", uid])
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

    // ─── Task 7：includeAll 字符串点号路径端到端（真实 PG） ─────────────────────
    // includeAll(["author.profile"]) 与上方 withInclude 链等价：主查询 + author 批量 +
    // profile 批量三次查询，Post.author.profile 逐级装配。验证字符串路径 DSL 走真实
    // 批量装配路径（与 include(PostRel.author.withInclude(UserRel.profile)) 同一引擎）。
    @TestCase
    public func testIncludeAllStringPath(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"nestedSkill\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedComment\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedProfile\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedUser\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedPost\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([NestedPostSchema(), NestedUserSchema(), NestedProfileSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"nestedUser\" (\"name\") VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"nestedProfile\" (\"bio\", \"user_id\") VALUES (?, ?)", ["engineer", uid])
                    tx.execute("INSERT INTO \"nestedPost\" (\"title\", \"user_id\") VALUES (?, ?)", ["p1", uid])
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

    // ─── batch include Task 6：嵌套 ref_many junction 源列修正（真实 PG） ───────────
    // Post.author（ref_to NestedUser）withInclude NestedUser.tags（ref_many）。junction 源列
    // 必须是当前层级表 nestedUser_id（而非顶层 nestedPost_id）——修复前生成 "<顶层表>_id"
    // 在 PG 报 column does not exist，此处用真实 PG 验证嵌套 ref_many 端到端装配成功。
    @TestCase
    public func testNestedIncludeRefToThenRefMany(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"nestedUser_tags\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedTag\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([NestedPostSchema(), NestedUserSchema(), NestedTagSchema(), NestedUser_TagsJunctionSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"nestedUser\" (\"name\") VALUES (?)", ["Alice"]) }
                let u = NestedUser.query().using(rf).filter(NestedUser.col().name == "Alice").one()
                @Expect(u.isSome(), true)
                let uid = u.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"nestedTag\" (\"name\") VALUES (?)", ["t1"])
                    tx.execute("INSERT INTO \"nestedPost\" (\"title\", \"user_id\") VALUES (?, ?)", ["p1", uid])
                }
                let tag = NestedTag.query().using(rf).filter(NestedTag.col().name == "t1").one()
                @Expect(tag.isSome(), true)
                let tid = tag.getOrThrow().id
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"nestedUser_tags\" (\"nestedUser_id\", \"nestedTag_id\") VALUES (?, ?)", [uid, tid])
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

    // ─── Task 9：混合 has_many + ref_to include 无笛卡尔积（真实 PG） ─────────────
    // PostWithRel（postWithRel）同时 include author（ref_to "user"）与 comments
    // （has_many "comment"）。2 个主行 × 各 3 条评论，分步批量协议返回 2 行主实体
    // （而非 JOIN 展开的 6 行），每行带 3 条评论 + 装配好的 author。
    @TestCase
    public func testMixedHasManyRefToNoCartesian(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"comment\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"user\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"postWithRel\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([PostWithRelSchema(), UserSchema(), CommentSchema()])
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"user\" (\"name\", \"email\") VALUES (?, ?)", ["AuthorA", "a@x.com"])
                    tx.execute("INSERT INTO \"user\" (\"name\", \"email\") VALUES (?, ?)", ["AuthorB", "b@x.com"])
                }
                let users = User.query().using(rf).order([User.col().id.asc()]).all()
                @Expect(users.size, 2)
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, 0)", ["p1", users[0].id])
                    tx.execute("INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, 0)", ["p2", users[1].id])
                }
                let posts = PostWithRel.query().using(rf).order([PostWithRel.col().id.asc()]).all()
                @Expect(posts.size, 2)
                rf.transaction { tx: Tx =>
                    for (i in 0..3) {
                        tx.execute("INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)", ["p1c" + i.toString(), posts[0].id])
                        tx.execute("INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)", ["p2c" + i.toString(), posts[1].id])
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

    // ─── Task 9：同表多 ref 合并（真实 PG） ─────────────────────────────────────
    // SameTableRefPost 的 author/editor 两个 ref_to 指向同一目标表 sameTableRefUser，
    // 批量 include 合并为单条批量查询（查询次数在单元层用 mock 断言）并分别回填，
    // 此处验证真实 PG 上两个 ref 都正确装配。
    @TestCase
    public func testSameTableRefsBothPopulate(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"sameTableRefPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"sameTableRefUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([SameTableRefPostSchema(), SameTableRefUserSchema()])
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"sameTableRefUser\" (\"name\", \"email\") VALUES (?, ?)", ["Alice", "a@x.com"])
                    tx.execute("INSERT INTO \"sameTableRefUser\" (\"name\", \"email\") VALUES (?, ?)", ["Eve", "e@x.com"])
                }
                let users = SameTableRefUser.query().using(rf).order([SameTableRefUser.col().id.asc()]).all()
                @Expect(users.size, 2)
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"sameTableRefPost\" (\"title\", \"author_id\", \"editor_id\") VALUES (?, ?, ?)", ["t1", users[0].id, users[1].id])
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

    // ─── Task 9：page + has_many include（真实 PG） ─────────────────────────────
    // page() 的 count + 主查询 LIMIT/OFFSET + 批量 IN 三次查询协议，total 为父实体数、
    // 每项带全部评论（LIMIT/OFFSET 作用于源表行，不按子行展开）。
    @TestCase
    public func testPageWithHasManyInclude(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"nestedComment\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([NestedUserSchema(), NestedCommentSchema()])
                rf.transaction { tx: Tx =>
                    tx.execute("INSERT INTO \"nestedUser\" (\"name\") VALUES (?)", ["U1"])
                    tx.execute("INSERT INTO \"nestedUser\" (\"name\") VALUES (?)", ["U2"])
                }
                let users = NestedUser.query().using(rf).order([NestedUser.col().id.asc()]).all()
                @Expect(users.size, 2)
                rf.transaction { tx: Tx =>
                    for (i in 0..3) {
                        tx.execute("INSERT INTO \"nestedComment\" (\"body\", \"user_id\") VALUES (?, ?)", ["u1c" + i.toString(), users[0].id])
                        tx.execute("INSERT INTO \"nestedComment\" (\"body\", \"user_id\") VALUES (?, ?)", ["u2c" + i.toString(), users[1].id])
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

    // ─── Task 9：空关联（真实 PG） ─────────────────────────────────────────────
    // 主实体无任何子对象 → 批量查询命中 0 行，comments 保持空列表、不抛异常。
    @TestCase
    public func testEmptyHasManyRelation(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"nestedComment\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"nestedUser\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([NestedUserSchema(), NestedCommentSchema()])
                rf.transaction { tx: Tx => tx.execute("INSERT INTO \"nestedUser\" (\"name\") VALUES (?)", ["Lonely"]) }
                let found = NestedUser.query().include(NestedUserRel.comments).using(rf).filter(NestedUser.col().name == "Lonely").one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().comments.size, 0)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── I20: RETURNING 自增主键列引号化（真实 PG） ─────────────────────────────
    // 驼峰自增主键列 postId（表 camelAutoPkPost 建表时引号原样保留）。save 的
    // RETURNING 若未引号化则折叠为 postid 找不到列；引号化后能回填实体主键。
    @TestCase
    public func testCamelCaseAutoPkSaveReturningQuoted(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS \"camelAutoPkPost\"", []) }
                let m = rf.migrator()
                m.autoMigrate([CamelAutoPkPostSchema()])
                let p = CamelAutoPkPost()
                p.title = "ret"
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.postId > 0, true)
                let found = CamelAutoPkPost.query().using(rf).filter(CamelAutoPkPost.col().postId == p.postId).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().title, "ret")
                rf.transaction { tx: Tx => tx.delete(found.getOrThrow()) }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── I21: junction 写路径标识符引号化（真实 PG） ─────────────────────────────
    // 驼峰 via 表 camelViaPostTags + 驼峰源列 camelViaPost_id：append/delete/clear/count
    // 走宏生成实体方法，SQL 运行时经 tx.getDialect().quoteIdentifier 引号化，
    // 与建表时引号原样保留的标识符一致，PG 可正常读写。
    @TestCase
    public func testCamelViaJunctionWriteRoundtrip(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"camelViaPostTags\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"camelViaPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"tag\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([CamelViaPostSchema(), TagSchema(), CamelViaPost_TagsJunctionSchema()])
                let p = CamelViaPost()
                p.title = "via"
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)
                let t1 = Tag(); t1.name = "t1"
                let t2 = Tag(); t2.name = "t2"
                rf.transaction { tx: Tx =>
                    tx.save(t1)
                    tx.save(t2)
                }
                rf.transaction { tx: Tx => p.appendTags(tx, [t1, t2]) }
                rf.transaction { tx: Tx => @Expect(p.countTags(tx), 2) }
                let loaded = rf.transaction { tx: Tx => p.loadTags(tx) }
                @Expect(loaded.size, 2)
                rf.transaction { tx: Tx => p.deleteTags(tx, t1) }
                rf.transaction { tx: Tx => @Expect(p.countTags(tx), 1) }
                rf.transaction { tx: Tx => p.clearTags(tx) }
                rf.transaction { tx: Tx => @Expect(p.countTags(tx), 0) }
                rf.transaction { tx: Tx =>
                    tx.delete(t1)
                    tx.delete(t2)
                    tx.delete(p)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── F1: junction schema 源列类型跟随源主键（真实 PG） ─────────────────────────
    // StringKeyPost 主键 String → junction 源列 stringKeyPost_id 建为 VARCHAR(255)，
    // 目标列 tag_id（Tag 主键 Int64）为 BIGINT。String 源 id 可经 appendTags 写入
    // VARCHAR 列并回读，验证 String-pk 源 junction 真实可读写（此前硬编码 Integer
    // 导致源列 BIGINT，String id 写入即报错）。
    @TestCase
    public func testStringPkSourceJunctionRoundtrip(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"string_key_post_tags\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"stringKeyPost\"", [])
                    tx.execute("DROP TABLE IF EXISTS \"tag\"", [])
                }
                let m = rf.migrator()
                m.autoMigrate([StringKeyPostSchema(), TagSchema(), StringKeyPost_TagsJunctionSchema()])
                let p = StringKeyPost()
                p.id = "skp-1"
                p.title = "skp"
                let t = Tag(); t.name = "tag-1"
                rf.transaction { tx: Tx =>
                    tx.save(p)
                    tx.save(t)
                }
                rf.transaction { tx: Tx => p.appendTags(tx, t) }
                rf.transaction { tx: Tx => @Expect(p.countTags(tx), 1) }
                let loaded = rf.transaction { tx: Tx => p.loadTags(tx) }
                @Expect(loaded.size, 1)
                @Expect(loaded[0].name, "tag-1")
                rf.transaction { tx: Tx =>
                    tx.delete(t)
                    tx.delete(p)
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── R-C1: PG versioned upsert 非法 SQL 回归（真实 PG） ─────────────────────
    // 修复前 PG 方言 versionCol 分支生成 `"versionedPost"."version" = "versionedPost"."version" + 1`，
    // PG 17 报 "SET target columns cannot be qualified with the relation name"（DO UPDATE SET 的
    // LHS 目标列不允许表限定；RHS 裸列名同样有歧义）。修复后 LHS 裸列名、RHS 表限定：
    // `"version" = "versionedPost"."version" + 1`。
    // 真实 PG 链路：save 插入（version=1）→ 同主键 upsert 冲突 → DB 版本自增为 2，不报错。
    @TestCase
    public func testVersionedUpsertIncrementsVersion(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"versionedPost\"", [])
                }
                rf.migrator().autoMigrate([VersionedPostSchema()])
                let p = VersionedPost()
                p.title = "v1"
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.version, 1)
                let pid = p.id
                @Expect(pid > 0, true)
                rf.transaction { tx: Tx => tx.upsert(p) }
                let found = VersionedPost.query().using(rf).filter(VersionedPost.col().id == pid).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().version, 2)
                rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS \"versionedPost\"", []) }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── R-C1 补充：非 versioned 实体 PG upsert 冲突更新（此前无任何真实 PG upsert 覆盖） ──
    // save 插入后改值再 upsert 同主键 → ON CONFLICT DO UPDATE 命中，title/content 被刷新，
    // 行数不增长（此前 PG 的 upsert 只有 mock/dialect 层断言，无真实数据库验证）。
    @TestCase
    public func testPlainUpsertUpdatesOnConflict(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgpost\"", [])
                }
                rf.migrator().autoMigrate([PgPostSchema()])
                let p = PgPost()
                p.title = "a"
                p.content = "c1"
                rf.transaction { tx: Tx => tx.save(p) }
                let pid = p.id
                @Expect(pid > 0, true)
                p.title = "b"
                p.content = "c2"
                rf.transaction { tx: Tx => tx.upsert(p) }
                let found = PgPost.query().using(rf).filter(PgPost.col().id == pid).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().title, "b")
                @Expect(found.getOrThrow().content, "c2")
                let all = PgPost.query().using(rf).all()
                @Expect(all.size, 1)
                rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS \"pgpost\"", []) }
                rf.close()
            case None => @Expect(true, true)
        }
    }
}
