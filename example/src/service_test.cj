package demo

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.time.DateTime
import refine.*
import mariadb.cdbc.*
import pgsql.*

// ─── 数据库连接工厂 ──────────────────────────────────────

func openMySQL(): Refine {
    Refine.open("mariadb://127.0.0.1:3306", [
        ("username", "root"),
        ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
        ("database", "refine_test")
    ])
}

func openPostgres(): Refine {
    Refine.open("postgres://127.0.0.1:5432", [
        ("username", "postgres"),
        ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
        ("database", "refine_test"),
        ("sslmode", "disable")
    ])
}

// ─── 共享测试基础设施（每库各初始化一次） ─────────────────

var seq: Int64 = 0

func uid(): String { seq++; seq.toString() }

func initOnce(rf: Refine): Unit {
    let schemas: Array<TableSchema> = [UserSchema(), ProfileSchema(), PostSchema(), CommentSchema(), TagSchema(), EventSchema(), AuditNoteSchema()]
    // 每次测试先清空重建，避免残留数据/旧结构干扰
    let m = rf.migrator()
    for (schema in schemas) {
        m.dropTable(schema)
    }
    rf.transaction { tx: Tx =>
        tx.execute("DROP TABLE IF EXISTS post_tags", [])
        // junction 表需要通过原始 SQL 创建（框架不自动管理 junction 表）
        tx.execute("CREATE TABLE IF NOT EXISTS post_tags (post_id BIGINT NOT NULL, tag_id BIGINT NOT NULL)", [])
    }
    m.autoMigrate(schemas)
    rf.hook<User>("User", HookKind.TxBeforeCreate) { scope: Scope<User> =>
        if (scope.entity.name == "") {
            scope.abort(Exception("name required"))
        }
    }
}

func isValidUlid(id: String): Bool {
    if (id.size != 26) { return false }
    let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    for (i in 0..id.size) {
        var found = false
        for (c in alphabet) {
            if (id[i] == c) { found = true; break }
        }
        if (!found) { return false }
    }
    true
}

// ─── 共享断言（同一套测试在 MySQL / PostgreSQL 各跑一遍） ──

class ServiceChecks {

    // ─── UserService ──────────────────────────────────

    static func register(rf: Refine): Unit {
        let name = "Reg_" + uid()
        let user = UserService.register(rf, name, "reg@t.com")
        @Expect(user.id > 0, true)
        @Expect(user.name, name)
    }

    static func registerEmptyName(rf: Refine): Unit {
        try {
            UserService.register(rf, "", "bad@t.com")
            @Fail("expected Hook abort")
        } catch (_: Exception) {
            @Expect(true, true)
        }
    }

    static func findByEmail(rf: Refine): Unit {
        let name = "Email_" + uid()
        UserService.register(rf, name, name + "@t.com")
        var p = UserFind()
        p.email = Some(name + "@t.com")
        let found = UserRepo.findOne(rf, p)
        @Expect(found.isSome(), true)
        @Expect(found.getOrThrow().email, name + "@t.com")
    }

    static func searchByLike(rf: Refine): Unit {
        let suffix = uid()
        let name = "Like_" + suffix
        UserService.register(rf, name, name + "@t.com")
        var p = UserFind()
        p.nameLike = Some(suffix)
        @Expect(UserRepo.find(rf, p).size > 0, true)
    }

    static func updateEmail(rf: Refine): Unit {
        let name = "Upd_" + uid()
        UserService.register(rf, name, name + "@t.com")
        var p = UserFind()
        p.email = Some(name + "@t.com")
        let u = UserRepo.findOne(rf, p).getOrThrow()
        UserService.updateEmail(rf, u.id, "new_mail@t.com")
        p = UserFind()
        p.id = Some(u.id)
        @Expect(UserRepo.findOne(rf, p).getOrThrow().email, "new_mail@t.com")
    }

    static func preloadPosts(rf: Refine): Unit {
        let name = "Preload_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        PostService.create(rf, "P1", "B1", user.id)
        PostService.create(rf, "P2", "B2", user.id)
        let loaded = UserService.getWithPosts(rf, user.id)
        @Expect(loaded.isSome(), true)
        @Expect(loaded.getOrThrow().posts.size, 2)
    }

    static func deleteUser(rf: Refine): Unit {
        let name = "Del_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        UserService.deleteUser(rf, user.id)
        var p = UserFind()
        p.id = Some(user.id)
        @Expect(UserRepo.findOne(rf, p).isNone(), true)
    }

