package refine

import refine.macros.*
import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.{Connection, Transaction, QueryResult, UpdateResult, ColumnInfo, ConnectionState, SqlDbType}
import std.database.sql.Statement as SqlStatement
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

@Refine
public class Post {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
}

@Refine
public class User {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""
}

@Refine
public class Tag {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
public class Comment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
public class UuidPost {
    var id: String = ""
    var title: String = ""
    var content: String = ""
}

@Refine
public class ManualIdPost {
    @Id[auto, false]
    var id: Int64 = 0
    var title: String = ""
}

@Refine
public class OrderTag {
    @Id[]
    var order_id: Int64 = 0
    @Id[]
    var tag_id: Int64 = 0
}

@Refine
public class StringKeyEntity {
    @Id[]
    var key: String = ""
    var name: String = ""
}

@Refine
public class CustomAutoPkEntity {
    @Id[auto, true]
    var uid: Int64 = 0
    var label: String = ""
}

@Refine
public class OrderItemTag {
    @Id[]
    var order_id: Int64 = 0
    @Id[]
    var item_id: Int64 = 0
    var quantity: Int64 = 0
}

@Refine
public class PgPost {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
}

@Refine
public class PgEvent {
    var id: String = ""
    var name: String = ""
    var payload: String = ""
}

@Refine
public class PostWithRel {
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

class TestInt64IdGenerator <: IdGenerator {
    private var counter: Int64 = 0
    public func generate(): String {
        counter = counter + 1
        counter.toString()
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
    public var queryResult: QueryResult = MockQueryResult()
    public var capturedSetValues: ArrayList<Any> = ArrayList<Any>()

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { _parameterColumnInfos } }
    private var _parameterColumnInfos: Array<ColumnInfo> = []

    public func query(): QueryResult { queryResult }
    public func query(_params: Array<SqlDbType>): QueryResult { queryResult }

