package refine

import std.time.DateTime
import std.math.numeric.Decimal
import std.unittest.*
import std.unittest.testmacro.*
import refine.macros.*
import mariadb.cdbc.*

// R-M19: 真实 MariaDB 服务器集成测试（refine-mariadb-test 容器，端口 3307）。
// mariadb 驱动连 MariaDB 时，Refine.open 运行时探测（SELECT VERSION()）应识别为
// MariaDBDialect，且 upsert 生成 MariaDB 合法的 VALUES(col) 老语法（非 MySQL 的 AS new）。
func tryMariaDB(): Option<Refine> {
    try {
        Some(Refine.open("mariadb://127.0.0.1:3307", [
            ("username", "root"),
            ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
            ("database", "refine_test")
        ]))
    } catch (_: Exception) {
        None
    }
}

@Test
public class MariaDBIntegrationTest {

    // 环境守卫验证：容器不在时 tryMariaDB 返回 None，测试跳过（@Expect(true, true) 占位）。
    // 容器在时断言探测结果与 paramOffset。
    @TestCase
    public func testDetectServerDialectRealMariaDB(): Unit {
        match (tryMariaDB()) {
            case Some(rf) =>
                @Expect(rf.getDialect().name(), "mariadb")
                @Expect(rf.getParamOffset(), 1)
                // 复用继承 MySQLDialect 的 migrator（MySQLMigrator）验证建表链路
                @Expect(rf.migrator().hasTable("information_schema.TABLES"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // R-M19: plain upsert roundtrip——save 插入 → 改值 upsert 同主键 → DO UPDATE SET 命中，
    // title/content 被 VALUES(col) 刷新、行数不增长。MariaDB 不识别 AS new，此用例验证
    // 修复前会抛 ERROR 1064 的路径现在走 VALUES(col) 老语法正常执行。
    @TestCase
    public func testPlainUpsertUpdatesOnConflict(): Unit {
        match (tryMariaDB()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `post`", [])
                }
                rf.migrator().autoMigrate([PostSchema()])
                let p = Post()
                p.title = "a"
                p.content = "c1"
                rf.transaction { tx: Tx => tx.save(p) }
                let pid = p.id
                @Expect(pid > 0, true)
                p.title = "b"
                p.content = "c2"
                rf.transaction { tx: Tx => tx.upsert(p) }
                let found = Post.query().using(rf).filter(Post.col().title == "b").one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().content, "c2")
                let all = Post.query().using(rf).all()
                @Expect(all.size, 1)
                rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS `post`", []) }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // R-M19: versioned upsert——冲突时 version 列 `VALUES(version) + 1` 自增（MariaDB 老语法）。
    // save 后 version=1，upsert 冲突 → version 变 2。真实 MariaDB 验证 VALUES(version)+1
    // 语义与 MySQL 的 new.col 等价（方案 R-M19 标注"需真实 MariaDB 验证"的点）。
    @TestCase
    public func testVersionedUpsertIncrementsVersion(): Unit {
        match (tryMariaDB()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `versionedPost`", [])
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
                rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS `versionedPost`", []) }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── Decimal 字段真实 MariaDB 端到端 ────────────────────────────
    // mariadb 驱动 set Decimal（原生类型）→ DECIMAL(65,30) 列 → getDecimal 读回。
    // 与 MySQL 版同构链路，验证 MariaDB 服务器下的精度保留与 Option<Decimal> None/Some。
    @TestCase
    public func testDecimalRoundtrip(): Unit {
        match (tryMariaDB()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `decimalproduct`", [])
                    tx.execute("DROP TABLE IF EXISTS `decimaldiscount`", [])
                }
                rf.migrator().autoMigrate([DecimalProductSchema(), DecimalDiscountSchema()])
                let p = DecimalProduct()
                p.name = "p1"
                p.price = Decimal.parse("12345.6789")
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)
                let back = DecimalProduct.query().using(rf).filter(DecimalProduct.col().id == p.id).one()
                @Expect(back.isSome(), true)
                @Expect(back.getOrThrow().name, "p1")
                @Expect(back.getOrThrow().price == Decimal.parse("12345.6789"), true)
                let gt = DecimalProduct.query().using(rf).filter(DecimalProduct.col().price > Decimal.parse("10.5")).all()
                @Expect(gt.size, 1)
                @Expect(gt[0].name, "p1")
                let d1 = DecimalDiscount()
                d1.name = "d1"
                rf.transaction { tx: Tx => tx.save(d1) }
                @Expect(d1.id > 0, true)
                let bd1 = DecimalDiscount.query().using(rf).filter(DecimalDiscount.col().id == d1.id).one()
                @Expect(bd1.isSome(), true)
                @Expect(bd1.getOrThrow().discount.isNone(), true)
                let d2 = DecimalDiscount()
                d2.name = "d2"
                d2.discount = Some(Decimal.parse("9.5"))
                rf.transaction { tx: Tx => tx.save(d2) }
                @Expect(d2.id > 0, true)
                let bd2 = DecimalDiscount.query().using(rf).filter(DecimalDiscount.col().id == d2.id).one()
                @Expect(bd2.isSome(), true)
                @Expect(bd2.getOrThrow().discount.isSome(), true)
                @Expect(bd2.getOrThrow().discount.getOrThrow() == Decimal.parse("9.5"), true)
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `decimalproduct`", [])
                    tx.execute("DROP TABLE IF EXISTS `decimaldiscount`", [])
                }
                rf.close()
            case None => @Expect(true, true)
        }
    }

    // ─── Task 6: snake 命名策略真实 DB roundtrip（真实 MariaDB） ───────────────────
    // SnakePost/SnakeAuthor/SnakeComment 端到端：autoMigrate 建 snake 表 →
    // save（snake 列名 INSERT）→ query 读回（rowMapper snake 键）→ include 关系
    // 装配（r.by author_id/post_id）→ ref_many junction 写读（related_authors）。
    @TestCase
    public func testSnakeNamingRoundtrip(): Unit {
        match (tryMariaDB()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS `related_authors`", [])
                    tx.execute("DROP TABLE IF EXISTS `snake_comment`", [])
                    tx.execute("DROP TABLE IF EXISTS `snake_author`", [])
                    tx.execute("DROP TABLE IF EXISTS `snake_post`", [])
                }
                let m = rf.migrator()
                m.autoMigrate([SnakePostSchema(), SnakeAuthorSchema(), SnakeCommentSchema(), SnakePost_RelatedAuthorsJunctionSchema()])
                @Expect(m.hasTable("snake_post"), true)
                @Expect(m.hasTable("related_authors"), true)

                // save：snake 列名 INSERT（display_name / author_id / post_id）
                let a = SnakeAuthor()
                a.displayName = "Alice"
                rf.transaction { tx: Tx => tx.save(a) }
                @Expect(a.id > 0, true)
                let p = SnakePost()
                p.title = "snake-title"
                p.authorId = a.id
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)
                let c = SnakeComment()
                c.body = "snake-comment"
                c.postId = p.id
                rf.transaction { tx: Tx => tx.save(c) }
                @Expect(c.id > 0, true)

                // query 读回：rowMapper 用 snake 键映射回实体字段
                let found = SnakePost.query().using(rf).filter(SnakePost.col().title == "snake-title").one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().title, "snake-title")
                @Expect(found.getOrThrow().authorId, a.id)

                // include 关系装配：r.by snake 列（author_id / post_id）
                let withRel = SnakePost.query()
                    .include(SnakePostRel.author)
                    .include(SnakePostRel.comments)
                    .using(rf)
                    .filter(SnakePost.col().title == "snake-title")
                    .one()
                @Expect(withRel.isSome(), true)
                let fp = withRel.getOrThrow()
                match (fp.author) {
                    case Some(auth) =>
                        @Expect(auth.id, a.id)
                        @Expect(auth.displayName, "Alice")
                    case None => @Expect(true, false)
                }
                @Expect(fp.comments.size, 1)
                @Expect(fp.comments[0].body, "snake-comment")
                @Expect(fp.comments[0].postId, p.id)

                // ref_many junction snake 写读：appendRelatedAuthors → loadRelatedAuthors
                rf.transaction { tx: Tx => fp.appendRelatedAuthors(tx, a) }
                rf.transaction { tx: Tx => @Expect(fp.countRelatedAuthors(tx), 1) }
                let loaded = rf.transaction { tx: Tx => fp.loadRelatedAuthors(tx) }
                @Expect(loaded.size, 1)
                @Expect(loaded[0].id, a.id)
                @Expect(loaded[0].displayName, "Alice")

                rf.close()
            case None => @Expect(true, true)
        }
    }
}