    static func nestedRollback(rf: Refine): Unit {
        let name = "Nest_" + uid()
        UserService.nestedRollback(rf, name)
        var p = UserFind()
        p.email = Some(name + "_rollbacked@t.com")
        @Expect(UserRepo.findOne(rf, p).isNone(), true)
        p = UserFind()
        p.email = Some(name + "@t.com")
        @Expect(UserRepo.findOne(rf, p).isSome(), true)
    }

    // ─── PostService ──────────────────────────────────

    static func createPost(rf: Refine): Unit {
        let name = "Auth_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        let post = PostService.create(rf, "Hello", "World", author.id)
        @Expect(post.id > 0, true)
        @Expect(post.title, "Hello")
    }

    static func preloadDetails(rf: Refine): Unit {
        let name = "Detail_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        let post = PostService.create(rf, "DP", "DB", author.id)
        PostService.addComment(rf, post.id, "C1")
        PostService.addComment(rf, post.id, "C2")
        PostService.addTags(rf, post.id, ["refine", "orm", "cangjie"])

        let loaded = PostService.getDetails(rf, post.id)
        @Expect(loaded.isSome(), true)
        @Expect(loaded.getOrThrow().author.getOrThrow().name, name)
        @Expect(loaded.getOrThrow().comments.size, 2)
        @Expect(loaded.getOrThrow().tags.size, 3)
    }

    static func findRecent(rf: Refine): Unit {
        let name = "Recent_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        for (i in 0..5) { PostService.create(rf, "R" + i.toString(), "B", author.id) }
        var p = PostFind()
        p.userId = Some(author.id)
        p.orderBy = Some("id")
        p.asc = false
        p.limit = Some(3)
        @Expect(PostRepo.find(rf, p).size, 3)
    }

    static func searchPosts(rf: Refine): Unit {
        let name = "Kw_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        PostService.create(rf, "AlphaPost", "BodyA", author.id)
        PostService.create(rf, "BetaPost", "BodyB", author.id)
        var p = PostFind()
        p.keyword = Some("Alpha")
        @Expect(PostRepo.find(rf, p).size > 0, true)
    }

    // ─── ProfileService ───────────────────────────────

    static func setProfile(rf: Refine): Unit {
        let name = "Pro_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        ProfileService.setProfile(rf, user.id, "MyBio", "avatar.png")
        let profile = ProfileRepo.findByUserId(rf, user.id)
        @Expect(profile.isSome(), true)
        @Expect(profile.getOrThrow().bio, "MyBio")
    }

    // ─── Aggregation ──────────────────────────────────

    static func countExists(rf: Refine): Unit {
        let name = "Ex_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        let post = PostService.create(rf, "Ex", "B", user.id)
        @Expect(PostService.existsById(rf, post.id), true)
        @Expect(!PostService.existsById(rf, -999), true)
        @Expect(PostService.countAll(rf) >= 0, true)
        @Expect(UserRepo.countAll(rf) > 0, true)
    }

    // ─── ULID / String Id ─────────────────────────────

    static func ulidSaveAutoGenerate(rf: Refine): Unit {
        rf.setIdGenerator(UlidIdGenerator())
        let ev = Event()
        ev.name = "deploy"
        ev.payload = "v1.2.3"
        rf.transaction { tx: Tx => EventRepo.save(tx, ev) }
        @Expect(isValidUlid(ev.id), true)
        var p = EventFind()
        p.id = Some(ev.id)
        let found = EventRepo.findOne(rf, p)
        @Expect(found.isSome(), true)
        @Expect(found.getOrThrow().name, "deploy")
        @Expect(found.getOrThrow().payload, "v1.2.3")
    }

    static func ulidSaveCustomId(rf: Refine): Unit {
        rf.setIdGenerator(UlidIdGenerator())
        let customId = "evt-custom-" + UlidIdGenerator().generate()
        let ev = Event()
        ev.id = customId
        ev.name = "manual"
        rf.transaction { tx: Tx => EventRepo.save(tx, ev) }
        @Expect(ev.id, customId)
        var p = EventFind()
        p.id = Some(customId)
        @Expect(EventRepo.findOne(rf, p).isSome(), true)
    }