    public func set<T>(index: Int, value: T): Unit {
        capturedSetValues.add(value)
    }
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

class RowQueryResult <: QueryResult {
    private var value: Any
    private var consumed: Bool = false
    public init(value: Any) { this.value = value }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop columnInfos: Array<ColumnInfo> { get() { _columnInfos } }
    private var _columnInfos: Array<ColumnInfo> = []
    public func next(): Bool {
        if (!consumed) { consumed = true; return true }
        false
    }
    public func next(_values: Array<SqlDbType>): Bool { false }
    public func get<T>(index: Int): T {
        match (value) { case v: T => v; case _ => throw Exception("type mismatch") }
    }
    public func getOrNull<T>(index: Int): ?T { None }
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
    public func testTxBatchSaveDoesNotSetAutoIds(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 100
        conn.stmt.mockRowCount = 2
        let tx = Tx(conn)

        let p1 = Post(); p1.title = "A"; p1.content = "B"
        let p2 = Post(); p2.title = "C"; p2.content = "D"
        tx.batchSave([p1, p2])

        @Expect(p1.id, 0)
        @Expect(p2.id, 0)
        @Expect(conn.stmt.capturedSql, "INSERT INTO post (title, content) VALUES (?, ?), (?, ?)")
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

    @TestCase
    public func testTxSaveStringKeyEntityAutoGen(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)

        let e = StringKeyEntity()
        e.name = "abc"
        tx.save(e)

        @Expect(e.key != "", true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO stringKeyEntity (key, name)"), true)
    }

    @TestCase
    public func testTxBatchSaveStringKeyEntityAutoGen(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)

        let e1 = StringKeyEntity(); e1.name = "a"
        let e2 = StringKeyEntity(); e2.name = "b"
        tx.batchSave([e1, e2])

        @Expect(e1.key != "", true)
        @Expect(e2.key != "", true)
        @Expect(e1.key != e2.key, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO stringKeyEntity (key, name)"), true)
    }

    @TestCase
    public func testTxSaveCustomAutoPkEntity(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let e = CustomAutoPkEntity()
        e.label = "x"
        tx.save(e)

        @Expect(e.uid, 42)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO customAutoPkEntity (label)"), true)
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
    public func testTxSaveManualIntPkAutoGen(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestInt64IdGenerator())
        let tx = Tx(conn, rf, 0)

        let p = ManualIdPost()
        p.title = "AutoGen"
        tx.save(p)

        @Expect(p.id != 0, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO manualIdPost (id, title)"), true)
    }

    @TestCase
    public func testTxBatchSaveManualIntPkAutoGen(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestInt64IdGenerator())
        let tx = Tx(conn, rf, 0)

        let p1 = ManualIdPost(); p1.title = "A"
        let p2 = ManualIdPost(); p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(p1.id != 0, true)
        @Expect(p2.id != 0, true)
        @Expect(p1.id != p2.id, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO manualIdPost (id, title)"), true)
    }

    @TestCase
    public func testTxSaveManualIntPkKeepsCustomId(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestInt64IdGenerator())
        let tx = Tx(conn, rf, 0)

        let p = ManualIdPost()
        p.id = 42
        p.title = "Custom"
        tx.save(p)

        @Expect(p.id, 42)
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

    // ─── Upsert ──────────────────────────────────────

    @TestCase
    public func testTxUpsertMySQL(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        let tx = Tx(conn, rf, 1)

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        tx.upsert(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `post` (`id`, `title`, `content`)"), true)
        @Expect(conn.stmt.capturedSql.contains("ON DUPLICATE KEY UPDATE"), true)
        @Expect(conn.stmt.capturedSql.contains("`title` = VALUES(`title`)"), true)
    }

    @TestCase
    public func testTxUpsertPostgres(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), PostgreSQLDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        tx.upsert(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"post\" (\"id\", \"title\", \"content\")"), true)
        @Expect(conn.stmt.capturedSql.contains("ON CONFLICT (\"id\") DO UPDATE SET"), true)
        @Expect(conn.stmt.capturedSql.contains("\"title\" = EXCLUDED.\"title\""), true)
    }

    @TestCase
    public func testTxUpsertUnsupportedDialect(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let p = Post()
        p.id = 1
        p.title = "T"
        try {
            tx.upsert(p)
            @Fail("expected unsupported dialect exception")
        } catch (_: Exception) {
            @Expect(conn.stmt.capturedSql, "")
        }
    }

    // ─── Batch Update ─────────────────────────────────

    @TestCase
    public func testTxBatchUpdatePost(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p1 = Post()
        p1.id = 1
        p1.title = "A"
        p1.content = "X"
        let p2 = Post()
        p2.id = 2
        p2.title = "B"
        p2.content = "Y"
        tx.batchUpdate([p1, p2])

        @Expect(conn.stmt.capturedSql.contains("UPDATE post SET title = CASE id WHEN ? THEN ? WHEN ? THEN ? END, content = CASE id WHEN ? THEN ? WHEN ? THEN ? END WHERE id IN (?, ?)"), true)
    }

    @TestCase
    public func testTxBatchUpdateEmpty(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        tx.batchUpdate(ArrayList<Post>().toArray())

        @Expect(conn.stmt.capturedSql, "")
    }

    @TestCase
    public func testTxBatchUpdateFiresHooks(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxBeforeUpdate) { scope: Scope<Post> =>
            flag.called = true
        }

        let p1 = Post(); p1.id = 1; p1.title = "A"
        let p2 = Post(); p2.id = 2; p2.title = "B"
        tx.batchUpdate([p1, p2])

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxBatchUpdateCompoundPk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let ot1 = OrderItemTag()
        ot1.order_id = 1
        ot1.item_id = 2
        ot1.quantity = 5
        let ot2 = OrderItemTag()
        ot2.order_id = 3
        ot2.item_id = 4
        ot2.quantity = 6
        tx.batchUpdate([ot1, ot2])

        @Expect(conn.stmt.capturedSql.contains("UPDATE orderItemTag SET quantity = CASE WHEN order_id = ? AND item_id = ? THEN ? WHEN order_id = ? AND item_id = ? THEN ? END WHERE (order_id, item_id) IN ((?, ?), (?, ?))"), true)
    }

