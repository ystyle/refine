package demo

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import refine.*
import mariadb.cdbc.*

@Test
public class ServiceTest {
    static let rf = Refine.open("mariadb://127.0.0.1:3306", [
        ("username", "root"),
        ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
        ("database", "refine_test")
    ])

    static var seq: Int64 = 0
    static var initialized: Bool = false

    static func initOnce(): Unit {
        if (initialized) { return }
        initialized = true
        // 先创建所有业务表
        rf.transaction { tx: Tx =>
            // junction 表需要通过原始 SQL 创建（框架不自动管理 junction 表）
            tx.execute("CREATE TABLE IF NOT EXISTS post_tags (post_id BIGINT NOT NULL, tag_id BIGINT NOT NULL)", [])
        }
        rf.migrator().autoMigrate([
            UserSchema(), ProfileSchema(), PostSchema(), CommentSchema(), TagSchema()
        ])
        rf.hook<User>("User", HookKind.BeforeCreate) { scope: Scope<User> =>
            if (scope.entity.name == "") {
                scope.abort(Exception("name required"))
            }
        }
    }

    static func uid(): String { seq++; seq.toString() }

    // ─── UserService ──────────────────────────────────

    @TestCase
    public func testRegister(): Unit {
        initOnce()
        let name = "Reg_" + uid()
        let user = UserService.register(rf, name, "reg@t.com")
        @Expect(user.id > 0, true)
        @Expect(user.name, name)
    }

    @TestCase
    public func testRegisterEmptyName(): Unit {
        initOnce()
        try {
            UserService.register(rf, "", "bad@t.com")
            @Fail("expected Hook abort")
        } catch (_: Exception) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testFindByEmail(): Unit {
        initOnce()
        let name = "Email_" + uid()
        UserService.register(rf, name, name + "@t.com")
        var p = UserFind()
        p.email = Some(name + "@t.com")
        let found = UserRepo.findOne(rf, p)
        @Expect(found.isSome(), true)
        @Expect(found.getOrThrow().email, name + "@t.com")
    }

    @TestCase
    public func testSearchByLike(): Unit {
        initOnce()
        let suffix = uid()
        let name = "Like_" + suffix
        UserService.register(rf, name, name + "@t.com")
        var p = UserFind()
        p.nameLike = Some(suffix)
        @Expect(UserRepo.find(rf, p).size > 0, true)
    }

    @TestCase
    public func testUpdateEmail(): Unit {
        initOnce()
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

    @TestCase
    public func testPreloadPosts(): Unit {
        initOnce()
        let name = "Preload_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        PostService.create(rf, "P1", "B1", user.id)
        PostService.create(rf, "P2", "B2", user.id)
        let loaded = UserService.getWithPosts(rf, user.id)
        @Expect(loaded.isSome(), true)
        @Expect(loaded.getOrThrow().posts.size, 2)
    }

    @TestCase
    public func testDeleteUser(): Unit {
        initOnce()
        let name = "Del_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        UserService.deleteUser(rf, user.id)
        var p = UserFind()
        p.id = Some(user.id)
        @Expect(UserRepo.findOne(rf, p).isNone(), true)
    }

    @TestCase
    public func testNestedRollback(): Unit {
        initOnce()
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

    @TestCase
    public func testCreatePost(): Unit {
        initOnce()
        let name = "Auth_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        let post = PostService.create(rf, "Hello", "World", author.id)
        @Expect(post.id > 0, true)
        @Expect(post.title, "Hello")
    }

    @TestCase
    public func testPreloadDetails(): Unit {
        initOnce()
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

    @TestCase
    public func testFindRecent(): Unit {
        initOnce()
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

    @TestCase
    public func testSearchPosts(): Unit {
        initOnce()
        let name = "Kw_" + uid()
        let author = UserService.register(rf, name, name + "@t.com")
        PostService.create(rf, "AlphaPost", "BodyA", author.id)
        PostService.create(rf, "BetaPost", "BodyB", author.id)
        var p = PostFind()
        p.keyword = Some("Alpha")
        @Expect(PostRepo.find(rf, p).size > 0, true)
    }

    // ─── ProfileService ───────────────────────────────

    @TestCase
    public func testSetProfile(): Unit {
        initOnce()
        let name = "Pro_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        ProfileService.setProfile(rf, user.id, "MyBio", "avatar.png")
        let profile = ProfileRepo.findByUserId(rf, user.id)
        @Expect(profile.isSome(), true)
        @Expect(profile.getOrThrow().bio, "MyBio")
    }

    // ─── Aggregation ──────────────────────────────────

    @TestCase
    public func testCountExists(): Unit {
        initOnce()
        let name = "Ex_" + uid()
        let user = UserService.register(rf, name, name + "@t.com")
        let post = PostService.create(rf, "Ex", "B", user.id)
        @Expect(PostService.existsById(rf, post.id), true)
        @Expect(!PostService.existsById(rf, -999), true)
        @Expect(PostService.countAll(rf) >= 0, true)
        @Expect(UserRepo.countAll(rf) > 0, true)
    }
}
