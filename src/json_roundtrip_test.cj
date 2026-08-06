package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.ColumnInfo
import std.unittest.*
import std.unittest.testmacro.*

// ─── M8-Json Task 3: Json 兜底 struct 字段真实 DB roundtrip 共享实现 ────────────
// 与 snake_roundtrip_test.cj 同构：mysql/pgsql/mariadb 三个集成测试文件各写 thin
// wrapper（只负责 tryXxx() 取连接、执行、关闭），真实链路端到端覆盖：
// autoMigrate 建表（Json 列：SQLite TEXT / MySQL JSON / PG JSONB）→ save（宏层
// jsonToString 序列化 struct → JSON 文本绑定）→ query 读回（rowMapper stringToJson
// 反序列化 JSON 文本 → struct）→ update → batchSave / batchUpdate → upsert。
// 环境守卫由各 wrapper 承担（连不上返回 None 跳过）。
// DROP TABLE 用 dialect.quoteIdentifier：jsonUser 是首字母小写驼峰表名（非全小写
// snake），PG 不加引号会折叠为 jsonuser 而命中不到，MySQL 反引号/PG 双引号均一致。
public func runJsonRoundtrip(rf: Refine): Unit {
    let qtable = rf.getDialect().quoteIdentifier("jsonUser")
    rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS " + qtable, []) }
    let m = rf.migrator()
    m.autoMigrate([JsonUserSchema()])
    @Expect(m.hasTable("jsonUser"), true)

    // a. 单条 save → query 读回：struct 字段值完整（含嵌套 Option<JsonAddress>/集合）
    let u = JsonUser()
    u.name = "alice"
    u.profile = newJsonProfile()
    rf.transaction { tx: Tx => tx.save(u) }
    @Expect(u.id > 0, true)
    let found = JsonUser.query().using(rf).filter(JsonUser.col().id == u.id).one()
    @Expect(found.isSome(), true)
    let back = found.getOrThrow()
    @Expect(back.name, "alice")
    assertProfileFull(back.profile)

    // b. update → 读回：struct 字段经 JSON 文本更新后反序列化完整（tags 清空/address None）
    back.name = "bob"
    back.profile = JsonProfile("Bob", 40, ArrayList<String>(), None, HashMap<String, String>())
    rf.transaction { tx: Tx => tx.update(back) }
    let updated = JsonUser.query().using(rf).filter(JsonUser.col().id == u.id).one()
    @Expect(updated.isSome(), true)
    @Expect(updated.getOrThrow().name, "bob")
    @Expect(updated.getOrThrow().profile.name, "Bob")
    @Expect(updated.getOrThrow().profile.age, 40)
    @Expect(updated.getOrThrow().profile.tags.size, 0)
    @Expect(updated.getOrThrow().profile.address.isNone(), true)

    // c. batchSave：多条含 Json 字段实体批量 INSERT（batch 不回填自增 id，经 name 取回）
    let u1 = JsonUser()
    u1.name = "batch-a"
    u1.profile = JsonProfile("A", 1, tagsOf(["a"]), None, HashMap<String, String>())
    let u2 = JsonUser()
    u2.name = "batch-b"
    u2.profile = JsonProfile("B", 2, ArrayList<String>(), None, HashMap<String, String>())
    rf.transaction { tx: Tx => tx.batchSave([u1, u2]) }
    let b1 = JsonUser.query().using(rf).filter(JsonUser.col().name == "batch-a").one()
    let b2 = JsonUser.query().using(rf).filter(JsonUser.col().name == "batch-b").one()
    @Expect(b1.isSome(), true)
    @Expect(b2.isSome(), true)
    @Expect(b1.getOrThrow().profile.name, "A")
    @Expect(b1.getOrThrow().profile.tags.size, 1)
    @Expect(b1.getOrThrow().profile.tags[0], "a")
    @Expect(b2.getOrThrow().profile.name, "B")

    // batchUpdate：CASE 批量更新 Json 列（每条值独立绑定为 JSON 文本）
    let bu1 = b1.getOrThrow()
    let bu2 = b2.getOrThrow()
    bu1.profile = JsonProfile("A2", 11, ArrayList<String>(), None, HashMap<String, String>())
    bu2.profile = JsonProfile("B2", 12, ArrayList<String>(), None, HashMap<String, String>())
    rf.transaction { tx: Tx => tx.batchUpdate([bu1, bu2]) }
    let bu1Back = JsonUser.query().using(rf).filter(JsonUser.col().id == bu1.id).one()
    let bu2Back = JsonUser.query().using(rf).filter(JsonUser.col().id == bu2.id).one()
    @Expect(bu1Back.getOrThrow().profile.name, "A2")
    @Expect(bu1Back.getOrThrow().profile.age, 11)
    @Expect(bu2Back.getOrThrow().profile.name, "B2")
    @Expect(bu2Back.getOrThrow().profile.age, 12)

    // upsert：冲突时 Json 列被 JSON 文本刷新、行数不增长
    bu1.profile = JsonProfile("A3", 21, tagsOf(["x", "y"]), None, HashMap<String, String>())
    rf.transaction { tx: Tx => tx.upsert(bu1) }
    let all = JsonUser.query().using(rf).all()
    @Expect(all.size, 3)
    let u1Back = JsonUser.query().using(rf).filter(JsonUser.col().id == bu1.id).one()
    @Expect(u1Back.getOrThrow().profile.name, "A3")
    @Expect(u1Back.getOrThrow().profile.age, 21)
    @Expect(u1Back.getOrThrow().profile.tags.size, 2)

    rf.transaction { tx: Tx => tx.execute("DROP TABLE IF EXISTS " + qtable, []) }
}

