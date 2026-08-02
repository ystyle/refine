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

    // ─── I2: include 别名保留大小写，stripPrefix 按原大小写匹配到关系字段 ───────────────────

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
}
