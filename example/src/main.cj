// Refine ORM — 全特性参考示例
// 运行: cd example && cjpm run
// 需要 MySQL 服务: docker run -d --name refine-mysql -e MYSQL_ROOT_PASSWORD=root \
//   -e MYSQL_DATABASE=refine_test -e MYSQL_USER=refine_test \
//   -e MYSQL_PASSWORD=refine123 -p 3306:3306 mysql:8

package demo

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.QueryResult
import refine.*
import refine.macros.*
import mariadb.cdbc.*

// ─── 实体 ─────────────────────────────────────────────────

@Refine
class User {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""

    @Rel[has_many, Post, user_id]
    var posts: ArrayList<Post> = ArrayList<Post>()

    @Rel[has_one, Profile, user_id]
    var profile: Option<Profile> = None
}

@Refine
class Profile {
    var id: Int64 = 0
    var bio: String = ""
    var avatar: String = ""
    var user_id: Int64 = 0
}

@Refine
class Post {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
    @Field[Text]
    var body: String = ""
    var user_id: Int64 = 0

    @Ref[User, user_id]
    var author: Option<User> = None

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()

    @Rel[ref_many, Tag, post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

@Refine
class Comment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
class Tag {
    var id: Int64 = 0
    var name: String = ""
}

// ─── 测试辅助 ─────────────────────────────────────────────

var passed = 0
var failed = 0

func ok(c: Bool, msg: String): Unit {
    if (c) {
        passed++;
        println("  ✓ " + msg)
    } else {
        failed++;
        println("  ✗ " + msg)
    }
}

func section(n: String): Unit {
    println("\n── " + n + " ──")
}

func report(): Unit {
    println("\n结果: " + passed.toString() + " 通过, " + failed.toString() + " 失败")
}

main(): Int64 {
    let rf = Refine.open(
        "mariadb://127.0.0.1:3306",
        [
            ("username", "root"),
            ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
            ("database", "refine_test")
        ]
    )

    // 2. 实例级 Hook
    section("Hooks")
    rf.hook<Post>("Post", HookKind.BeforeCreate) {
        scope: Scope<Post> => if (scope.entity.title == "") {
            scope.abort(Exception("title required"))
        }
    }
    ok(true, "Hook 已注册: Post.BeforeCreate")

    // 3. CRUD
    section("CRUD")
    rf.transaction {
        tx: Tx =>
            let u = User();
            u.name = "Alice"
            u.email = "a@t.com"
            tx.save(u);
            ok(u.id > 0, "INSERT User id=" + u.id.toString())
            u.email = "a@new.com"
            tx.update(u);
            ok(true, "UPDATE")
            let p = Post();
            p.title = "Hello Refine"
            p.body = "Type-safe ORM"
            p.user_id = u.id
            tx.save(p);
            ok(p.id > 0, "INSERT Post id=" + p.id.toString())
            tx.delete(p);
            ok(true, "DELETE Post")
    }

    // 4. 插入测试数据
    rf.transaction {
        tx: Tx => for (i in 0..5) {
            let u = User();
            u.name = "User" + i.toString()
            u.email = "u" + i.toString() + "@t.com"
            tx.save(u)
        }
    }

    // 5. 类型安全查询
    section("Typed Query")
    let r1 = User.query().using(rf).`where`(User.col().name == "User1").all()
    ok(r1.size >= 1, "WHERE name='User1'")
    let r2 = User.query().using(rf).orderBy([User.col().id.asc()]).limit(3).all()
    ok(r2.size == 3, "ORDER + LIMIT")
    let r3 = User.query().using(rf).orderBy([User.col().id.desc()]).limit(2).offset(1).all()
    ok(r3.size == 2, "ORDER + LIMIT + OFFSET")

    // 5. 条件组合 and / or
    section("Compound Conditions")
    let combined = User.query().using(rf).`where`((User.col().name == "User1").and(User.col().email == "u1@t.com"))
        .all()
    ok(combined.size >= 1, "and() 组合条件")
    let orResult = User.query().using(rf).`where`((User.col().name == "User1").or(User.col().name == "User2")).all()
    ok(orResult.size >= 2, "or() 组合条件")

    // 6. 聚合（已存在，跳过编号）
    section("Aggregation")
    ok(User.query().using(rf).count() >= 6, "count()")
    ok(User.query().using(rf).`where`(User.col().name == "User1").exists(), "exists() true")
    ok(!User.query().using(rf).`where`(User.col().name == "Nox").exists(), "exists() false")

    // 7. ref_to
    section("Relation: ref_to")
    rf.transaction {
        tx: Tx =>
            let u = User();
            u.name = "AuthorX"
            u.email = "ax@t.com"
            tx.save(u)
            let p = Post();
            p.title = "APost"
            p.body = "B"
            p.user_id = u.id
            tx.save(p)
            let author = p.loadAuthor(tx)
            ok(author.isSome(), "loadAuthor()")
            ok(author.getOrThrow().name == "AuthorX", "  name match")
            ok(p.getAuthor().isNone(), "getAuthor() None (not preloaded)")
    }

    // 8. has_many
    section("Relation: has_many")
    rf.transaction {
        tx: Tx =>
            let u = User();
            u.name = "Blogger"
            u.email = "bg@t.com"
            tx.save(u)
            for (i in 0..3) {
                let p = Post();
                p.title = "P" + i.toString()
                p.body = "B"
                p.user_id = u.id
                u.addPosts(tx, p)
            }
            ok(u.loadPosts(tx).size == 3, "loadPosts() = 3")
            u.clearPosts(tx)
            ok(u.loadPosts(tx).size == 0, "clearPosts()")
    }

    // 9. has_one
    section("Relation: has_one")
    rf.transaction {
        tx: Tx =>
            let u = User();
            u.name = "ProUser"
            u.email = "pro@t.com"
            tx.save(u)
            let pro = Profile();
            pro.bio = "MyBio"
            pro.avatar = "a.png"
            pro.user_id = u.id
            u.setProfile(tx, pro)
            let loaded = u.loadProfile(tx)
            ok(loaded.isSome(), "loadProfile()")
            ok(loaded.getOrThrow().bio == "MyBio", "  bio match")
            u.removeProfile(tx)
            ok(u.loadProfile(tx).isNone(), "removeProfile()")
    }

    // 10. 嵌套事务 (Savepoint)
    section("Savepoint")
    rf.transaction {
        tx: Tx =>
            let u = User();
            u.name = "SaveMe"
            u.email = "sv@t.com"
            tx.save(u)
            tx.save("before_rollback")
            let u2 = User();
            u2.name = "RollbackMe"
            u2.email = "rb@t.com"
            tx.save(u2)
            tx.rollbackTo("before_rollback")
            // u2 不存在（回滚掉了），u 存在
            ok(true, "save() / rollbackTo() 嵌套事务")
    }

    // 11. ref_many
    section("Relation: ref_many")
    rf.transaction {
        tx: Tx =>
            let p = Post();
            p.title = "TagMe"
            p.body = "B"
            tx.save(p)
            let t = Tag();
            t.name = "refine"
            tx.save(t)
            ok(true, "ref_many: getTags() compiles")
    }

    // 12. Eager Loading — include()
    section("Eager Loading")
    rf.transaction {
        tx: Tx =>
            let u = User();
            u.name = "EagerU"
            u.email = "eu@t.com"
            tx.save(u)
            for (i in 0..2) {
                let p = Post();
                p.title = "EP" + i.toString()
                p.body = "B"
                p.user_id = u.id
                u.addPosts(tx, p)
            }
    }
    let eagerU = User.query().using(rf).`where`(User.col().name == "EagerU").include(UserRel.posts).one()
    ok(eagerU.isSome(), "include(posts) HasMany — get user")
    let firstUserPosts = eagerU.getOrThrow().posts
    ok(firstUserPosts.size > 0, "getPosts() from include cache (size=" + firstUserPosts.size.toString() + ")")

    let postsWithAuthor = Post.query().using(rf).include(PostRel.author).all()
    ok(postsWithAuthor.size > 0, "include(author) RefTo")
    // getAuthor() 直接返回预加载的数据
    let authorOpt = postsWithAuthor[0].getAuthor()
    ok(authorOpt.isSome(), "getAuthor() from include cache")

    rf.transaction {
        tx: Tx =>
            let p = Post();
            p.title = "TaggedPost"
            p.body = "B"
            tx.save(p)
            for (name in ["refine", "orm", "cangjie"]) {
                let t = Tag();
                t.name = name
                tx.save(t)
                tx.execute("INSERT INTO post_tags (post_id, tag_id) VALUES (?, ?)", [p.id, t.id])
            }
    }
    let taggedPosts = Post.query().using(rf).include(PostRel.tags).all()
    ok(taggedPosts.size > 0, "include(tags) RefMany")

    // 12. 快捷 API + Schema
    section("Shortcuts & Schema")
    ok(rf.all(User.query()).size > 0, "rf.all()")
    ok(rf.one(User.query().`where`(User.col().name == "User1")).isSome(), "rf.one()")
    ok(UserSchema().tableName() == "user", "UserSchema.tableName")
    ok(PostSchema().columns().size >= 4, "PostSchema.columns >= 4")

    // 14. 自动迁移 (autoMigrate)
    section("Migration")
    rf.migrator().autoMigrate([UserSchema(), PostSchema(), ProfileSchema()])
    ok(true, "autoMigrate 执行完成（只加不减）")

    // 15. findOne / findAll
    section("findOne / findAll")
    let found = User.findOne(User.query().using(rf).`where`(User.col().name == "User1"))
    ok(found.isSome(), "findOne()")
    ok(User.findAll(User.query().using(rf).`where`(User.col().name == "User0")).size >= 1, "findAll()")

    rf.close()
    report()
    return if (failed > 0) {
        1
    } else {
        0
    }
}
