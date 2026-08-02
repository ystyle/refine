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

@Refine
@Table["custom_tags"]
public class CustomTag {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
@Table["custom_tag_posts"]
public class CustomTagPost {
    var id: Int64 = 0
    var title: String = ""

    @Ref[CustomTag, via: custom_post_tags]
    var tags: ArrayList<CustomTag> = ArrayList<CustomTag>()
}

@Refine
public class UuidTag {
    var id: String = ""
    var name: String = ""
}

@Refine
public class UuidTagPost {
    var id: Int64 = 0
    var title: String = ""

    @Ref[UuidTag, via: uuid_tag_post_tags]
    var tags: ArrayList<UuidTag> = ArrayList<UuidTag>()
}

@Refine
public class UnderscoreFieldEntity {
    var id: Int64 = 0
    var _note: String = ""

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()
}

@Refine
public class UuidRefComment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: String = ""

    @Ref[UuidPost, post_id]
    var post: Option<UuidPost> = None
}

@Refine
public class UuidPostWithRel {
    var id: Int64 = 0
    var title: String = ""

    @Rel[has_many, UuidComment, post_id]
    var comments: ArrayList<UuidComment> = ArrayList<UuidComment>()
}

@Refine
public class UuidComment {
    var id: String = ""
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
public class ProfileWithRel {
    var id: Int64 = 0
    var bio: String = ""
    var user_id: Int64 = 0
}

@Refine
public class UserWithRel {
    var id: Int64 = 0
    var name: String = ""

    @Rel[has_one, ProfileWithRel, user_id]
    var profile: Option<ProfileWithRel> = None
}

@Refine
public class CategoryWithRel {
    var id: Int64 = 0
    var name: String = ""
    var parent_id: Int64 = 0

    @Rel[has_many, CategoryWithRel, parent_id]
    var children: ArrayList<CategoryWithRel> = ArrayList<CategoryWithRel>()
}

@Refine
public class SoftDeleteParent {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0

    @Rel[has_many, SoftDeleteChild, parent_id]
    var children: ArrayList<SoftDeleteChild> = ArrayList<SoftDeleteChild>()
}

@Refine
public class SoftDeleteChild {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
    var parent_id: Int64 = 0
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
    public var capturedSqlHistory: ArrayList<String> = ArrayList<String>()
    public var capturedParams: Array<Any> = []
    public var mockLastInsertId: Int64 = 0
    public var mockRowCount: Int64 = 0
    public var mockLastInsertIdQueue: ArrayList<Int64> = ArrayList<Int64>()
    public var mockRowCountQueue: ArrayList<Int64> = ArrayList<Int64>()
    public var queryResult: QueryResult = MockQueryResult()
    public var queryResultQueue: ArrayList<QueryResult> = ArrayList<QueryResult>()
    public var capturedSetValues: ArrayList<Any> = ArrayList<Any>()

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { _parameterColumnInfos } }
    private var _parameterColumnInfos: Array<ColumnInfo> = []

    public func query(): QueryResult { dequeueQueryResult() }
    public func query(_params: Array<SqlDbType>): QueryResult { dequeueQueryResult() }

    private func dequeueQueryResult(): QueryResult {
        if (queryResultQueue.size > 0) {
            return queryResultQueue.remove(at: 0)
        }
        queryResult
    }

    public func set<T>(index: Int, value: T): Unit {
        capturedSetValues.add(value)
    }
    public func setNull(index: Int): Unit {}
    public func setOption(_key: String, value: String): Unit {}
    public func update(): UpdateResult { CaptureUpdateResult(dequeueLastInsertId(), dequeueRowCount()) }
    public func update(_params: Array<SqlDbType>): UpdateResult { CaptureUpdateResult(dequeueLastInsertId(), dequeueRowCount()) }

    private func dequeueLastInsertId(): Int64 {
        if (mockLastInsertIdQueue.size > 0) { return mockLastInsertIdQueue.remove(at: 0) }
        mockLastInsertId
    }

    private func dequeueRowCount(): Int64 {
        if (mockRowCountQueue.size > 0) { return mockRowCountQueue.remove(at: 0) }
        mockRowCount
    }
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
        stmt.capturedSqlHistory.add(sql)
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

@Refine
public class VersionedOrder {
    var id: Int64 = 0
    var name: String = ""
    @Version
    var version: Int64 = 0

    @Rel[has_many, VersionedOrderItem, order_id]
    var items: ArrayList<VersionedOrderItem> = ArrayList<VersionedOrderItem>()
}

@Refine
public class VersionedOrderItem {
    var id: Int64 = 0
    var name: String = ""
    @Version
    var version: Int64 = 0
    var order_id: Int64 = 0
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

