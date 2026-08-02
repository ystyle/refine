package refine

import std.unittest.*
import std.unittest.testmacro.*

// I5: 已有表（id）缺 name 列的旧表，autoMigrate 补 NOT NULL 列必须生成带 DEFAULT 的 ADD COLUMN
class I5AddNotNullSchema <: TableSchema {
    public func tableName(): String { "t5" }
    public func columns(): Array<ColumnDef> {
        [
            ColumnDef("id", StorageType.Integer, true, true, false),
            ColumnDef("name", StorageType.Text, false, false, false),
        ]
    }
    public func indexes(): Array<IndexDef> { [] }
}

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

    // I5: SQLite 非空表加 NOT NULL 列必须带类型合适的 DEFAULT（按存储类型），否则 ALTER 失败
    @TestCase
    public func testAddColumnSQLNotNullGetsDefault(): Unit {
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("age", StorageType.Integer, false, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"age\" INTEGER NOT NULL DEFAULT 0")
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("score", StorageType.Float, false, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"score\" REAL NOT NULL DEFAULT 0.0")
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("active", StorageType.`Bool`, false, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"active\" INTEGER NOT NULL DEFAULT 0")
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("nickname", StorageType.Text, false, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"nickname\" TEXT NOT NULL DEFAULT ''")
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("meta", StorageType.Json, false, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"meta\" TEXT NOT NULL DEFAULT '{}'")
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("blob", StorageType.Bytes, false, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"blob\" BLOB NOT NULL DEFAULT X''")
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("created_at", StorageType.Timestamp, false, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"created_at\" TEXT NOT NULL DEFAULT 0")
    }

    // I5: 可空列、主键列不加 DEFAULT（主键列不允许普通默认值，可空列用 NULL 即可）
    @TestCase
    public func testAddColumnSQLNullableAndPkUnchanged(): Unit {
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("nickname", StorageType.Text, false, false, true)),
            "ALTER TABLE \"user\" ADD COLUMN \"nickname\" TEXT NULL")
        @Expect(SQLiteMigrator.addColumnSQL("user", ColumnDef("pk", StorageType.Integer, true, false, false)),
            "ALTER TABLE \"user\" ADD COLUMN \"pk\" INTEGER PRIMARY KEY NOT NULL")
    }

    // I5: autoMigrate 补 NOT NULL 列走 addColumn，SQL 必须带 DEFAULT
    @TestCase
    public func testAutoMigrateAddsDefaultForNotNullColumn(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        conn.stmt.queryResultQueue.add(RowQueryResult(1))             // hasTable → true
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [])) // getExistingColumnNames → 空（模拟旧表缺 name）
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [])) // getExistingIndexNames → 空
        let db = DB(ds)
        let migrator = SQLiteMigrator(db)
        migrator.autoMigrate([I5AddNotNullSchema()])
        var found = false
        for (sql in conn.stmt.capturedSqlHistory) {
            if (sql.contains("ADD COLUMN \"name\" TEXT NOT NULL DEFAULT ''")) { found = true }
        }
        @Expect(found, true)
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