// newJsonProfile()（json_util_test.cj）的完整字段断言——save 读回后 struct 每一层都保留。
func assertProfileFull(p: JsonProfile): Unit {
    @Expect(p.name, "Alice")
    @Expect(p.age, 30)
    @Expect(p.tags.size, 2)
    @Expect(p.tags.contains("go"), true)
    @Expect(p.tags.contains("rust"), true)
    match (p.address) {
        case Some(a) =>
            @Expect(a.city, "Beijing")
            @Expect(a.zip, 100000)
        case None => @Fail("expected Some address after roundtrip")
    }
    @Expect(p.meta.size, 2)
    @Expect(p.meta.get("k1").getOrThrow(), "v1")
    @Expect(p.meta.get("k2").getOrThrow(), "v2")
}

// 变长 tags 构造助手（JsonProfile 的 ArrayList 字段初始化）。
func tagsOf(values: Array<String>): ArrayList<String> {
    let t = ArrayList<String>()
    for (v in values) { t.add(v) }
    t
}

// 从 mock 捕获的绑定参数中提取 profile 列的 JSON 文本（save 写路径的存储形态）。
func extractProfileJson(conn: CaptureConnection): String {
    match (conn.stmt.capturedSetValues[1]) {
        case v: String => v
        case _ => throw Exception("expected JSON text String param for profile")
    }
}

// ─── M8-Json Task 3: SQLite Json roundtrip（mock 链路，SQLite 无真实驱动依赖）───
// 服务器方言走 runJsonRoundtrip（真实 DB）；SQLite 用现有 CaptureConnection mock
// 验证 SQLite 方言整条 roundtrip 契约：save 写入的 JSON 文本正是 rowMapper 能读回的
// 存储形态——把写路径捕获的绑定值直接喂给读路径 rowMapper，写读共享同一存储格式。
@Test
public class JsonSqliteMockRoundtripTest {
    @TestCase
    public func testSqliteSaveWriteReadShareJsonText(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = JsonUser()
        u.name = "alice"
        u.profile = newJsonProfile()
        tx.save(u)
        @Expect(conn.stmt.capturedSql.contains("\"profile\""), true)
        let jsonText = extractProfileJson(conn)
        @Expect(jsonText.contains("\"name\":\"Alice\""), true)
        // 读路径：同一 JSON 文本经生成 rowMapper 反序列化回 struct
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("profile", false),
        ]
        let row = Array<Any>(3, { i => if (i == 0) { 1 } else if (i == 1) { "alice" } else { jsonText } })
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let e = JsonUserRowMapper(result, buildColumnMap(cols, 0))
        @Expect(e.id, 1)
        @Expect(e.name, "alice")
        @Expect(e.profile.name, "Alice")
        @Expect(e.profile.age, 30)
        @Expect(e.profile.tags.size, 2)
    }

    @TestCase
    public func testSqliteBatchAndUpsertBindJsonText(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = JsonUser()
        u.id = 7
        u.name = "n"
        u.profile = JsonProfile("N", 9, tagsOf(["t"]), None, HashMap<String, String>())
        tx.upsert(u)
        var upsertHasJson = false
        for (v in conn.stmt.capturedSetValues) {
            match (v) {
                case s: String => if (s.contains("\"name\":\"N\"")) { upsertHasJson = true }
                case _ => ()
            }
        }
        @Expect(upsertHasJson, true)
        let conn2 = CaptureConnection()
        let tx2 = sqliteTx(conn2)
        tx2.begin()
        let u1 = JsonUser()
        u1.name = "a"
        u1.profile = JsonProfile("A", 1, ArrayList<String>(), None, HashMap<String, String>())
        let u2 = JsonUser()
        u2.name = "b"
        u2.profile = JsonProfile("B", 2, ArrayList<String>(), None, HashMap<String, String>())
        tx2.batchSave([u1, u2])
        var jsonCount = 0
        for (v in conn2.stmt.capturedSetValues) {
            match (v) {
                case s: String => if (s.contains("\"name\":\"A\"") || s.contains("\"name\":\"B\"")) { jsonCount++ }
                case _ => ()
            }
        }
        @Expect(jsonCount, 2)
    }
}