    @TestCase
    public func testRowMapperIncludeDoesNotSetModified(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("title", false)
        let col3: ColumnInfo = MapperMockColumnInfo("user_id", false)
        let col4: ColumnInfo = MapperMockColumnInfo("post_id", false)
        let col5: ColumnInfo = MapperMockColumnInfo("author.id", false)
        let cols: Array<ColumnInfo> = [col1, col2, col3, col4, col5]
        let row = Array<Any>(5, {i => if (i == 0) { 42 } else if (i == 1) { "hello" } else if (i == 2) { 7 } else if (i == 3) { 8 } else { 99 }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let e = PostWithRelRowMapper(result, cm)
        @Expect(e._authorModified, false)
        @Expect(e.author.getOrThrow().id, 99)
    }

    @TestCase
    public func testRelClassIncludeSetterDoesNotSetModified(): Unit {
        let p = PostWithRel()
        let u = User()
        u.id = 55
        PostWithRelRel.authorSetter(p, u)
        @Expect(p._authorModified, false)
        @Expect(p.author.getOrThrow().id, 55)
    }

    @TestCase
    public func testRelClassRefManySetterDoesNotSetModified(): Unit {
        let p = PostWithRel()
        let t = Tag()
        t.id = 7
        PostWithRelRel.tagsSetter(p, t)
        @Expect(p._tagsModified, false)
        @Expect(p.tags.size, 1)
        @Expect(p.tags[0].id, 7)
    }
}

@Test
public class CascadeTraversalTest {
    @TestCase
    public func testCascadePreSaveRefToBackfillsFk(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p.author = Some(u)
        let r = p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 42)
        @Expect(refEq(r, p), true)
    }

    @TestCase
    public func testCascadePreSaveRefToZeroIdClearsFk(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        let u = User()
        p.author = Some(u)
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 0)
    }

    @TestCase
    public func testCascadePreSaveRefToNoneClearsFk(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.user_id = 7
        p.author = None
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 0)
    }

