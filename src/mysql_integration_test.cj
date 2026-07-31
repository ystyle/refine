package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.QueryResult
import std.unittest.*
import std.unittest.testmacro.*
import refine.macros.*
import mariadb.cdbc.*

func tryMySQL(): Option<Refine> {
    try {
        Some(Refine.open("mariadb://127.0.0.1:3306", [
            ("username", "root"),
            ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
            ("database", "refine_test")
        ]))
    } catch (_: Exception) {
        None
    }
}

struct ISchema <: TableSchema {
    var t: String
    var c: Array<ColumnDef>
    var i: Array<IndexDef>
    public init(name: String, cols: Array<ColumnDef>, idxs: Array<IndexDef>) {
        this.t = name; this.c = cols; this.i = idxs
    }
    public func tableName(): String { t }
    public func columns(): Array<ColumnDef> { c }
    public func indexes(): Array<IndexDef> { i }
}

@Test
public class MySQLIntegrationTest {

    @TestCase
    public func testColumnDefSQL(): Unit {
        let d = MySQLDialect()
        let sql1 = MySQLMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, true, false), d)
        @Expect(sql1, "`id` BIGINT AUTO_INCREMENT PRIMARY KEY")
        let sql2 = MySQLMigrator.columnDefSQL(ColumnDef("name", StorageType.Text, false, false, false), d)
        @Expect(sql2, "`name` TEXT NOT NULL")
        let sql3 = MySQLMigrator.columnDefSQL(ColumnDef("bio", StorageType.Text, false, false, true), d)
        @Expect(sql3, "`bio` TEXT")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let d = MySQLDialect()
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
        let schema = ISchema("test_tbl", cols, [])
        let sql = MySQLMigrator.createTableSQL(schema, d)
        @Expect(sql.contains("CREATE TABLE IF NOT EXISTS"), true)
        @Expect(sql.contains("test_tbl"), true)
        @Expect(sql.contains("AUTO_INCREMENT PRIMARY KEY"), true)
    }

    @TestCase
    public func testMigratorHasTable(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let m = rf.migrator()
                @Expect(m.hasTable("information_schema.TABLES"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorCreateDropTable(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = ISchema("__test_my_mig", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                @Expect(m.hasTable("__test_my_mig"), true)
                m.dropTable(schema)
                @Expect(m.hasTable("__test_my_mig"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddColumn(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = ISchema("__test_my_col", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                m.addColumn("__test_my_col", ColumnDef("extra", StorageType.Text, false, false, true))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddIndex(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_idx", cols, [IndexDef("idx_name", ["name"])])
                let m = rf.migrator()
                m.createTable(schema)
                m.addIndex("__test_my_idx", IndexDef("idx_name2", ["name"]))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAutoMigrate(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.Text, false, false, false)]
                let schema = ISchema("__test_my_auto", cols, [])
                let m = rf.migrator()
                m.autoMigrate([schema])
                @Expect(m.hasTable("__test_my_auto"), true)
                m.autoMigrate([schema])
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testAlterColumnReal(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let m = rf.migrator()
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_alt", cols, [])
                m.createTable(schema)
                m.alterColumn("__test_my_alt",
                    ColumnDef("val", StorageType.String, false, false, false),
                    ColumnDef("val", StorageType.Text, false, false, true))
                rf.transaction { tx: Tx =>
                    let r = tx.query("SELECT DATA_TYPE, IS_NULLABLE FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ? AND COLUMN_NAME = ?", ["__test_my_alt", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(1), "text")
                        @Expect(r.get<String>(2), "YES")
                    } else {
                        @Expect(true, false)
                    }
                }
                m.dropTable(schema)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testAutoMigrateAltersColumn(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let m = rf.migrator()
                let oldCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_alt2", oldCols, [])
                m.createTable(schema)
                let newCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.Text, false, false, true),
                               ColumnDef("extra", StorageType.Integer, false, false, true)]
                let newSchema = ISchema("__test_my_alt2", newCols, [])
                m.autoMigrate([newSchema])
                rf.transaction { tx: Tx =>
                    let r = tx.query("SELECT DATA_TYPE, IS_NULLABLE FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ? AND COLUMN_NAME = ?", ["__test_my_alt2", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(1), "text")
                        @Expect(r.get<String>(2), "YES")
                    } else {
                        @Expect(true, false)
                    }
                    let r2 = tx.query("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ? AND COLUMN_NAME = ?", ["__test_my_alt2", "extra"])
                    if (r2.next()) {
                        @Expect(r2.get<Int64>(1), 1)
                    } else {
                        @Expect(true, false)
                    }
                }
                m.dropTable(schema)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorDropColumn(): Unit {
        match (tryMySQL()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
                let schema = ISchema("__test_my_drop", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                m.dropColumn("__test_my_drop", "name")
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }
}

// ─── Query 集成测试 ────────────────────────────────────

@Refine
@Table["__q_users"]
class QUser {
    var id: Int64 = 0
    var name: String = ""
}

@Test
public class QueryIntegrationTest {
    static var qrf: Option<Refine> = None

    @BeforeAll
    static func setupClass(): Unit {
        qrf = tryMySQL()
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("CREATE TABLE IF NOT EXISTS __q_users (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL)", [])
                }
            case None => ()
        }
    }

    @AfterAll
    static func teardownClass(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS __q_users", [])
                }
            case None => ()
        }
    }

    @TestCase
    public func testAllWithFilter(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (id, name) VALUES (1, 'Alice')", [])
                    tx.execute("INSERT INTO __q_users (id, name) VALUES (2, 'Bob')", [])
                }
                let users = QUser.query().using(rf).filter(QUser.col().name == "Alice").all()
                @Expect(users.size, 1)
                @Expect(users[0].name, "Alice")
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testOneWithFilter(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (id, name) VALUES (10, 'Target')", [])
                }
                let user = QUser.query().using(rf).filter(QUser.col().name == "Target").one()
                @Expect(user.isSome(), true)
                @Expect(user.getOrThrow().name, "Target")
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testCount(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    for (i in 0..3) {
                        tx.execute("INSERT INTO __q_users (name) VALUES ('U" + i.toString() + "')", [])
                    }
                }
                let cnt = QUser.query().using(rf).count()
                @Expect(cnt >= 3, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testExists(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('ExistsTest')", [])
                }
                @Expect(QUser.query().using(rf).filter(QUser.col().name == "ExistsTest").exists(), true)
                @Expect(QUser.query().using(rf).filter(QUser.col().name == "NonExistent").exists(), false)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testOrderLimitOffset(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    for (i in 0..5) {
                        tx.execute("INSERT INTO __q_users (name) VALUES ('U" + i.toString() + "')", [])
                    }
                }
                let users = QUser.query().using(rf).order([QUser.col().id.desc()]).limit(3).offset(1).all()
                @Expect(users.size, 3)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testFilterAndOr(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('A')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('B')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('C')", [])
                }
                let users = QUser.query().using(rf)
                    .filter((QUser.col().name == "A").or(QUser.col().name == "C")).all()
                @Expect(users.size, 2)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testFilterLike(): Unit {
        match (qrf) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DELETE FROM __q_users", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('HelloWorld')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('HelloThere')", [])
                    tx.execute("INSERT INTO __q_users (name) VALUES ('Other')", [])
                }
                let users = QUser.query().using(rf)
                    .filter(QUser.col().name.like("%Hello%")).all()
                @Expect(users.size, 2)
            case None => @Expect(true, true)
        }
    }
}