    static func aggregateFunctions(rf: Refine): Unit {
        initOnce(rf)
        let name = "Agg_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        for (i in 0..5) { PostService.create(rf, "A" + i.toString(), "B", author.id) }
        let total = Post.query().using(rf).filter(Post.col().user_id == author.id).sum(Post.col().id)
        @Expect(total > 0, true)
        let maxId = Post.query().using(rf).filter(Post.col().user_id == author.id).max(Post.col().id)
        @Expect(maxId > 0, true)
        let cnt = Post.query().using(rf).filter(Post.col().user_id == author.id).count()
        @Expect(cnt, 5)
    }

    static func pageQuery(rf: Refine): Unit {
        initOnce(rf)
        let name = "Page_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        for (i in 0..7) { PostService.create(rf, "P" + i.toString(), "B", author.id) }
        let pg = Post.query().using(rf)
            .filter(Post.col().user_id == author.id)
            .order([Post.col().id.asc()])
            .page(2, 3)
        @Expect(pg.total, 7)
        @Expect(pg.items.size, 3)
        @Expect(pg.totalPages(), 3)
        @Expect(pg.hasNext(), true)
        let last = Post.query().using(rf)
            .filter(Post.col().user_id == author.id)
            .page(3, 3)
        @Expect(last.items.size, 1)
    }

    static func updateWhereDeleteWhere(rf: Refine): Unit {
        initOnce(rf)
        let name = "Uw_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        for (i in 0..3) { PostService.create(rf, "U" + i.toString(), "B", author.id) }
        let updated = Post.query().using(rf)
            .filter(Post.col().user_id == author.id)
            .updateWhere(["title"], ["UPDATED"])
        @Expect(updated, 3)
        let all = Post.query().using(rf).filter(Post.col().user_id == author.id).all()
        for (p in all) { @Expect(p.title, "UPDATED") }
        let deleted = Post.query().using(rf)
            .filter(Post.col().user_id == author.id)
            .deleteWhere()
        @Expect(deleted, 3)
        @Expect(Post.query().using(rf).filter(Post.col().user_id == author.id).count(), 0)
    }

    static func forUpdateQuery(rf: Refine): Unit {
        initOnce(rf)
        let name = "Lock_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        PostService.create(rf, "L1", "B", author.id)
        rf.transaction { tx: Tx =>
            let found = Post.query().using(tx)
                .filter(Post.col().user_id == author.id)
                .forUpdate()
                .all()
            @Expect(found.size, 1)
        }
    }

    static func batchUpdateDifferentValues(rf: Refine): Unit {
        initOnce(rf)
        let name = "BatchUpd_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        let p1 = PostService.create(rf, "BU1", "B1", author.id)
        let p2 = PostService.create(rf, "BU2", "B2", author.id)
        p1.title = "BU1-UPDATED"
        p2.title = "BU2-UPDATED"
        rf.transaction { tx: Tx => tx.batchUpdate([p1, p2]) }
        let all = Post.query().using(rf).filter(Post.col().id.anyOf([p1.id, p2.id])).all()
        @Expect(all.size, 2)
        var titles = ArrayList<String>()
        for (p in all) { titles.add(p.title) }
        @Expect(titles.contains("BU1-UPDATED"), true)
        @Expect(titles.contains("BU2-UPDATED"), true)
    }

    static func upsertInsertAndUpdate(rf: Refine): Unit {
        initOnce(rf)
        rf.setIdGenerator(UlidIdGenerator())
        // 首次 upsert = 插入
        let ev = Event()
        ev.id = "evt-upsert-" + UlidIdGenerator().generate()
        ev.name = "first"
        ev.payload = "v1"
        rf.transaction { tx: Tx => tx.upsert(ev) }
        var p = EventFind()
        p.id = Some(ev.id)
        @Expect(EventRepo.findOne(rf, p).isSome(), true)
        @Expect(EventRepo.findOne(rf, p).getOrThrow().payload, "v1")
        // 再次 upsert 同 id = 更新（不产生重复行）
        ev.payload = "v2"
        rf.transaction { tx: Tx => tx.upsert(ev) }
        let all = Event.query().using(rf).filter(Event.col().id == ev.id).all()
        @Expect(all.size, 1)
        @Expect(all[0].payload, "v2")
    }

    static func ulidUpdateDelete(rf: Refine): Unit {
        rf.setIdGenerator(UlidIdGenerator())
        let ev = Event()
        ev.name = "before"
        rf.transaction { tx: Tx => EventRepo.save(tx, ev) }
        ev.name = "after"
        rf.transaction { tx: Tx => EventRepo.update(tx, ev) }
        var p = EventFind()
        p.id = Some(ev.id)
        @Expect(EventRepo.findOne(rf, p).getOrThrow().name, "after")
        rf.transaction { tx: Tx => EventRepo.delete(tx, ev) }
        @Expect(EventRepo.findOne(rf, p).isNone(), true)
    }