    @TestCase
    public func testCascadePreSaveSkipsWhenNotModified(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p._author = Some(u)
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 0)
    }

    @TestCase
    public func testCascadePreSaveStringFkBackfills(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let c = UuidRefComment()
        let u = UuidPost()
        u.id = "uuid-1"
        c.post = Some(u)
        c.cascadePreSave(tx, ArrayList<Object>())
        @Expect(c.post_id, "uuid-1")
    }

    @TestCase
    public func testCascadePreSaveStringFkClears(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let c = UuidRefComment()
        c.post_id = "old"
        c.post = Some(UuidPost())
        c.cascadePreSave(tx, ArrayList<Object>())
        @Expect(c.post_id, "")
    }

    @TestCase
    public func testCascadePreSaveStringFkNoneClears(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let c = UuidRefComment()
        c.post_id = "old"
        c.post = None
        c.cascadePreSave(tx, ArrayList<Object>())
        @Expect(c.post_id, "")
    }

    @TestCase
    public func testCascadePostSaveHasManyNewChildSaves(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(c.post_id, 5)
        @Expect(conn.stmt.capturedSql, "INSERT INTO comment (body, post_id) VALUES (?, ?)")
    }

    @TestCase
    public func testCascadePostSaveHasManyExistingChildUpdates(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.id = 9
        c.body = "hi"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(c.post_id, 5)
        @Expect(conn.stmt.capturedSql, "UPDATE comment SET body = ?, post_id = ? WHERE id = ?")
    }

    @TestCase
    public func testCascadePostSaveHasManyNotModifiedSkips(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.body = "x"
        p.comments.add(c)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(c.post_id, 0)
    }

    @TestCase
    public func testCascadePostSaveHasOneSavesChild(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let u = UserWithRel()
        u.id = 3
        let pr = ProfileWithRel()
        pr.bio = "bio"
        u.profile = Some(pr)
        u.cascadePostSave(tx, ArrayList<Object>())
        @Expect(pr.user_id, 3)
        @Expect(conn.stmt.capturedSql, "INSERT INTO profileWithRel (bio, user_id) VALUES (?, ?)")
    }

    @TestCase
    public func testCascadePostSaveRefManyRebuilds(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        let list = ArrayList<Tag>()
        list.add(t1)
        list.add(t2)
        p.tags = list
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
    }

    @TestCase
    public func testCascadePostSaveRefManyNotModifiedSkips(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let t = Tag()
        t.id = 7
        p.tags.add(t)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    @TestCase
    public func testCascadePostSaveVisitedSkipsDuplicates(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.body = "x"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        let visited = ArrayList<Object>()
        visited.add(p)
        p.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(c.post_id, 0)
    }

    @TestCase
    public func testCascadePostSaveSkipsVisitedChild(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.body = "x"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        let visited = ArrayList<Object>()
        visited.add(c)
        p.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(c.post_id, 5)
    }

    @TestCase
    public func testCascadePostSaveHasOneSkipsVisitedChild(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let u = UserWithRel()
        u.id = 3
        let pr = ProfileWithRel()
        pr.bio = "b"
        u.profile = Some(pr)
        let visited = ArrayList<Object>()
        visited.add(pr)
        u.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(pr.user_id, 3)
    }

    @TestCase
    public func testCascadePreSaveRefToResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p.author = Some(u)
        @Expect(p._authorModified, true)
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 42)
        @Expect(p._authorModified, false)
    }

    @TestCase
    public func testCascadePostSaveHasManyResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        @Expect(p._commentsModified, true)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(c.post_id, 5)
        @Expect(p._commentsModified, false)
    }

    @TestCase
    public func testCascadePostSaveHasOneResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let u = UserWithRel()
        u.id = 3
        let pr = ProfileWithRel()
        pr.bio = "bio"
        u.profile = Some(pr)
        @Expect(u._profileModified, true)
        u.cascadePostSave(tx, ArrayList<Object>())
        @Expect(pr.user_id, 3)
        @Expect(u._profileModified, false)
    }

    @TestCase
    public func testCascadePostSaveRefManyResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let t1 = Tag()
        t1.id = 7
        let list = ArrayList<Tag>()
        list.add(t1)
        p.tags = list
        @Expect(p._tagsModified, true)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(p._tagsModified, false)
    }

    @TestCase
    public func testCascadeCycleSaveNoDuplicateInsert(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let a = CategoryWithRel()
        a.id = 1
        let b = CategoryWithRel()
        let la = ArrayList<CategoryWithRel>()
        la.add(b)
        a.children = la
        let lb = ArrayList<CategoryWithRel>()
        lb.add(a)
        b.children = lb
        let visited = ArrayList<Object>()
        a.cascadePostSave(tx, visited)
        b.cascadePostSave(tx, visited)
        a.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 1)
    }

    @TestCase
    public func testCascadeDiamondSaveNoDuplicateSharedChild(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = CategoryWithRel()
        p.id = 1
        let c1 = CategoryWithRel()
        let c2 = CategoryWithRel()
        let d = CategoryWithRel()
        let lp = ArrayList<CategoryWithRel>()
        lp.add(c1)
        lp.add(c2)
        p.children = lp
        let l1 = ArrayList<CategoryWithRel>()
        l1.add(d)
        c1.children = l1
        let l2 = ArrayList<CategoryWithRel>()
        l2.add(d)
        c2.children = l2
        let visited = ArrayList<Object>()
        p.cascadePostSave(tx, visited)
        c1.cascadePostSave(tx, visited)
        d.cascadePostSave(tx, visited)
        c2.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
    }

    @TestCase
    public func testCascadeDeleteChildrenThenJunction(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("body", false), MapperMockColumnInfo("post_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "hi" } else { 5 }})])
        p.cascadeDelete(tx, ArrayList<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM comment WHERE post_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM comment WHERE id = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 9)
    }

    @TestCase
    public func testCascadeDeleteHasOneViaQuery(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let u = UserWithRel()
        u.id = 3
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("bio", false), MapperMockColumnInfo("user_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 7 } else if (i == 1) { "b" } else { 3 }})])
        u.cascadeDelete(tx, ArrayList<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM profileWithRel WHERE user_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM profileWithRel WHERE id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 3)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
    }

    @TestCase
    public func testCascadeDeleteRecursiveGrandchildren(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("parent_id", false)]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "c" } else { 5 }})]))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 12 } else if (i == 1) { "g" } else { 9 }})]))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, []))
        let root = CategoryWithRel()
        root.id = 5
        root.cascadeDelete(tx, ArrayList<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 5)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM categoryWithRel WHERE parent_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "SELECT * FROM categoryWithRel WHERE parent_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "SELECT * FROM categoryWithRel WHERE parent_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[3], "DELETE FROM categoryWithRel WHERE id = ?")
        @Expect(conn.stmt.capturedSqlHistory[4], "DELETE FROM categoryWithRel WHERE id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 12)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 9)
    }

    @TestCase
    public func testCascadeDeleteDbCycleTerminates(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("parent_id", false)]
        // DB 常驻环：A(id=5) → B(id=9) → A'(id=5) → ... 每次 loadX 都新建实体实例，
        // 对象引用（refEq）永远匹配不上，必须靠 (type,id) 键终止递归
        let bRow = Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "b" } else { 5 }})
        let aRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { "a" } else { 9 }})
        for (i in 0..6) {
            let row = if (i % 2 == 0) { bRow } else { aRow }
            conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [row]))
        }
        let root = CategoryWithRel()
        root.id = 5
        root.cascadeDelete(tx, ArrayList<String>())
        // 环在第二层被 "CategoryWithRel:5" 键命中即返回，且 deleteCascade 操作层守卫阻止对
        // A'(id=5)（与 root 同 (type,id) 的副本行）重复 DELETE：仅 2 次 SELECT + 1 次 DELETE(B)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM categoryWithRel WHERE parent_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "SELECT * FROM categoryWithRel WHERE parent_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM categoryWithRel WHERE id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 9)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 9)
    }

    @TestCase
    public func testCascadeDeleteVisitedSkipsAlreadySeen(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let visited = ArrayList<String>()
        visited.add("PostWithRel:5")
        p.cascadeDelete(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    @TestCase
    public func testCascadeDeleteRefToNotProcessed(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let c = UuidRefComment()
        c.id = 3
        let u = UuidPost()
        u.id = "uuid-1"
        c.post = Some(u)
        c.cascadeDelete(tx, ArrayList<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    @TestCase
    public func testRowMapperIncludeStringPkRefTo(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("body", false)
        let col3: ColumnInfo = MapperMockColumnInfo("post_id", false)
        let col4: ColumnInfo = MapperMockColumnInfo("post.id", false)
        let cols: Array<ColumnInfo> = [col1, col2, col3, col4]
        let row = Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "hello" } else if (i == 2) { "uuid-9" } else { "uuid-99" }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let e = UuidRefCommentRowMapper(result, cm)
        @Expect(e.post_id, "uuid-9")
        @Expect(e.post.getOrThrow().id, "uuid-99")
    }
}

@Test
public class UnderscoreFieldEntityTest {
    @TestCase
    public func testUnderscoreFieldInCols(): Unit {
        let cols = UnderscoreFieldEntity.col()
        @Expect(cols._note.name, "_note")
        @Expect(cols.id.name, "id")
    }

    @TestCase
    public func testUnderscoreFieldInColumnNames(): Unit {
        let names = UnderscoreFieldEntityColumnNames()
        var found = false
        for (c in names) {
            if (c.name == "_note") { found = true }
        }
        @Expect(found, true)
        @Expect(names.size, 2)
    }

    @TestCase
    public func testUnderscoreFieldMappedByRowMapper(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("_note", false)
        let row = Array<Any>(2, {i => if (i == 0) { 42 } else { "internal" }})
        let result = MapperMockQueryResult([col1, col2], [row])
        result.next()
        let cm = buildColumnMap([col1, col2])
        let e = UnderscoreFieldEntityRowMapper(result, cm)
        @Expect(e.id, 42)
        @Expect(e._note, "internal")
    }
}

@Test
public class RefManyRelationApiTest {
    @TestCase
    public func testAppendTagsSingle(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        t.id = 7
        let r = p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
        r.clearTags(tx)
        @Expect(conn.stmt.capturedSql, "DELETE FROM post_tags WHERE postWithRel_id = ?")
    }

    @TestCase
    public func testAppendTagsArray(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        p.appendTags(tx, [t1, t2])
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 4)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 8)
    }

    @TestCase
    public func testReplaceTags(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        p.replaceTags(tx, [t1, t2])
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 8)
    }

    @TestCase
    public func testDeleteTagsSingle(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        t.id = 7
        p.deleteTags(tx, t)
        @Expect(conn.stmt.capturedSql, "DELETE FROM post_tags WHERE postWithRel_id = ? AND tag_id = ?")
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
    }

    @TestCase
    public func testDeleteTagsArray(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        p.deleteTags(tx, [t1, t2])
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "DELETE FROM post_tags WHERE postWithRel_id = ? AND tag_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM post_tags WHERE postWithRel_id = ? AND tag_id = ?")
        @Expect(conn.stmt.capturedSetValues.size, 4)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 8)
    }

    @TestCase
    public func testClearTags(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        p.clearTags(tx)
        @Expect(conn.stmt.capturedSql, "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(conn.stmt.capturedSetValues.size, 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
    }

    @TestCase
    public func testCountTags(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let col: ColumnInfo = MapperMockColumnInfo("COUNT(*)", false)
        conn.stmt.queryResult = MapperMockQueryResult([col], [Array<Any>(1, {i => 5})])
        let n = p.countTags(tx)
        @Expect(n, 5)
        @Expect(conn.stmt.capturedSql, "SELECT COUNT(*) FROM post_tags WHERE postWithRel_id = ?")
        @Expect(conn.stmt.capturedSetValues.size, 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
    }

    @TestCase
    public func testAppendTagsUnsavedThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        try {
            p.appendTags(tx, t)
            @Fail("expected exception for unsaved target")
        } catch (e: Exception) {
            @Expect(e.message, "ref_many tags: target Tag has empty id, save it first")
        }
    }

    @TestCase
    public func testDeleteTagsUnsavedThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        try {
            p.deleteTags(tx, t)
            @Fail("expected exception for unsaved target")
        } catch (e: Exception) {
            @Expect(e.message, "ref_many tags: target Tag has empty id, save it first")
        }
    }
}