    @TestCase
    public func testTxBatchUpdateNoUpdatableColumns(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let ot1 = OrderTag()
        ot1.order_id = 1
        ot1.tag_id = 2
        try {
            tx.batchUpdate([ot1])
            @Fail("expected no updatable columns exception")
        } catch (_: Exception) {
            @Expect(conn.stmt.capturedSql, "")
        }
    }

    @TestCase
    public func testTxUpsertStringPkAutoGen(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 1)

        let e = UuidPost()
        e.title = "T"
        tx.upsert(e)

        @Expect(e.id != "", true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `uuidPost` (`id`, `title`, `content`)"), true)
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
    public func testStringIdSchemaNoAutoIncrement(): Unit {
        let schema = UuidPostSchema()
        let cols = schema.columns()
        @Expect(cols[0].name, "id")
        @Expect(cols[0].primaryKey, true)
        @Expect(cols[0].autoIncrement, false)
    }

    @TestCase
    public func testStringFieldStorageType(): Unit {
        let schema = UuidPostSchema()
        let cols = schema.columns()
        @Expect(cols[0].storageType, StorageType.String)
        @Expect(cols[1].storageType, StorageType.String)
        @Expect(cols[2].storageType, StorageType.String)
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
public class Document {
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
public class SoftUser {
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

// ─── Version + Audit Fields Tests ───────────────────────

@Refine
public class VersionedPost {
    var id: Int64 = 0
    var title: String = ""
    var created_at: DateTime = DateTime.now()
    var updated_at: DateTime = DateTime.now()
    @Version
    var version: Int64 = 0
}

@Refine
public class VersionedEvent {
    @Id[]
    var id: String = ""
    var name: String = ""
    @Version
    var version: Int64 = 0
}

@Refine
public class VersionedOrderTag {
    @Id[]
    var order_id: Int64 = 0
    @Id[]
    var tag_id: Int64 = 0
    var quantity: Int64 = 0
    @Version
    var version: Int64 = 0
}

@Test
public class VersionedEntityTest {
    @TestCase
    public func testVersionedPostAuditColumnsStorageType(): Unit {
        let schema = VersionedPostSchema()
        let cols = schema.columns()
        @Expect(cols[2].storageType, StorageType.Timestamp)
        @Expect(cols[3].storageType, StorageType.Timestamp)
    }

    @TestCase
    public func testTxSaveVersionedPostInjectsAuditAndVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let before = DateTime.now()

        let p = VersionedPost()
        p.title = "Audit"
        tx.save(p)

        let after = DateTime.now()
        @Expect(p.version, 1)
        @Expect(p.created_at >= before, true)
        @Expect(p.created_at <= after, true)
        @Expect(p.updated_at >= before, true)
        @Expect(p.updated_at <= after, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO versionedPost (title, created_at, updated_at, version)"), true)
        @Expect(conn.stmt.capturedSql.contains("VALUES (?, ?, ?, ?)"), true)
    }

    @TestCase
    public func testTxUpdateVersionedPostSuccess(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)

        let p = VersionedPost()
        p.id = 1
        p.title = "Updated"
        p.version = 1
        tx.update(p)

        @Expect(conn.stmt.capturedSql, "UPDATE versionedPost SET title = ?, created_at = ?, updated_at = ?, version = version + 1 WHERE id = ? AND version = ?")
        @Expect(p.version, 2)
    }

    @TestCase
    public func testTxUpdateVersionedPostConflictNotFound(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        let tx = Tx(conn)

        let p = VersionedPost()
        p.id = 1
        p.title = "Updated"
        p.version = 1
        try {
            tx.update(p)
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.entityType, "VersionedPost")
            @Expect(e.pk, "1")
            @Expect(e.expected, 1)
            @Expect(e.actual, -1)
            @Expect(conn.stmt.capturedSql, "SELECT version FROM versionedPost WHERE id = ?")
        }
    }

    @TestCase
    public func testTxUpdateVersionedPostConflictActualVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        conn.stmt.queryResult = RowQueryResult(5)
        let tx = Tx(conn)

        let p = VersionedPost()
        p.id = 1
        p.title = "Updated"
        p.version = 1
        try {
            tx.update(p)
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.actual, 5)
            @Expect(e.expected, 1)
        }
    }

    @TestCase
    public func testTxSaveVersionedEventClientPkInjectsVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let e = VersionedEvent()
        e.id = "evt-1"
        e.name = "E"
        tx.save(e)

        @Expect(e.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO versionedEvent (id, name, version)"), true)
    }

    @TestCase
    public func testTxUpdateVersionedEventConflictStringPk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        let tx = Tx(conn)

        let e = VersionedEvent()
        e.id = "evt-1"
        e.version = 1
        try {
            tx.update(e)
            @Fail("expected OptimisticLockException")
        } catch (ex: OptimisticLockException) {
            @Expect(ex.pk, "evt-1")
            @Expect(ex.expected, 1)
            @Expect(ex.actual, -1)
        }
    }