    // ─── 乐观锁 / 审计字段 / 隔离级别 ──────────────────

    static func auditFieldsFilled(rf: Refine): Unit {
        let note = AuditNote()
        note.title = "AF_" + uid()
        rf.transaction { tx: Tx => tx.save(note) }
        @Expect(note.id > 0, true)
        @Expect(note.version, 1)
        @Expect(note.created_at > DateTime.UnixEpoch, true)
        @Expect(note.updated_at > DateTime.UnixEpoch, true)
        // 回读确认审计字段已持久化
        let found = AuditNote.query().using(rf).filter(AuditNote.col().id == note.id).one().getOrThrow()
        @Expect(found.created_at > DateTime.UnixEpoch, true)
        @Expect(found.updated_at > DateTime.UnixEpoch, true)
        @Expect(found.version, 1)
    }

    static func auditFieldsOnUpdate(rf: Refine): Unit {
        let note = AuditNote()
        note.title = "AU_" + uid()
        rf.transaction { tx: Tx => tx.save(note) }
        @Expect(note.version, 1)
        note.title = "AU_" + uid() + "_upd"
        rf.transaction { tx: Tx => tx.update(note) }
        // version 递增为主断言；updated_at 通过 DB 回读断言未回退
        @Expect(note.version, 2)
        let found = AuditNote.query().using(rf).filter(AuditNote.col().id == note.id).one().getOrThrow()
        @Expect(found.version, 2)
        @Expect(found.title, note.title)
        @Expect(found.updated_at >= found.created_at, true)
    }

    static func optimisticLockConflict(rf: Refine): Unit {
        let note = AuditNote()
        note.title = "OL_" + uid()
        rf.transaction { tx: Tx => tx.save(note) }
        @Expect(note.version, 1)
        try {
            rf.transaction { tx: Tx =>
                let found = AuditNote.query().using(tx).filter(AuditNote.col().id == note.id).one().getOrThrow()
                // 模拟并发写：直接修改 DB 中的 version
                tx.execute("UPDATE audit_notes SET version = version + 1 WHERE id = ?", [found.id])
                found.title = "OL_" + uid() + "_conflict"
                tx.update(found)
            }
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.entityType, "AuditNote")
            @Expect(e.expected, 1)
        }
        // 事务回滚后 DB version 应仍为 1
        let after = AuditNote.query().using(rf).filter(AuditNote.col().id == note.id).one().getOrThrow()
        @Expect(after.version, 1)
    }

    static func optimisticLockSuccessPath(rf: Refine): Unit {
        let note = AuditNote()
        note.title = "OLS_" + uid()
        rf.transaction { tx: Tx => tx.save(note) }
        @Expect(note.version, 1)
        note.title = "OLS_" + uid() + "_upd"
        rf.transaction { tx: Tx => tx.update(note) }
        @Expect(note.version, 2)
        let found = AuditNote.query().using(rf).filter(AuditNote.col().id == note.id).one().getOrThrow()
        @Expect(found.version, 2)
        @Expect(found.title, note.title)
    }

    static func batchSaveAuditAndVersion(rf: Refine): Unit {
        let n1 = AuditNote()
        n1.title = "BS1_" + uid()
        let n2 = AuditNote()
        n2.title = "BS2_" + uid()
        rf.transaction { tx: Tx => tx.batchSave([n1, n2]) }
        @Expect(n1.version, 1)
        @Expect(n2.version, 1)
        @Expect(n1.created_at > DateTime.UnixEpoch, true)
        @Expect(n2.updated_at > DateTime.UnixEpoch, true)
        // batchSave 不回填自增 id，按 title 回读验证
        let all = AuditNote.query().using(rf).filter(AuditNote.col().title.anyOf([n1.title, n2.title])).all()
        @Expect(all.size, 2)
        for (n in all) {
            @Expect(n.version, 1)
            @Expect(n.created_at > DateTime.UnixEpoch, true)
        }
    }

    static func batchUpdateVersion(rf: Refine): Unit {
        let n1 = AuditNote()
        n1.title = "BU1_" + uid()
        rf.transaction { tx: Tx => tx.save(n1) }
        let n2 = AuditNote()
        n2.title = "BU2_" + uid()
        rf.transaction { tx: Tx => tx.save(n2) }
        @Expect(n1.version, 1)
        @Expect(n2.version, 1)
        n1.title = "BU1_" + uid() + "_upd"
        n2.title = "BU2_" + uid() + "_upd"
        // 关键验证：batchUpdate 不应误报冲突（rowCount == entities.size）
        rf.transaction { tx: Tx => tx.batchUpdate([n1, n2]) }
        @Expect(n1.version, 2)
        @Expect(n2.version, 2)
        let all = AuditNote.query().using(rf).filter(AuditNote.col().id.anyOf([n1.id, n2.id])).all()
        @Expect(all.size, 2)
        for (n in all) {
            @Expect(n.version, 2)
        }
    }

    static func isolationLevel(rf: Refine): Unit {
        let d = rf.getDialect().name()
        let note = AuditNote()
        note.title = "ISO_" + uid()
        rf.transaction(IsolationLevel.Serializable) { tx: Tx =>
            tx.save(note)
            if (d == "postgresql") {
                let qr = tx.query("SELECT current_setting('transaction_isolation')", [])
                if (qr.next()) {
                    @Expect(qr.get<String>(0 + rf.getParamOffset()), "serializable")
                }
                qr.close()
            } else {
                let qr = tx.query("SELECT @@transaction_isolation", [])
                if (qr.next()) {
                    @Expect(qr.get<String>(0 + rf.getParamOffset()), "SERIALIZABLE")
                }
                qr.close()
            }
        }
    }
}