@Test
public class RefManyTableOverrideTest {
    @TestCase
    public func testJunctionSchemaColumnsUseLowerTargetName(): Unit {
        let js = CustomTagPost_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols.size, 2)
        @Expect(cols[0].name, "custom_tag_posts_id")
        @Expect(cols[1].name, "customTag_id")
    }

    @TestCase
    public func testAppendTagsUsesJunctionColumnNames(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = CustomTagPost()
        p.id = 42
        let t = CustomTag()
        t.id = 7
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO custom_post_tags (custom_tag_posts_id, customTag_id) VALUES (?, ?)")
    }

    @TestCase
    public func testDeleteTagsUsesJunctionColumnNames(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = CustomTagPost()
        p.id = 42
        let t = CustomTag()
        t.id = 7
        p.deleteTags(tx, t)
        @Expect(conn.stmt.capturedSql, "DELETE FROM custom_post_tags WHERE custom_tag_posts_id = ? AND customTag_id = ?")
    }

    @TestCase
    public func testLoadTagsUsesJunctionColumnNames(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = CustomTagPost()
        p.id = 42
        p.loadTags(tx)
        @Expect(conn.stmt.capturedSql.contains("custom_post_tags.customTag_id"), true)
        @Expect(conn.stmt.capturedSql.contains("custom_post_tags.custom_tags_id"), false)
        @Expect(conn.stmt.capturedSql.contains("custom_post_tags.custom_tag_posts_id"), true)
    }
}

@Test
public class RefManyStringPkTargetTest {
    @TestCase
    public func testAppendUnsavedStringPkTargetThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        try {
            p.appendTags(tx, t)
            @Fail("expected exception for unsaved String-pk target")
        } catch (e: Exception) {
            @Expect(e.message.contains("has empty id"), true)
        }
    }

    @TestCase
    public func testDeleteUnsavedStringPkTargetThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        try {
            p.deleteTags(tx, t)
            @Fail("expected exception for unsaved String-pk target")
        } catch (e: Exception) {
            @Expect(e.message.contains("has empty id"), true)
        }
    }

    @TestCase
    public func testAppendSavedStringPkTargetWritesId(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        t.id = "uuid-tag-1"
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        match (conn.stmt.capturedSetValues[1]) {
            case v: String => @Expect(v, "uuid-tag-1")
            case _ => @Fail("expected String tag id param")
        }
    }
}

