package refine

import refine.macros.*
import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.{Connection, Transaction, QueryResult, UpdateResult, ColumnInfo, ConnectionState, SqlDbType}
import std.database.sql.Statement as SqlStatement
import std.unittest.*
import std.unittest.testmacro.*

@Refine
class Post {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
}

@Refine
class User {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""
}

@Refine
class Tag {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
class Comment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
class PostWithRel {
    var id: Int64 = 0
    var title: String = ""
    var user_id: Int64 = 0
    var post_id: Int64 = 0

    @Ref[User, user_id]
    var author: Option<User> = None

    @Rel[ref_many, Tag, post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()
}

class HookFlag {
    var called: Bool = false
    public init() {}
}

class CaptureStatement <: SqlStatement {
    public var capturedSql: String = ""
    public var capturedParams: Array<Any> = []

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { _parameterColumnInfos } }
    private var _parameterColumnInfos: Array<ColumnInfo> = []

    public func query(): QueryResult { MockQueryResult() }
    public func query(_params: Array<SqlDbType>): QueryResult { MockQueryResult() }

    public func set<T>(index: Int, value: T): Unit {}
    public func setNull(index: Int): Unit {}
    public func setOption(_key: String, value: String): Unit {}
    public func update(): UpdateResult { MockUpdateResult() }
    public func update(_params: Array<SqlDbType>): UpdateResult { MockUpdateResult() }
}

class CaptureConnection <: Connection {
    public var stmt: CaptureStatement = CaptureStatement()

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }
    public func createTransaction(): Transaction { MockTransaction() }
    public func getMetaData(): HashMap<String, String> { HashMap<String, String>() }
    public func prepareStatement(sql: String): SqlStatement {
        stmt.capturedSql = sql
        stmt
    }
}

@Test
public class MacroSaveTest {
    @TestCase
    public func testTxSavePost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p = Post()
        p.title = "Test Title"
        p.content = "Test Content"
        tx.save(p)

        @Expect(conn.stmt.capturedSql, "INSERT INTO post (title, content) VALUES (?, ?)")
    }

    @TestCase
    public func testTxSaveUser(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let u = User()
        u.name = "Alice"
        u.email = "alice@test.com"
        tx.save(u)

        @Expect(conn.stmt.capturedSql, "INSERT INTO user (name, email) VALUES (?, ?)")
    }

    @TestCase
    public func testTxUpdatePost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p = Post()
        p.id = 1
        p.title = "Updated Title"
        p.content = "Updated Content"
        tx.update(p)

        @Expect(conn.stmt.capturedSql, "UPDATE post SET title = ?, content = ? WHERE id = ?")
    }

    @TestCase
    public func testTxDeletePost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p = Post()
        p.id = 1
        tx.delete(p)

        @Expect(conn.stmt.capturedSql, "DELETE FROM post WHERE id = ?")
    }
}

@Test
public class MacroExistingTest {
    @TestCase
    public func testColsStructs(): Unit {
        let postCols = Post.col()
        println("PostCols: id=${postCols.id.name}, title=${postCols.title.name}, content=${postCols.content.name}")
        @Expect(postCols.title.name, "title")
    }

    @TestCase
    public func testQueries(): Unit {
        let _ = Post.query()
        let _ = User.query()
    }

    @TestCase
    public func testRels(): Unit {
        @Expect(PostWithRelRel.author.name, "author")
        @Expect(PostWithRelRel.tags.name, "tags")
    }

    @TestCase
    public func testCRUDMethods(): Unit {
        let post = Post()
        Post.save(post)
        Post.update(post)
        Post.delete(post)
    }

    @TestCase
    public func testHookIntegration(): Unit {
        clearHooks()
        let flag = HookFlag()
        registerHook("Post", HookKind.BeforeSave) { scope: Scope<Post> =>
            flag.called = true
        }
        let p2 = Post()
        Post.save(p2)
        @Expect(flag.called, true)
    }

    @TestCase
    public func testFindAllThrowsWithoutExecutor(): Unit {
        try {
            let _ = Post.findAll(Post.query())
            @Fail("expected QueryException")
        } catch (e: QueryException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testFindOneThrowsWithoutExecutor(): Unit {
        try {
            let _ = Post.findOne(Post.query())
            @Fail("expected QueryException")
        } catch (e: QueryException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testGetAuthorRelation(): Unit {
        let p = PostWithRel()
        let author = p.getAuthor()
        @Expect(author.isNone(), true)
    }

    @TestCase
    public func testGetTagsRelation(): Unit {
        let p = PostWithRel()
        let tags = p.getTags()
        @Expect(tags.size, 0)
    }

    @TestCase
    public func testAliasedRendering(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id"), Aliased(Column("name"), "user.name")]))
        stmt.addClause(FromClause("users"))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\", \"name\" AS \"user.name\" FROM \"users\"")
    }

    @TestCase
    public func testIncludeRendersJoin(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let _ = PostWithRel.findAll(PostWithRel.query()
            .select([Column("id")])
            .from("postWithRel")
            .include(PostWithRelRel.author)
            .using(tx))
        @Expect(conn.stmt.capturedSql.contains("LEFT JOIN"), true)
        @Expect(conn.stmt.capturedSql.contains("author"), true)
    }

    @TestCase
    public func testGeneratedSchema(): Unit {
        let schema = UserSchema()
        @Expect(schema.tableName(), "user")
        let cols = schema.columns()
        @Expect(cols.size, 3)
        @Expect(cols[0].name, "id")
        @Expect(cols[0].primaryKey, true)
        @Expect(cols[0].autoIncrement, true)
        @Expect(cols[1].name, "name")
    }
}

@Refine
class Document {
    var id: Int64 = 0
    @Field[Text]
    var title: String = ""
}

@Test
public class FieldAnnotationTest {
    @TestCase
    public func testFieldOverrideSchema(): Unit {
        let schema = DocumentSchema()
        let cols = schema.columns()
        @Expect(cols.size, 2)
        @Expect(cols[1].name, "title")
        @Expect(cols[1].storageType, StorageType.Text)
    }
}