// ─── MySQL 测试类 ───────────────────────────────────────

@Test
public class MySQLServiceTest {
    static let rf = openMySQL()

    @BeforeAll
    static func setup(): Unit { initOnce(rf) }

    @TestCase
    public func testRegister(): Unit { ServiceChecks.register(rf) }

    @TestCase
    public func testRegisterEmptyName(): Unit { ServiceChecks.registerEmptyName(rf) }

    @TestCase
    public func testFindByEmail(): Unit { ServiceChecks.findByEmail(rf) }

    @TestCase
    public func testSearchByLike(): Unit { ServiceChecks.searchByLike(rf) }

    @TestCase
    public func testUpdateEmail(): Unit { ServiceChecks.updateEmail(rf) }

    @TestCase
    public func testPreloadPosts(): Unit { ServiceChecks.preloadPosts(rf) }

    @TestCase
    public func testDeleteUser(): Unit { ServiceChecks.deleteUser(rf) }

    @TestCase
    public func testNestedRollback(): Unit { ServiceChecks.nestedRollback(rf) }

    @TestCase
    public func testCreatePost(): Unit { ServiceChecks.createPost(rf) }

    @TestCase
    public func testPreloadDetails(): Unit { ServiceChecks.preloadDetails(rf) }

    @TestCase
    public func testFindRecent(): Unit { ServiceChecks.findRecent(rf) }

    @TestCase
    public func testSearchPosts(): Unit { ServiceChecks.searchPosts(rf) }

    @TestCase
    public func testSetProfile(): Unit { ServiceChecks.setProfile(rf) }

    @TestCase
    public func testCountExists(): Unit { ServiceChecks.countExists(rf) }

    @TestCase
    public func testUlidSaveAutoGenerate(): Unit { ServiceChecks.ulidSaveAutoGenerate(rf) }

    @TestCase
    public func testUlidSaveCustomId(): Unit { ServiceChecks.ulidSaveCustomId(rf) }

    @TestCase
    public func testUlidUpdateDelete(): Unit { ServiceChecks.ulidUpdateDelete(rf) }

    @TestCase
    public func testUpsertInsertAndUpdate(): Unit { ServiceChecks.upsertInsertAndUpdate(rf) }

    @TestCase
    public func testBatchUpdateDifferentValues(): Unit { ServiceChecks.batchUpdateDifferentValues(rf) }

    @TestCase
    public func testAggregateFunctions(): Unit { ServiceChecks.aggregateFunctions(rf) }

    @TestCase
    public func testPageQuery(): Unit { ServiceChecks.pageQuery(rf) }

    @TestCase
    public func testUpdateWhereDeleteWhere(): Unit { ServiceChecks.updateWhereDeleteWhere(rf) }

    @TestCase
    public func testForUpdateQuery(): Unit { ServiceChecks.forUpdateQuery(rf) }

    @TestCase
    public func testAuditFieldsFilled(): Unit { ServiceChecks.auditFieldsFilled(rf) }

    @TestCase
    public func testAuditFieldsOnUpdate(): Unit { ServiceChecks.auditFieldsOnUpdate(rf) }