// ─── Tx.save/update/delete 级联接线 ───────────────────────

@Test
public class TxCascadeTest {
    @TestCase
    public func testTxSaveCascadesHasManyBackfillsFk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = Tx(conn)
        let p = PostWithRel()
        let c = Comment()
        c.body = "hello"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO postWithRel (title, user_id, post_id) VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO comment (body, post_id) VALUES (?, ?)")
        @Expect(p.id, 42)
        @Expect(c.post_id, 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 42)
    }

    @TestCase
    public func testTxSaveCascadesHasOneBackfillsFk(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 7
        let tx = Tx(conn)
        let u = UserWithRel()
        let pr = ProfileWithRel()
        pr.bio = "b"
        u.profile = Some(pr)
        tx.save(u)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO userWithRel (name) VALUES (?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO profileWithRel (bio, user_id) VALUES (?, ?)")
        @Expect(u.id, 7)
        @Expect(pr.user_id, 7)
    }

    @TestCase
    public func testTxUpdateCascadesChildInsertAndUpdate(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let existing = Comment()
        existing.id = 9
        existing.body = "updated"
        let fresh = Comment()
        fresh.body = "new"
        let list = ArrayList<Comment>()
        list.add(existing)
        list.add(fresh)
        p.comments = list
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE postWithRel SET title = ?, user_id = ?, post_id = ? WHERE id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "UPDATE comment SET body = ?, post_id = ? WHERE id = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO comment (body, post_id) VALUES (?, ?)")
        @Expect(existing.post_id, 5)
        @Expect(fresh.post_id, 5)
    }

    @TestCase
    public func testTxDeleteCascadesChildrenThenParent(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("body", false), MapperMockColumnInfo("post_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "hi" } else { 5 }})])
        tx.delete(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 4)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM comment WHERE post_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM comment WHERE id = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[3], "DELETE FROM postWithRel WHERE id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 9)
    }

    @TestCase
    public func testTxDeleteSoftDeleteCascadesChildren(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = SoftDeleteParent()
        p.id = 1
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("deleted_at", false), MapperMockColumnInfo("parent_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(4, {i => if (i == 0) { 2 } else if (i == 1) { "c" } else if (i == 2) { 0 } else { 1 }})])
        tx.delete(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM softDeleteChild WHERE parent_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1].contains("UPDATE softDeleteChild SET deleted_at"), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("UPDATE softDeleteParent SET deleted_at"), true)
    }

    @TestCase
    public func testTxSaveCycleNoDuplicateInsertSharedVisited(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let a = CategoryWithRel()
        let b = CategoryWithRel()
        let la = ArrayList<CategoryWithRel>()
        la.add(b)
        a.children = la
        let lb = ArrayList<CategoryWithRel>()
        lb.add(a)
        b.children = lb
        tx.save(a)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
    }

    @TestCase
    public func testTxSaveRefToBackfillsFkBeforeInsert(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = PostWithRel()
        let u = User()
        u.id = 5
        p.author = Some(u)
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO postWithRel (title, user_id, post_id) VALUES (?, ?, ?)")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 5)
    }

    @TestCase
    public func testCascadeRefToGhostThenSaveTargetDoesNotBackfill(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertIdQueue.add(1)   // p.id
        conn.stmt.mockLastInsertIdQueue.add(2)   // u.id
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)
        let p = PostWithRel()
        let u = User()
        u.name = "ghost"
        p.author = Some(u)                       // u.id == 0，幽灵对象
        @Expect(p._authorModified, true)
        tx.save(p)
        @Expect(p.id, 1)
        @Expect(p.user_id, 0)                    // 幽灵对象按清空处理
        @Expect(p._authorModified, false)        // 标记已复位
        // 后存目标得 id → update 不再回填（一次性语义）
        tx.save(u)
        @Expect(u.id, 2)
        tx.update(p)
        @Expect(p.user_id, 0)                    // 不回填，user_id 保持 0
        // 重新整体赋值 → 回填
        p.author = Some(u)
        @Expect(p._authorModified, true)
        tx.update(p)
        @Expect(p.user_id, 2)
        @Expect(p._authorModified, false)
    }

    @TestCase
    public func testTxUpdateNoCascadeWhenRelsNotModified(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        p.title = "x"
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE postWithRel SET title = ?, user_id = ?, post_id = ? WHERE id = ?")
    }

    @TestCase
    public func testTxSaveResetsMarkersThenUpdateDoesNotReplay(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = Tx(conn)
        let p = PostWithRel()
        let c = Comment()
        c.body = "hello"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        @Expect(p._commentsModified, true)
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(p._commentsModified, false)
        // 标记已复位：再次 update 不重放子列表
        conn.stmt.mockRowCount = 1
        p.title = "changed"
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[2], "UPDATE postWithRel SET title = ?, user_id = ?, post_id = ? WHERE id = ?")
    }

    @TestCase
    public func testTxSaveResetsMarkersThenUpdateReplayAfterReassign(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = Tx(conn)
        let p = PostWithRel()
        let c = Comment()
        c.body = "hello"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        tx.save(p)
        @Expect(p._commentsModified, false)
        // 再次整体赋值 → 标记置位 → update 重放
        let c2 = Comment()
        c2.body = "world"
        let list2 = ArrayList<Comment>()
        list2.add(c)
        list2.add(c2)
        p.comments = list2
        @Expect(p._commentsModified, true)
        conn.stmt.mockRowCount = 1
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 5)
        @Expect(conn.stmt.capturedSqlHistory[3], "UPDATE comment SET body = ?, post_id = ? WHERE id = ?")
        @Expect(conn.stmt.capturedSqlHistory[4], "INSERT INTO comment (body, post_id) VALUES (?, ?)")
        @Expect(p._commentsModified, false)
    }

    @TestCase
    public func testTxSaveRefManyRebuildsJunction(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = Tx(conn)
        let p = PostWithRel()
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        let list = ArrayList<Tag>()
        list.add(t1)
        list.add(t2)
        p.tags = list
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 4)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO postWithRel (title, user_id, post_id) VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[3], "INSERT INTO post_tags (postWithRel_id, tag_id) VALUES (?, ?)")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 42)
    }
}

