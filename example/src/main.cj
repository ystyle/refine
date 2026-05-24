package demo

import std.database.sql.{Connection, QueryResult, DriverManager}
import std.collection.ArrayList
import refine.*
import mariadb.cdbc.*

struct UserRow {
    var id: Int64 = 0; var name: String = ""; var email: String = ""
    public init(id: Int64, name: String, email: String) {
        this.id = id; this.name = name; this.email = email
    }
}

struct TitleTag {
    var title: String = ""; var tag: String = ""
    public init(title: String, tag: String) { this.title = title; this.tag = tag }
}

var passed = 0; var failed = 0
func ok(c: Bool, msg: String): Unit {
    if (c) { passed++; println("  OK " + msg) }
    else { failed++; println("  FAIL " + msg) }
}
func section(n: String): Unit { println("\n== " + n + " ==") }
func report(): Unit { println("\nResults: " + passed.toString() + " passed, " + failed.toString() + " failed") }

func getConn(): Connection {
    let d = DriverManager.getDriver("mariadb").getOrThrow()
    var opts = ArrayList<(String, String)>()
    opts.add(("username", "refine_test"))
    opts.add(("password", "refine123"))
    opts.add(("database", "refine_test"))
    d.open("mariadb://127.0.0.1:3306", opts.toArray()).connect()
}

func getDialect(): Dialect { MySQLDialect() }

func qr(conn: Connection, sql: String, params: Array<Any>): QueryResult {
    let st = conn.prepareStatement(sql)
    for (i in 0..params.size) {
        let v = params[i]
        match (v) {
            case sv: String => st.set<String>(i, sv)
            case n: Int64 => st.set<Int64>(i, n)
            case b: Bool => st.set<Bool>(i, b)
            case _ => st.setNull(i)
        }
    }
    st.query()
}

main(): Int64 {
    println("Refine ORM Integration Tests (PostgreSQL)\n")
    testConn(); testCRUD(); testWhere(); testOrderLimit()
    testGroupHaving(); testJoin(); testAgg(); testTx()
    report()
    if (failed > 0) { return 1 }
    0
}

func testConn(): Unit { section("Connection"); let c = getConn(); ok(true, "Connect"); c.close() }

func testCRUD(): Unit {
    section("CRUD"); let c = getConn()
    let ins = c.prepareStatement("INSERT INTO users (name, email) VALUES (?, ?) RETURNING id")
    ins.set<String>(0, "Tu"); ins.set<String>(1, "tu@t.com"); let ir = ins.query(); ir.next()
    let uid = ir.get<Int64>(0); ok(uid > 0, "INSERT")
    let sr = qr(c, "SELECT name FROM users WHERE id = ?", [uid]); sr.next()
    ok(sr.get<String>(0) == "Tu", "SELECT")
    let up = c.prepareStatement("UPDATE users SET email = ? WHERE id = ?")
    up.set<String>(0, "uu@t.com"); up.set<Int64>(1, uid); up.update()
    let ur = qr(c, "SELECT email FROM users WHERE id = ?", [uid]); ur.next()
    ok(ur.get<String>(0) == "uu@t.com", "UPDATE")
    let dl = c.prepareStatement("DELETE FROM users WHERE id = ?"); dl.set<Int64>(0, uid); dl.update()
    let dr = qr(c, "SELECT COUNT(*) FROM users WHERE id = ?", [uid]); dr.next()
    ok(dr.get<Int64>(0) == 0, "DELETE"); c.close()
}

func testWhere(): Unit {
    section("WHERE"); let c = getConn(); let d = getDialect(); let s = Session(c)
    let r1 = Query<UserRow>().dialect(d).using(s).select([Column("id"), Column("name"), Column("email")]).from("users")
        .`where`(Binary(Column("name"), Eq, Value("Alice")))
        .all() { res, m => UserRow(res.get<Int64>(m["id"]), res.get<String>(m["name"]), res.get<String>(m["email"])) }
    ok(r1.size == 1, "WHERE name='Alice'")
    let r2 = Query<UserRow>().dialect(d).using(s).select([Column("id")]).from("users")
        .`where`(Binary(Column("name"), Eq, Value("Bob")))
        .all() { res, m => UserRow(res.get<Int64>(m["id"]), "", "") }
    ok(r2.size == 1, "WHERE name='Bob'"); c.close()
}

