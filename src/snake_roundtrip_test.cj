package refine

import std.unittest.*
import std.unittest.testmacro.*

// M4 审查：snake 命名策略真实 DB roundtrip 的共享实现。mariadb/mysql/pgsql 三个集成
// 测试文件的 testSnakeNamingRoundtrip 之前 ~95% 重复，收敛为顶层函数 + 各文件 thin
// wrapper（只负责 tryXxx() 取连接、执行、关闭）。
// 端到端覆盖：autoMigrate 建 snake 表 → save（snake 列名 INSERT：display_name /
// author_id / post_id）→ query 读回（rowMapper snake 键）→ include 关系装配
//（r.by author_id/post_id）→ ref_many junction 写读（related_authors.snake_post_id /
// snake_author_id）。验证 r.by 双身份 + junction 列名转换在真实 DB 上可完整读写。
// DROP TABLE 用不带引号的标识符：四张表都是全小写 snake_case 非保留字，MySQL/MariaDB
// 与 PostgreSQL 均接受不带引号写法（PG 未加引号折叠小写，正好命中小写表名）。
// M5：hasTable 断言统一为 4 张表（修复前 MySQL/MariaDB 只断言 2 张）。
public func runSnakeNamingRoundtrip(rf: Refine): Unit {
    rf.transaction { tx: Tx =>
        tx.execute("DROP TABLE IF EXISTS related_authors", [])
        tx.execute("DROP TABLE IF EXISTS snake_comment", [])
        tx.execute("DROP TABLE IF EXISTS snake_author", [])
        tx.execute("DROP TABLE IF EXISTS snake_post", [])
    }
    let m = rf.migrator()
    m.autoMigrate([SnakePostSchema(), SnakeAuthorSchema(), SnakeCommentSchema(), SnakePost_RelatedAuthorsJunctionSchema()])
    @Expect(m.hasTable("snake_post"), true)
    @Expect(m.hasTable("snake_author"), true)
    @Expect(m.hasTable("snake_comment"), true)
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

    // include 关系装配：r.by snake 列（author_id / post_id）批量查询命中
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
}