    @TestCase
    public func testTxUpdateVersionedPostWritesVersionInSet(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)

        let p = VersionedPost()
        p.id = 1
        p.version = 3
        tx.update(p)

        let setPart = conn.stmt.capturedSql.split("SET ")[1].split(" WHERE")[0]
        @Expect(setPart.contains("version = version + 1"), true)
        @Expect(setPart.contains("created_at"), true)
        @Expect(p.version, 4)
    }

    @TestCase
    public func testTxSaveVersionedOrderTagInjectsVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let ot = VersionedOrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        ot.quantity = 5
        tx.save(ot)

        @Expect(ot.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO versionedOrderTag (order_id, tag_id, quantity, version)"), true)
    }

    @TestCase
    public func testTxUpdateVersionedOrderTagCompoundPk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)

        let ot = VersionedOrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        ot.quantity = 5
        ot.version = 1
        tx.update(ot)

        @Expect(conn.stmt.capturedSql, "UPDATE versionedOrderTag SET quantity = ?, version = version + 1 WHERE order_id = ? AND tag_id = ? AND version = ?")
        @Expect(ot.version, 2)
    }

    @TestCase
    public func testTxUpdateVersionedOrderTagConflictCompositePk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        conn.stmt.queryResult = RowQueryResult(3)
        let tx = Tx(conn)

