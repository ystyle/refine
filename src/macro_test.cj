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
class UuidPost {
    var id: String = ""
    var title: String = ""
    var content: String = ""
}

@Refine
class ManualIdPost {
    @Id[auto, false]
    var id: Int64 = 0
    var title: String = ""
}

@Refine
class OrderTag {
    @Id[]
    var order_id: Int64 = 0
    @Id[]
    var tag_id: Int64 = 0
}

@Refine
class PostWithRel {
    var id: Int64 = 0
    var title: String = ""
    var user_id: Int64 = 0
    var post_id: Int64 = 0

    @Ref[User, user_id]
    var author: Option<User> = None

    @Ref[Tag, via: post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()
}

class HookFlag {
    var called: Bool = false
    public init() {}
}

class TestIdGenerator <: IdGenerator {
    private var counter: Int64 = 0
    public func generate(): String {
        counter = counter + 1
        "uuid-" + counter.toString()
    }
}

class CaptureUpdateResult <: UpdateResult {
    public prop lastInsertId: Int64 { get() { _lastInsertId } }
    public prop rowCount: Int64 { get() { _rowCount } }
    private var _lastInsertId: Int64
    private var _rowCount: Int64
    public init(lastInsertId: Int64, rowCount: Int64) {
        this._lastInsertId = lastInsertId
        this._rowCount = rowCount
    }
}

class CaptureStatement <: SqlStatement {
    public var capturedSql: String = ""
    public var capturedParams: Array<Any> = []
    public var mockLastInsertId: Int64 = 0
    public var mockRowCount: Int64 = 0

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { _parameterColumnInfos } }
    private var _parameterColumnInfos: Array<ColumnInfo> = []

    public func query(): QueryResult { MockQueryResult() }
    public func query(_params: Array<SqlDbType>): QueryResult { MockQueryResult() }

    public func set<T>(index: Int, value: T): Unit {}
    public func setNull(index: Int): Unit {}
    public func setOption(_key: String, value: String): Unit {}
    public func update(): UpdateResult { CaptureUpdateResult(mockLastInsertId, mockRowCount) }
    public func update(_params: Array<SqlDbType>): UpdateResult { CaptureUpdateResult(mockLastInsertId, mockRowCount) }
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

    @TestCase
    public func testTxSaveFiresTxBeforeCreate(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxBeforeCreate) { scope: Scope<Post> =>
            flag.called = true
            if (scope.db.isSome()) { flag.called = true }
        }

        let p = Post()
        p.title = "Hook Test"
        p.content = "Testing hooks"
        tx.save(p)

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxSaveDoesNotFireNonTxBeforeCreate(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let nonTxFlag = HookFlag()
        rf.hook<Post>("Post", HookKind.BeforeCreate) { scope: Scope<Post> =>
            nonTxFlag.called = true
        }

        let p = Post()
        p.title = "Separation Test"
        tx.save(p)

        @Expect(nonTxFlag.called, false)
    }

    // ─── Batch Save Tests ────────────────────────────────

    @TestCase
    public func testTxBatchSavePost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p1 = Post()
        p1.title = "Title 1"
        p1.content = "Content 1"
        let p2 = Post()
        p2.title = "Title 2"
        p2.content = "Content 2"

        tx.batchSave([p1, p2])