// ─── 级联边界用例 ──────────────────────────────────────
// 覆盖设计文档第 2/4/7 节的边界：加载后未修改不级联、两个无 id 新对象互不误判、
// 空列表标记 true 的语义、三层深链、级联子对象乐观锁

@Test
public class CascadeBoundaryTest {
    @TestCase
    public func testTxUpdateLoadedEntityNoCascade(): Unit {
        clearHooks()
        // rowMapper 从库加载实体（含 ref_to include），关联字段标记必须保持 false
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("title", false)
        let col3: ColumnInfo = MapperMockColumnInfo("user_id", false)
        let col4: ColumnInfo = MapperMockColumnInfo("post_id", false)
        let col5: ColumnInfo = MapperMockColumnInfo("author.id", false)
        let cols: Array<ColumnInfo> = [col1, col2, col3, col4, col5]
        let row = Array<Any>(5, {i => if (i == 0) { 5 } else if (i == 1) { "loaded" } else if (i == 2) { 7 } else if (i == 3) { 0 } else { 99 }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let e = PostWithRelRowMapper(result, cm)
        @Expect(e._authorModified, false)
        @Expect(e._tagsModified, false)
        @Expect(e._commentsModified, false)
        @Expect(e.author.getOrThrow().id, 99)

        // 仅加载未修改 → update 只发父 UPDATE，无 fk 改动 / 无子落库 / 无中间表重建
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)
        tx.update(e)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE postWithRel SET title = ?, user_id = ?, post_id = ? WHERE id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 5)
    }

    @TestCase
    public func testTxSaveTwoNewChildrenBothSaved(): Unit {
        clearHooks()
        // 两个不同实例的新子对象（都 id=0）不得被 visited 按 (type,id) 误判为同一对象
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = Tx(conn)
        let p = PostWithRel()
        let c1 = Comment()
        c1.body = "one"
        let c2 = Comment()
        c2.body = "two"
        let list = ArrayList<Comment>()
        list.add(c1)
        list.add(c2)
        p.comments = list
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO postWithRel (title, user_id, post_id) VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO comment (body, post_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO comment (body, post_id) VALUES (?, ?)")
        @Expect(p.id, 42)
        @Expect(c1.post_id, 42)
        @Expect(c2.post_id, 42)
        @Expect(capturedString(conn.stmt.capturedSetValues, 3), "one")
        @Expect(capturedString(conn.stmt.capturedSetValues, 5), "two")
    }

    @TestCase
    public func testTxSaveHasManyEmptyListNoChildInsert(): Unit {
        clearHooks()
        // 标记 true 且 has_many 列表为空 → save 无子对象要存（只父 INSERT）
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = Tx(conn)
        let p = PostWithRel()
        p.comments = ArrayList<Comment>()
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO postWithRel (title, user_id, post_id) VALUES (?, ?, ?)")
    }

    @TestCase
    public func testTxUpdateHasManyEmptyListNoChildDelete(): Unit {
        clearHooks()
        // 标记 true 且 has_many 列表为空 → update 不删现有（不自动清库）
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        p.comments = ArrayList<Comment>()
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE postWithRel SET title = ?, user_id = ?, post_id = ? WHERE id = ?")
    }

    @TestCase
    public func testTxSaveRefManyEmptyListClearsJunction(): Unit {
        clearHooks()
        // 标记 true 且 ref_many 列表为空 → save 清空中间表（DELETE 旧关联，无 INSERT）
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = Tx(conn)
        let p = PostWithRel()
        p.tags = ArrayList<Tag>()
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO postWithRel (title, user_id, post_id) VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 42)
    }