        let ot = VersionedOrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        ot.quantity = 5
        ot.version = 1
        try {
            tx.update(ot)
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.pk, "1:2")
            @Expect(e.expected, 1)
            @Expect(e.actual, 3)
        }
    }

    @TestCase
    public func testTxUpdateVersionedPostTwiceNoFalseConflict(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)

        let p = VersionedPost()
        p.id = 1
        p.title = "T"
        p.version = 1
        tx.update(p)
        @Expect(p.version, 2)

        conn.stmt.capturedSetValues.clear()
        conn.stmt.mockRowCount = 1
        tx.update(p)
        @Expect(p.version, 3)

        let lastIdx = conn.stmt.capturedSetValues.size - 1
        var lastParam: Int64 = -1
        match (conn.stmt.capturedSetValues[lastIdx]) {
            case v: Int64 => lastParam = v
            case _ => ()
        }
        @Expect(lastParam, 2)
    }

    @TestCase
    public func testTxUpdateVersionedPostNoOpStillBumpsVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)

        let p = VersionedPost()
        p.id = 1
        p.title = "same"
        p.version = 2
        tx.update(p)

        @Expect(conn.stmt.capturedSql.contains("version = version + 1"), true)
        @Expect(p.version, 3)
    }

    // ─── Versioned Batch Operations ─────────────────────

    @TestCase
    public func testTxBatchSaveVersionedPostInjectsAuditAndVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let p1 = VersionedPost()
        p1.title = "A"
        let p2 = VersionedPost()
        p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(p1.version, 1)
        @Expect(p2.version, 1)
        @Expect(conn.stmt.capturedSql, "INSERT INTO versionedPost (title, created_at, updated_at, version) VALUES (?, ?, ?, ?), (?, ?, ?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 8)
    }

    @TestCase
    public func testTxBatchSaveVersionedEventClientPkInjectsVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let e1 = VersionedEvent()
        e1.id = "evt-1"
        e1.name = "E1"
        let e2 = VersionedEvent()
        e2.id = "evt-2"
        e2.name = "E2"
        tx.batchSave([e1, e2])

        @Expect(e1.version, 1)
        @Expect(e2.version, 1)
        @Expect(conn.stmt.capturedSql, "INSERT INTO versionedEvent (id, name, version) VALUES (?, ?, ?), (?, ?, ?)")
    }

    @TestCase
    public func testTxBatchSaveVersionedOrderTagInjectsVersion(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)

        let ot1 = VersionedOrderTag()
        ot1.order_id = 1
        ot1.tag_id = 2
        ot1.quantity = 5
        let ot2 = VersionedOrderTag()
        ot2.order_id = 3
        ot2.tag_id = 4
        ot2.quantity = 6
        tx.batchSave([ot1, ot2])

        @Expect(ot1.version, 1)
        @Expect(ot2.version, 1)
        @Expect(conn.stmt.capturedSql, "INSERT INTO versionedOrderTag (order_id, tag_id, quantity, version) VALUES (?, ?, ?, ?), (?, ?, ?, ?)")
    }

    @TestCase
    public func testTxBatchUpdateVersionedPostVersionCaseAndRefresh(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 2
        let tx = Tx(conn)

        let p1 = VersionedPost()
        p1.id = 1
        p1.title = "A1"
        p1.version = 1
        let p2 = VersionedPost()
        p2.id = 2
        p2.title = "A2"
        p2.version = 3
        tx.batchUpdate([p1, p2])

        @Expect(conn.stmt.capturedSql, "UPDATE versionedPost SET title = CASE id WHEN ? THEN ? WHEN ? THEN ? END, created_at = CASE id WHEN ? THEN ? WHEN ? THEN ? END, version = CASE id WHEN ? THEN ? WHEN ? THEN ? END, updated_at = CASE id WHEN ? THEN ? WHEN ? THEN ? END WHERE id IN (?, ?)")
        @Expect(conn.stmt.capturedSql.contains("version = CASE"), true)
        @Expect(conn.stmt.capturedSql.contains("updated_at = CASE"), true)
        @Expect(p1.version, 2)
        @Expect(p2.version, 4)
        @Expect(containsInt(conn.stmt.capturedSetValues, 2), true)
        @Expect(containsInt(conn.stmt.capturedSetValues, 4), true)
    }

    @TestCase
    public func testTxBatchUpdateVersionedPostConflict(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)

        let p1 = VersionedPost()
        p1.id = 1
        p1.title = "A"
        p1.version = 1
        let p2 = VersionedPost()
        p2.id = 2
        p2.title = "B"
        p2.version = 1
        try {
            tx.batchUpdate([p1, p2])
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.entityType, "VersionedPost")
            @Expect(e.pk, "batch")
            @Expect(e.expected, 0)
            @Expect(e.actual, -1)
        }
        @Expect(p1.version, 1)
        @Expect(p2.version, 1)
    }

    @TestCase
    public func testTxBatchUpdateVersionedOrderTagVersionCase(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 2
        let tx = Tx(conn)

        let ot1 = VersionedOrderTag()
        ot1.order_id = 1
        ot1.tag_id = 2
        ot1.quantity = 5
        ot1.version = 1
        let ot2 = VersionedOrderTag()
        ot2.order_id = 3
        ot2.tag_id = 4
        ot2.quantity = 6
        ot2.version = 2
        tx.batchUpdate([ot1, ot2])

        @Expect(conn.stmt.capturedSql.contains("version = CASE WHEN order_id = ? AND tag_id = ? THEN ? WHEN order_id = ? AND tag_id = ? THEN ? END"), true)
        @Expect(ot1.version, 2)
        @Expect(ot2.version, 3)
        @Expect(containsInt(conn.stmt.capturedSetValues, 2), true)
        @Expect(containsInt(conn.stmt.capturedSetValues, 3), true)
    }

    @TestCase
    public func testTxUpsertVersionedPostMySQL(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        let tx = Tx(conn, rf, 1)

        let p = VersionedPost()
        p.id = 1
        p.title = "T"
        tx.upsert(p)

        @Expect(p.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `versionedPost` (`id`, `title`, `created_at`, `updated_at`, `version`)"), true)
        @Expect(conn.stmt.capturedSql.contains("ON DUPLICATE KEY UPDATE"), true)
        @Expect(conn.stmt.capturedSql.contains("`version` = `version` + 1"), true)
        @Expect(conn.stmt.capturedSql.contains("`updated_at` = ?"), true)
        @Expect(conn.stmt.capturedSql.contains("`created_at` = VALUES(`created_at`)"), false)
        @Expect(conn.stmt.capturedSetValues.size, 6)
    }

    @TestCase
    public func testTxUpsertVersionedPostPostgres(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), PostgreSQLDialect(), 0)
        let tx = Tx(conn, rf, 0)

        let p = VersionedPost()
        p.id = 1
        p.title = "T"
        tx.upsert(p)

        @Expect(p.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"versionedpost\" (\"id\", \"title\", \"created_at\", \"updated_at\", \"version\")"), true)
        @Expect(conn.stmt.capturedSql.contains("ON CONFLICT (\"id\") DO UPDATE SET"), true)
        @Expect(conn.stmt.capturedSql.contains("\"versionedpost\".\"version\" = \"versionedpost\".\"version\" + 1"), true)
        @Expect(conn.stmt.capturedSql.contains("\"updated_at\" = EXCLUDED.\"updated_at\""), true)
        @Expect(conn.stmt.capturedSql.contains("\"created_at\" = EXCLUDED.\"created_at\""), false)
        @Expect(conn.stmt.capturedSetValues.size, 5)
    }

    @TestCase
    public func testTxUpsertVersionedEventMySQL(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        let tx = Tx(conn, rf, 1)

        let e = VersionedEvent()
        e.id = "evt-1"
        e.name = "E"
        tx.upsert(e)

        @Expect(e.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `versionedEvent` (`id`, `name`, `version`)"), true)
        @Expect(conn.stmt.capturedSql.contains("`version` = `version` + 1"), true)
    }
}