        @Expect(conn.stmt.capturedSql, "INSERT INTO post (title, content) VALUES (?, ?), (?, ?)")
    }

    @TestCase
    public func testTxBatchSaveUser(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let u1 = User()
        u1.name = "Alice"
        u1.email = "alice@test.com"
        let u2 = User()
        u2.name = "Bob"
        u2.email = "bob@test.com"

        tx.batchSave([u1, u2])

        @Expect(conn.stmt.capturedSql, "INSERT INTO user (name, email) VALUES (?, ?), (?, ?)")
    }

    @TestCase
    public func testTxBatchSaveFiresTxBeforeCreate(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxBeforeCreate) { scope: Scope<Post> =>
            flag.called = true
        }

        let p1 = Post(); p1.title = "A"
        let p2 = Post(); p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxBatchSaveFiresTxAfterCreate(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxAfterCreate) { scope: Scope<Post> =>
            flag.called = true
        }

        let p1 = Post(); p1.title = "A"
        let p2 = Post(); p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxBatchSaveSetsIds(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 100
        conn.stmt.mockRowCount = 2
        let tx = Tx(conn)

        let p1 = Post(); p1.title = "A"; p1.content = "B"
        let p2 = Post(); p2.title = "C"; p2.content = "D"
        tx.batchSave([p1, p2])

        @Expect(p1.id, 100)
        @Expect(p2.id, 101)
    }

    @TestCase
    public func testTxBatchSaveEmptyEntities(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        tx.batchSave(ArrayList<Post>().toArray())

        @Expect(conn.stmt.capturedSql, "")
    }

    // ─── UUID / String Id Tests ────────────────────────

    @TestCase
    public func testTxSaveUuidPostIncludesIdInInsert(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)

        let p = UuidPost()
        p.title = "Test"
        p.content = "Content"
        tx.save(p)

        @Expect(p.id != "", true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO uuidPost (id, title, content)"), true)
        @Expect(conn.stmt.capturedSql.contains("VALUES (?, ?, ?)"), true)
    }

    @TestCase
    public func testTxSaveUuidPostKeepsCustomId(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)

        let p = UuidPost()
        p.id = "my-custom-id"
        p.title = "Test"
        p.content = "X"
        tx.save(p)

        @Expect(p.id, "my-custom-id")
    }

    @TestCase
    public func testTxBatchSaveUuidPost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)

        let p1 = UuidPost(); p1.title = "A"; p1.content = "B"
        let p2 = UuidPost(); p2.title = "C"; p2.content = "D"
        tx.batchSave([p1, p2])

        @Expect(p1.id != "", true)
        @Expect(p2.id != "", true)
        @Expect(p1.id != p2.id, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO uuidPost (id, title, content) VALUES (?, ?, ?), (?, ?, ?)"), true)
    }

    // ─── @Id / Compound Key Tests ──────────────────────

    @TestCase
    public func testTxSaveManualIdPostIncludesId(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p = ManualIdPost()
        p.id = 42
        p.title = "Manual"
        tx.save(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO manualIdPost (id, title)"), true)
    }

    @TestCase
    public func testTxUpdateManualIdPost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p = ManualIdPost()
        p.id = 1
        p.title = "Updated"
        tx.update(p)

        @Expect(conn.stmt.capturedSql.contains("UPDATE manualIdPost SET"), true)
        @Expect(conn.stmt.capturedSql.contains("WHERE id = ?"), true)
    }

    @TestCase
    public func testTxDeleteManualIdPost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p = ManualIdPost()
        p.id = 1
        tx.delete(p)

        @Expect(conn.stmt.capturedSql.contains("DELETE FROM manualIdPost"), true)
        @Expect(conn.stmt.capturedSql.contains("WHERE id = ?"), true)
    }

    @TestCase
    public func testTxSaveOrderTagCompoundPk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let ot = OrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        tx.save(ot)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO orderTag (order_id, tag_id)"), true)
        @Expect(conn.stmt.capturedSql.contains("VALUES (?, ?)"), true)
    }

    @TestCase
    public func testTxUpdateOrderTagCompoundPk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let ot = OrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        tx.update(ot)

        @Expect(conn.stmt.capturedSql.contains("WHERE order_id = ? AND tag_id = ?"), true)
    }

    @TestCase
    public func testTxDeleteOrderTagCompoundPk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let ot = OrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        tx.delete(ot)

        @Expect(conn.stmt.capturedSql.contains("WHERE order_id = ? AND tag_id = ?"), true)
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
        registerHook("Post", HookKind.BeforeCreate) { scope: Scope<Post> =>
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

    @TestCase
    public func testJunctionSchemaGenerated(): Unit {
        let js = PostWithRel_TagsJunctionSchema()
        @Expect(js.tableName(), "post_tags")
        let cols = js.columns()
        @Expect(cols.size, 2)
        @Expect(cols[0].name, "postWithRel_id")
        @Expect(cols[1].name, "tag_id")
        @Expect(cols[0].storageType, StorageType.Integer)
    }

    @TestCase
    public func testSchemasReturnsMainAndJunction(): Unit {
        let all = PostWithRel.schemas()
        @Expect(all.size, 2)
        @Expect(all[0].tableName(), "postWithRel")
        @Expect(all[1].tableName(), "post_tags")
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

// ─── Soft Delete Entity ────────────────────────────────

@Refine
class SoftUser {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
}

@Refine
@HardDelete
class HardUser {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
}

@Test
public class SoftDeleteTest {
    @TestCase
    public func testTxDeleteIsUpdateForSoftDelete(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let u = SoftUser()
        u.id = 1
        u.name = "test"
        tx.delete(u)
        @Expect(conn.stmt.capturedSql.contains("UPDATE"), true)
        @Expect(conn.stmt.capturedSql.contains("deleted_at"), true)
        @Expect(conn.stmt.capturedSql.contains("softUser"), true)
    }

    @TestCase
    public func testTxPhysicalDeleteIsDeleteForSoftDelete(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let u = SoftUser()
        u.id = 1
        u.name = "test"
        tx.physicalDelete(u)
        @Expect(conn.stmt.capturedSql.contains("DELETE"), true)
        @Expect(conn.stmt.capturedSql.contains("softUser"), true)
    }

    @TestCase
    public func testTxDeleteIsDeleteForHardDeleted(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let u = HardUser()
        u.id = 1
        u.name = "test"
        tx.delete(u)
        @Expect(conn.stmt.capturedSql.contains("DELETE"), true)
        @Expect(conn.stmt.capturedSql.contains("hardUser"), true)
    }

    @TestCase
    public func testSoftDeleteQueryAddsFilter(): Unit {
        let q = SoftUser.query()
        var hasDeletedAtFilter = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.WhereClause(predicates) =>
                    for (p in predicates) {
                        match (p) {
                            case Expr.Binary(Expr.Column(name), _, _) =>
                                if (name == "deleted_at") { hasDeletedAtFilter = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(hasDeletedAtFilter, true)
    }

    @TestCase
    public func testHardDeleteQueryNoFilter(): Unit {
        let q = HardUser.query()
        var hasDeletedAtFilter = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.WhereClause(predicates) =>
                    for (p in predicates) {
                        match (p) {
                            case Expr.Binary(Expr.Column(name), _, _) =>
                                if (name == "deleted_at") { hasDeletedAtFilter = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(hasDeletedAtFilter, false)
    }
}