    @TestCase
    public func testTxUpdateRefManyEmptyListClearsJunction(): Unit {
        clearHooks()
        // 标记 true 且 ref_many 列表为空 → update 清空中间表（重建为空 = 清旧关联）
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)
        let p = PostWithRel()
        p.id = 5
        p.tags = ArrayList<Tag>()
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE postWithRel SET title = ?, user_id = ?, post_id = ? WHERE id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM post_tags WHERE postWithRel_id = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 5)
    }

    @TestCase
    public func testTxSaveThreeLevelDeepChain(): Unit {
        clearHooks()
        // 三层嵌套：root → l2 → l3，自动递归，fk 逐层回填正确
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertIdQueue.add(10)
        conn.stmt.mockLastInsertIdQueue.add(11)
        conn.stmt.mockLastInsertIdQueue.add(12)
        let tx = Tx(conn)
        let root = CategoryWithRel()
        root.name = "root"
        let l2 = CategoryWithRel()
        l2.name = "l2"
        let l3 = CategoryWithRel()
        l3.name = "l3"
        let l2List = ArrayList<CategoryWithRel>()
        l2List.add(l2)
        root.children = l2List
        let l3List = ArrayList<CategoryWithRel>()
        l3List.add(l3)
        l2.children = l3List
        tx.save(root)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO categoryWithRel (name, parent_id) VALUES (?, ?)")
        @Expect(root.id, 10)
        @Expect(l2.id, 11)
        @Expect(l3.id, 12)
        @Expect(l2.parent_id, 10)
        @Expect(l3.parent_id, 11)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 10)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 5), 11)
    }

    @TestCase
    public func testTxUpdateCascadesVersionedChildIncrementsVersion(): Unit {
        clearHooks()
        // 级联 update 子对象带乐观锁：子 UPDATE 含 version 校验并递增
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = Tx(conn)
        let order = VersionedOrder()
        order.id = 1
        order.name = "o"
        order.version = 1
        let item = VersionedOrderItem()
        item.id = 7
        item.name = "old"
        item.version = 1
        let list = ArrayList<VersionedOrderItem>()
        list.add(item)
        order.items = list
        tx.update(order)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE versionedOrder SET name = ?, version = version + 1 WHERE id = ? AND version = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "UPDATE versionedOrderItem SET name = ?, order_id = ?, version = version + 1 WHERE id = ? AND version = ?")
        @Expect(order.version, 2)
        @Expect(item.version, 2)
        @Expect(item.order_id, 1)
    }

    @TestCase
    public func testTxUpdateCascadeVersionedChildConflictThrows(): Unit {
        clearHooks()
        // 级联 update 子对象乐观锁冲突：父成功、子 rowCount=0 → 抛 OptimisticLockException
        let conn = CaptureConnection()
        conn.stmt.mockRowCountQueue.add(1)
        conn.stmt.mockRowCountQueue.add(0)
        let tx = Tx(conn)
        let order = VersionedOrder()
        order.id = 1
        order.version = 1
        let item = VersionedOrderItem()
        item.id = 7
        item.name = "old"
        item.version = 1
        let list = ArrayList<VersionedOrderItem>()
        list.add(item)
        order.items = list
        try {
            tx.update(order)
            @Fail("expected OptimisticLockException from cascade child update")
        } catch (e: OptimisticLockException) {
            @Expect(e.entityType, "VersionedOrderItem")
            @Expect(e.expected, 1)
            @Expect(e.actual, -1)
        }
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("versionedOrderItem"), true)
        @Expect(conn.stmt.capturedSqlHistory[2], "SELECT version FROM versionedOrderItem WHERE id = ?")
    }

    @TestCase
    public func testTxSaveCascadesNewVersionedChildInitsVersion(): Unit {
        clearHooks()
        // 级联 save 子对象（无 id）：version 0→1 初始化、父 id 回填子 fk、子 INSERT 带 version 列
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertIdQueue.add(1)
        conn.stmt.mockLastInsertIdQueue.add(2)
        let tx = Tx(conn)
        let order = VersionedOrder()
        order.name = "o"
        let item = VersionedOrderItem()
        item.name = "fresh"
        let list = ArrayList<VersionedOrderItem>()
        list.add(item)
        order.items = list
        tx.save(order)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO versionedOrder (name, version) VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO versionedOrderItem (name, version, order_id) VALUES (?, ?, ?)")
        @Expect(order.id, 1)
        @Expect(order.version, 1)
        @Expect(item.id, 2)
        @Expect(item.version, 1)
        @Expect(item.order_id, 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 1)
    }
}

// ─── delete 钩子 abort 不删子 + physicalDelete 级联 ────────

@Test
public class TxDeleteHookAbortTest {
    @TestCase
    public func testTxDeleteHookAbortSkipsCascadeDelete(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        let p = PostWithRel()
        p.id = 5
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("body", false), MapperMockColumnInfo("post_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "hi" } else { 5 }})])
        rf.hook<PostWithRel>("PostWithRel", HookKind.TxBeforeDelete) { scope: Scope<PostWithRel> =>
            scope.abort(Exception("blocked"))
        }
        try {
            tx.delete(p)
            @Fail("expected abort exception")
        } catch (e: Exception) {
            @Expect(e.message, "blocked")
        }
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }
}

@Test
public class TxPhysicalDeleteCascadeTest {
    @TestCase
    public func testTxPhysicalDeleteCascadesChildren(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let p = SoftDeleteParent()
        p.id = 1
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("deleted_at", false), MapperMockColumnInfo("parent_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(4, {i => if (i == 0) { 2 } else if (i == 1) { "c" } else if (i == 2) { 0 } else { 1 }})])
        tx.physicalDelete(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM softDeleteChild WHERE parent_id = ?")
        @Expect(conn.stmt.capturedSqlHistory[1].contains("UPDATE softDeleteChild SET deleted_at"), true)
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM softDeleteParent WHERE id = ?")
    }
}

// ─── C2: include 预加载基于字段子集装配（缺列不抛异常/丢行） ──

@Test
public class C2IncludePreloadTest {
    @TestCase
    public func testRefToIncludeDefaultAllColumns(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
            MapperMockColumnInfo("post.id", false),
            MapperMockColumnInfo("post.title", false),
            MapperMockColumnInfo("post.content", false),
        ]
        let row = Array<Any>(6, {i =>
            if (i == 0) { 5 } else if (i == 1) { "nice" } else if (i == 2) { "p1" }
            else if (i == 3) { "p1" } else if (i == 4) { "First" } else { "Hello" }
        })
        conn.stmt.queryResult = MapperMockQueryResult(cols, [row])
        let q = UuidRefComment.query().include(UuidRefCommentRel.post).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].post.isSome(), true)
        let post = entities[0].post.getOrThrow()
        @Expect(post.id, "p1")
        @Expect(post.title, "First")
        @Expect(post.content, "Hello")
    }

