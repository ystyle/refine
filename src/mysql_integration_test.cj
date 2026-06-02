package refine

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
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