@Test
public class RelationFieldRewriteTest {
    @TestCase
    public func testModifiedFlagsInitiallyFalse(): Unit {
        let p = PostWithRel()
        @Expect(p._authorModified, false)
        @Expect(p._tagsModified, false)
        @Expect(p._commentsModified, false)
    }

    @TestCase
    public func testSetterSetsModifiedFlag(): Unit {
        let p = PostWithRel()
        p.author = Some(User())
        @Expect(p._authorModified, true)

        let p2 = PostWithRel()
        p2.tags = ArrayList<Tag>()
        @Expect(p2._tagsModified, true)

        let p3 = PostWithRel()
        p3.comments = ArrayList<Comment>()
        @Expect(p3._commentsModified, true)
    }

    @TestCase
    public func testRelationPropValueRoundtrip(): Unit {
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p.author = Some(u)
        @Expect(p.author.getOrThrow().id, 42)

        let c = Comment()
        c.id = 7
        p.comments.add(c)
        @Expect(p.comments.size, 1)
        @Expect(p.comments[0].id, 7)
    }

    @TestCase
    public func testScalarFieldsUntouched(): Unit {
        let p = PostWithRel()
        p.title = "hello"
        @Expect(p.title, "hello")
    }
}

private func containsInt(arr: ArrayList<Any>, target: Int64): Bool {
    for (i in 0..arr.size) {
        match (arr[i]) {
            case v: Int64 => if (v == target) { return true }
            case _ => ()
        }
    }
    false
}