    @TestCase
    public func testRefToIncludeSubsetFieldsNoThrow(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
            MapperMockColumnInfo("post.id", false),
            MapperMockColumnInfo("post.title", false),
        ]
        let row = Array<Any>(5, {i =>
            if (i == 0) { 5 } else if (i == 1) { "nice" } else if (i == 2) { "p1" }
            else if (i == 3) { "p1" } else { "First" }
        })
        conn.stmt.queryResult = MapperMockQueryResult(cols, [row])
        let rel = RefTo<UuidPost>("post", Col<Any>("post_id"),
            [Col<Any>("id"), Col<Any>("title")], "uuidPost",
            UuidRefCommentRel.postMapper, UuidRefCommentRel.postSetter)
        let q = UuidRefComment.query().include(rel, [Col<Any>("id"), Col<Any>("title")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        let post = entities[0].post.getOrThrow()
        @Expect(post.id, "p1")
        @Expect(post.title, "First")
        @Expect(post.content, "")
    }

    @TestCase
    public func testRefToIncludeNullTargetKeepsRow(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        // 模拟 LEFT JOIN 无匹配：目标列缺失（target id 不在结果集中）
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let row = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "orphan" } else { "nope" }
        })
        conn.stmt.queryResult = MapperMockQueryResult(cols, [row])
        let rel = RefTo<UuidPost>("post", Col<Any>("post_id"),
            [Col<Any>("id"), Col<Any>("title")], "uuidPost",
            UuidRefCommentRel.postMapper, UuidRefCommentRel.postSetter)
        let q = UuidRefComment.query().include(rel, [Col<Any>("id"), Col<Any>("title")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].post.isNone(), true)
    }

    @TestCase
    public func testHasManyIncludeSubsetFieldsNoThrow(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("comments.id", false),
            MapperMockColumnInfo("comments.body", false),
        ]
        let rows = [
            Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post" } else if (i == 2) { "c1" } else { "first" }}),
            Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post" } else if (i == 2) { "c2" } else { "second" }}),
        ]
        conn.stmt.queryResult = MapperMockQueryResult(cols, rows)
        let rel = HasMany<UuidComment>("comments", "post_id",
            [Col<Any>("id"), Col<Any>("body")], "uuidComment",
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter)
        let q = UuidPostWithRel.query().include(rel, [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        let cs = entities[0].comments
        @Expect(cs.size, 2)
        @Expect(cs[0].id, "c1")
        @Expect(cs[0].body, "first")
        @Expect(cs[0].post_id, 0)
        @Expect(cs[1].id, "c2")
        @Expect(cs[1].body, "second")
    }

    @TestCase
    public func testRefManyIncludeSubsetFieldsNoThrow(): Unit {
        clearHooks()
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("tags.id", false),
        ]
        let rows = [
            Array<Any>(3, {i => if (i == 0) { 3 } else if (i == 1) { "post1" } else { "t1" }}),
            Array<Any>(3, {i => if (i == 0) { 3 } else if (i == 1) { "post1" } else { "t2" }}),
        ]
        conn.stmt.queryResult = MapperMockQueryResult(cols, rows)
        let rel = RefMany<UuidTag>("tags", "uuid_tag_post_tags",
            [Col<Any>("id")], "uuidTag",
            UuidTagRowMapper, UuidTagPostRel.tagsSetter)
        let q = UuidTagPost.query().include(rel, [Col<Any>("id")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        let ts = entities[0].tags
        @Expect(ts.size, 2)
        @Expect(ts[0].id, "t1")
        @Expect(ts[0].name, "")
        @Expect(ts[1].id, "t2")
    }

    @TestCase
    public func testRowMapperToleratesMissingColumns(): Unit {
        // 直接验证生成的 RowMapper 对字段子集宽容：缺列不抛异常、选中填充、未选中默认
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("email", false)]
        let row = Array<Any>(2, {i => if (i == 0) { 99 } else { "bob@x.com" }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let u = UserRowMapper(result, cm)
        @Expect(u.id, 99)
        @Expect(u.email, "bob@x.com")
        @Expect(u.name, "")
    }
}

private func capturedInt64(arr: ArrayList<Any>, index: Int64): Int64 {
    match (arr[index]) {
        case v: Int64 => v
        case _ => throw Exception("param " + index.toString() + " is not Int64")
    }
}

private func capturedString(arr: ArrayList<Any>, index: Int64): String {
    match (arr[index]) {
        case v: String => v
        case _ => throw Exception("param " + index.toString() + " is not String")
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