    @TestCase
    public func testOptimisticLockConflict(): Unit { ServiceChecks.optimisticLockConflict(rf) }

    @TestCase
    public func testOptimisticLockSuccessPath(): Unit { ServiceChecks.optimisticLockSuccessPath(rf) }

    @TestCase
    public func testBatchSaveAuditAndVersion(): Unit { ServiceChecks.batchSaveAuditAndVersion(rf) }

    @TestCase
    public func testBatchUpdateVersion(): Unit { ServiceChecks.batchUpdateVersion(rf) }

    @TestCase
    public func testIsolationLevel(): Unit { ServiceChecks.isolationLevel(rf) }
}

// ─── PostgreSQL 测试类 ──────────────────────────────────

@Test
public class PostgreSQLServiceTest {
    static let rf = openPostgres()

    @BeforeAll
    static func setup(): Unit { initOnce(rf) }

    @TestCase
    public func testRegister(): Unit { ServiceChecks.register(rf) }

    @TestCase
    public func testRegisterEmptyName(): Unit { ServiceChecks.registerEmptyName(rf) }

    @TestCase
    public func testFindByEmail(): Unit { ServiceChecks.findByEmail(rf) }

    @TestCase
    public func testSearchByLike(): Unit { ServiceChecks.searchByLike(rf) }

    @TestCase
    public func testUpdateEmail(): Unit { ServiceChecks.updateEmail(rf) }

    @TestCase
    public func testPreloadPosts(): Unit { ServiceChecks.preloadPosts(rf) }

    @TestCase
    public func testDeleteUser(): Unit { ServiceChecks.deleteUser(rf) }

    @TestCase
    public func testNestedRollback(): Unit { ServiceChecks.nestedRollback(rf) }

    @TestCase
    public func testCreatePost(): Unit { ServiceChecks.createPost(rf) }

    @TestCase
    public func testPreloadDetails(): Unit { ServiceChecks.preloadDetails(rf) }

    @TestCase
    public func testFindRecent(): Unit { ServiceChecks.findRecent(rf) }

    @TestCase
    public func testSearchPosts(): Unit { ServiceChecks.searchPosts(rf) }

    @TestCase
    public func testSetProfile(): Unit { ServiceChecks.setProfile(rf) }

    @TestCase
    public func testCountExists(): Unit { ServiceChecks.countExists(rf) }

    @TestCase
    public func testUlidSaveAutoGenerate(): Unit { ServiceChecks.ulidSaveAutoGenerate(rf) }

    @TestCase
    public func testUlidSaveCustomId(): Unit { ServiceChecks.ulidSaveCustomId(rf) }

    @TestCase
    public func testUlidUpdateDelete(): Unit { ServiceChecks.ulidUpdateDelete(rf) }

    @TestCase
    public func testUpsertInsertAndUpdate(): Unit { ServiceChecks.upsertInsertAndUpdate(rf) }

    @TestCase
    public func testBatchUpdateDifferentValues(): Unit { ServiceChecks.batchUpdateDifferentValues(rf) }

    @TestCase
    public func testAggregateFunctions(): Unit { ServiceChecks.aggregateFunctions(rf) }

    @TestCase
    public func testPageQuery(): Unit { ServiceChecks.pageQuery(rf) }

    @TestCase
    public func testUpdateWhereDeleteWhere(): Unit { ServiceChecks.updateWhereDeleteWhere(rf) }

    @TestCase
    public func testForUpdateQuery(): Unit { ServiceChecks.forUpdateQuery(rf) }

    @TestCase
    public func testAuditFieldsFilled(): Unit { ServiceChecks.auditFieldsFilled(rf) }

    @TestCase
    public func testAuditFieldsOnUpdate(): Unit { ServiceChecks.auditFieldsOnUpdate(rf) }

    @TestCase
    public func testOptimisticLockConflict(): Unit { ServiceChecks.optimisticLockConflict(rf) }

    @TestCase
    public func testOptimisticLockSuccessPath(): Unit { ServiceChecks.optimisticLockSuccessPath(rf) }

    @TestCase
    public func testBatchSaveAuditAndVersion(): Unit { ServiceChecks.batchSaveAuditAndVersion(rf) }

    @TestCase
    public func testBatchUpdateVersion(): Unit { ServiceChecks.batchUpdateVersion(rf) }

    @TestCase
    public func testIsolationLevel(): Unit { ServiceChecks.isolationLevel(rf) }
}
