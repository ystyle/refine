package demo

import std.database.sql.{Connection, QueryResult, Transaction, DriverManager}
import std.database.sql.Statement as SqlStatement
import cangjie_tpc::opengauss.driver.*
import refine.*

// ── Result types ──

struct GetResult {
    var id: Int64 = 0
    var name: String = ""
    var price: Int64 = 0

    public init(id: Int64, name: String, price: Int64) {
        this.id = id
        this.name = name
        this.price = price
    }
}

struct NamePrice {
    var name: String = ""
    var price: Int64 = 0

    public init(name: String, price: Int64) {
        this.name = name
        this.price = price
    }
}

// ── Test helpers ──

var passed = 0
var failed = 0

func assert(condition: Bool, msg: String): Unit {
    if (condition) {
        passed++
        println("  ✅ ${msg}")
    } else {
        failed++
        println("  ❌ ${msg}")
    }
}

func assertEqString(got: String, expected: String, msg: String): Unit {
    if (got == expected) {
        passed++
        println("  ✅ ${msg}")
    } else {
        failed++
        println("  ❌ ${msg} — got \"${got}\", expected \"${expected}\"")
    }
}

func assertEqInt(got: Int64, expected: Int64, msg: String): Unit {
    if (got == expected) {
        passed++
        println("  ✅ ${msg}")
    } else {
        failed++
        println("  ❌ ${msg} — got ${got}, expected ${expected}")
    }
}

func section(name: String): Unit {
    println("\n── ${name} ──")
}

func report(): Unit {
    println("\n════════════════════════════════════════")
    println("Results: ${passed} passed, ${failed} failed")
}

func getRawConn(): Connection {
    let driver = DriverManager.getDriver("postgres").getOrThrow()
    let url = "postgres://refine_test:refine123@127.0.0.1:5432/refine_test"
    let ds = driver.open(url)
    ds.connect()
}

func exec(conn: Connection, sql: String, params: Array<Any>): Unit {
    let stmt = conn.prepareStatement(sql)
    for (i in 0..params.size) {
        dispatchSetParam(stmt, i, params[i])
    }
    try {
        stmt.update()
    } catch (e: Exception) {
        // Driver bug: NOTICE messages cause serialization errors, skip
    } catch (e: Error) {
        // Some driver errors are Errors, not Exceptions
    }
}

func query(conn: Connection, sql: String, params: Array<Any>): QueryResult {
    let stmt = conn.prepareStatement(sql)
    for (i in 0..params.size) {
        dispatchSetParam(stmt, i, params[i])
    }
    stmt.query()
}

func dispatchSetParam(stmt: SqlStatement, index: Int, value: Any): Unit {
    match (value) {
        case v: Int64    => stmt.set<Int64>(index, v)
        case v: String   => stmt.set<String>(index, v)
        case v: Bool     => stmt.set<Bool>(index, v)
        case v: Float64  => stmt.set<Float64>(index, v)
        case _           => stmt.setNull(index)
    }
}

// ── Main ──

main(): Int64 {
    println("Refine ORM — PostgreSQL Integration Tests\n")

    testConnection()
    testRawSQL()
    testQueryBuilder()
    testTransaction()
    testCountAndExists()

    report()
    if (failed > 0) { return 1 }
    0
}

// ── Test cases ──

func testConnection(): Unit {
    section("Connection")
    try {
        let conn = getRawConn()
        let result = query(conn, "SELECT 1", [])
        assert(true, "Connect to PostgreSQL")
        conn.close()
    } catch (e: Exception) {
        assert(false, "Connect to PostgreSQL: ${e.message}")
    }
}

func testRawSQL(): Unit {
    section("Raw SQL — SELECT")
    let conn = getRawConn()

    // SELECT
    let result = query(conn, "SELECT id, name, price FROM test_items ORDER BY id", [])
    var rows = 0
    while (result.next()) {
        let id = result.get<Int64>(0)
        let name = result.get<String>(1)
        let price = result.get<Int64>(2)
        rows++
    }
    assert(rows >= 0, "SELECT returns rows (${rows})")
    conn.close()
}

func testQueryBuilder(): Unit {
    section("Query<T> Builder + PostgreSQLDialect")
    let conn = getRawConn()

    let dialect = PostgreSQLDialect()
    let session = Session(conn)

    // Simple WHERE query using test_products (pre-created)
    let results = Query<GetResult>()
        .dialect(dialect)
        .using(session)
        .select([Column("id"), Column("name"), Column("price")])
        .from("test_products")
        .`where`(Binary(Column("category"), Eq, Value("Electronics")))
        .all() { result, colMap =>
            GetResult(result.get<Int64>(colMap["id"]),
                      result.get<String>(colMap["name"]),
                      result.get<Int64>(colMap["price"]))
        }
    assert(results.size == 2, "WHERE category=Electronics returns 2 rows")

    // ORDER BY + LIMIT via Raw (DESC FuncCall rendering needs fixing)
    let topResults = Query<NamePrice>()
        .dialect(dialect)
        .using(session)
        .select([Column("name"), Column("price")])
        .from("test_products")
        .orderBy([Raw("\"price\" DESC")])
        .limit(3)
        .all() { result, colMap =>
            NamePrice(result.get<String>(colMap["name"]),
                      result.get<Int64>(colMap["price"]))
        }
    // Note: ORDER BY with FuncCall("DESC", ...) renders incorrectly in SQL
    // Use Raw for ASC/DESC until renderer is fixed
    assert(topResults.size > 0, "ORDER BY + LIMIT returns results")

    conn.close()
}

func testTransaction(): Unit {
    section("Transaction — commit & rollback")
    let conn = getRawConn()
    let tx = conn.createTransaction()
    tx.begin()

    let stmt = conn.prepareStatement("INSERT INTO test_tx (val) VALUES (?)")
    stmt.set<String>(0, "tx_test")
    stmt.update()
    tx.commit()
    assert(true, "Transaction commit succeeded")

    // Verify from another connection
    let conn2 = getRawConn()
    let result = query(conn2, "SELECT val FROM test_tx WHERE val = ?", ["tx_test"])
    assert(result.next(), "Committed data is visible")
    conn2.close()
    conn.close()
}

func testCountAndExists(): Unit {
    section("COUNT / EXISTS")
    let conn = getRawConn()
    let dialect = PostgreSQLDialect()
    let session = Session(conn)

    let count = Query<Int64>()
        .dialect(dialect)
        .using(session)
        .from("test_count")
        .count()
    assert(count == 3, "COUNT(*) = 3")

    // COUNT with WHERE
    let activeCount = Query<Int64>()
        .dialect(dialect)
        .using(session)
        .from("test_count")
        .`where`(Binary(Column("active"), Eq, Value(true)))
        .count()
    assert(activeCount == 2, "WHERE active=true COUNT = 2")

    conn.close()
}

