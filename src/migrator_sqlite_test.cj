package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SQLiteMigratorTest {
    @TestCase
    public func testColumnDefSQL(): Unit {
        @Expect(SQLiteMigrator.columnDefSQL(ColumnDef("name", StorageType.Text, false, false, false)), "\"name\" TEXT NOT NULL")
        @Expect(SQLiteMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, false, false)), "\"id\" INTEGER PRIMARY KEY NOT NULL")
        @Expect(SQLiteMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, true, false)), "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL")
        @Expect(SQLiteMigrator.columnDefSQL(ColumnDef("email", StorageType.Text, false, false, true)), "\"email\" TEXT NULL")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let sql = SQLiteMigrator.createTableSQL(UserMigratorTestSchema())
        let expected = "CREATE TABLE IF NOT EXISTS \"user\" (" +
            "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
            "\"name\" TEXT NOT NULL, " +
            "\"email\" TEXT NULL, " +
            "\"age\" INTEGER NULL, " +
            "\"score\" REAL NULL)"
        @Expect(sql, expected)
    }

    @TestCase
    public func testAddColumnSQL(): Unit {
        let sql = SQLiteMigrator.addColumnSQL("user", ColumnDef("nickname", StorageType.Text, false, false, true))
        @Expect(sql, "ALTER TABLE \"user\" ADD COLUMN \"nickname\" TEXT NULL")
    }

    @TestCase
    public func testAddIndexSQL(): Unit {
        let sql = SQLiteMigrator.addIndexSQL("user", IndexDef("idx_user_email", ["email"]))
        @Expect(sql, "CREATE INDEX IF NOT EXISTS \"idx_user_email\" ON \"user\" (\"email\")")
    }

    @TestCase
    public func testDropColumnSQL(): Unit {
        let sql = SQLiteMigrator.dropColumnSQL("user", "age")
        @Expect(sql, "ALTER TABLE \"user\" DROP COLUMN \"age\"")
    }
}