func testOrderLimit(): Unit {
    section("ORDER BY + LIMIT + OFFSET"); let c = getConn(); let d = getDialect(); let s = Session(c)
    let r1 = Query<UserRow>().dialect(d).using(s).select([Column("id")]).from("users")
        .orderBy([Expr.Ordered(Column("id"), "ASC")])
        .all() { res, m => UserRow(res.get<Int64>(m["id"]), "", "") }
    ok(r1.size >= 2, "ASC"); if (r1.size >= 2) { ok(r1[0].id < r1[1].id, "  asc order") }
    let r2 = Query<UserRow>().dialect(d).using(s).select([Column("id")]).from("users")
        .orderBy([Expr.Ordered(Column("id"), "DESC")]).limit(2)
        .all() { res, m => UserRow(res.get<Int64>(m["id"]), "", "") }
    ok(r2.size == 2, "DESC LIMIT 2")
    let r3 = Query<UserRow>().dialect(d).using(s).select([Column("id")]).from("users")
        .orderBy([Expr.Ordered(Column("id"), "ASC")]).limit(1).offset(1)
        .all() { res, m => UserRow(res.get<Int64>(m["id"]), "", "") }
    ok(r3.size == 1, "OFFSET 1"); c.close()
}

func testGroupHaving(): Unit {
    section("GROUP BY"); let c = getConn(); let d = getDialect(); let s = Session(c)
    let r = Query<UserRow>().dialect(d).using(s).select([Column("user_id"), Raw("COUNT(*)")]).from("posts")
        .groupBy([Column("user_id")]).all() { res, m => UserRow(res.get<Int64>(m["user_id"]), "", "") }
    ok(r.size > 0, "GROUP BY"); c.close()
}

func testJoin(): Unit {
    section("JOIN"); let c = getConn(); let d = getDialect(); let s = Session(c)
    let r = Query<TitleTag>().dialect(d).using(s).select([Column("p.title"), Column("t.name")])
        .from("posts p, post_tags pt, tags t")
        .`where`(Binary(Column("p.id"), Eq, Column("pt.post_id")))
        .`where`(Binary(Column("pt.tag_id"), Eq, Column("t.id")))
        .all() { res, m => TitleTag(res.get<String>(m["title"]), res.get<String>(m["name"])) }
    ok(r.size > 0, "JOIN"); c.close()
}

func testAgg(): Unit {
    section("Aggregations"); let c = getConn(); let d = getDialect(); let s = Session(c)
    let cnt = Query<Int64>().dialect(d).using(s).from("users").count()
    ok(cnt >= 2, "COUNT=" + cnt.toString())
    let hit = Query<Int64>().dialect(d).using(s).from("users")
        .`where`(Binary(Column("name"), Eq, Value("Alice"))).count()
    ok(hit > 0, "WHERE EXISTS")
    let miss = Query<Int64>().dialect(d).using(s).from("users")
        .`where`(Binary(Column("name"), Eq, Value("Nox"))).count()
    ok(miss == 0, "WHERE MISSING"); c.close()
}

func testTx(): Unit {
    section("Transaction"); let c1 = getConn(); let c2 = getConn()
    let tx = c1.createTransaction(); tx.begin()
    let s = c1.prepareStatement("INSERT INTO users (name, email) VALUES (?, ?)")
    s.set<String>(0, "TxU"); s.set<String>(1, "txu@t.com"); s.update(); tx.commit()
    let r = qr(c2, "SELECT COUNT(*) FROM users WHERE email = ?", ["txu@t.com"]); r.next()
    ok(r.get<Int64>(0) > 0, "Commit OK")
    let cl = c2.prepareStatement("DELETE FROM users WHERE email = ?"); cl.set<String>(0, "txu@t.com"); cl.update()

    let tx2 = c1.createTransaction(); tx2.begin()
    let s2 = c1.prepareStatement("INSERT INTO users (name, email) VALUES (?, ?)")
    s2.set<String>(0, "RbU"); s2.set<String>(1, "rbu@t.com"); s2.update(); tx2.rollback()
    let r2 = qr(c2, "SELECT COUNT(*) FROM users WHERE email = ?", ["rbu@t.com"]); r2.next()
    ok(r2.get<Int64>(0) == 0, "Rollback OK"); c1.close(); c2.close()
}
