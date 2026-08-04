package refine

import std.unittest.*
import std.unittest.testmacro.*

class UserMigratorTestSchema <: TableSchema {
    public func tableName(): String { "user" }
    public func columns(): Array<ColumnDef> {
        [
            ColumnDef("id", StorageType.Integer, true, true, false),
            ColumnDef("name", StorageType.Text, false, false, false),
            ColumnDef("email", StorageType.Text, false, false, true),
            ColumnDef("age", StorageType.Integer, false, false, true),
            ColumnDef("score", StorageType.Float, false, false, true),
        ]
    }
    public func indexes(): Array<IndexDef> {
        [IndexDef("idx_user_email", ["email"])]
    }
}

class EmptySchema <: TableSchema {
    public func tableName(): String { "empty" }
    public func columns(): Array<ColumnDef> { [] }
    public func indexes(): Array<IndexDef> { [] }
}

class BoolSchema <: TableSchema {
    public func tableName(): String { "flags" }
    public func columns(): Array<ColumnDef> {
        [ColumnDef("active", StorageType.`Bool`, false, false, false)]
    }
    public func indexes(): Array<IndexDef> { [] }
}

class AllTypesSchema <: TableSchema {
    public func tableName(): String { "all_types" }
    public func columns(): Array<ColumnDef> {
        [
            ColumnDef("f_int", StorageType.Integer, false, false, true),
            ColumnDef("f_real", StorageType.Float, false, false, true),
            ColumnDef("f_dec", StorageType.Decimal, false, false, true),
            ColumnDef("f_bool", StorageType.`Bool`, false, false, true),
            ColumnDef("f_str", StorageType.String, false, false, true),
            ColumnDef("f_text", StorageType.Text, false, false, true),
            ColumnDef("f_json", StorageType.Json, false, false, true),
            ColumnDef("f_blob", StorageType.Bytes, false, false, true),
            ColumnDef("f_ts", StorageType.Timestamp, false, false, true),
        ]
    }
    public func indexes(): Array<IndexDef> { [] }
}

@Test
public class MigratorTest {
    @TestCase
    public func testColumnDefDefaultNullable(): Unit {
        let col = ColumnDef("name", StorageType.Text, false, false, true)
        @Expect(col.name, "name")
        @Expect(col.storageType, StorageType.Text)
        @Expect(col.primaryKey, false)
        @Expect(col.autoIncrement, false)
        @Expect(col.nullable, true)
    }

    @TestCase
    public func testColumnDefFull(): Unit {
        let col = ColumnDef("id", StorageType.Integer, true, true, false)
        @Expect(col.name, "id")
        @Expect(col.storageType, StorageType.Integer)
        @Expect(col.primaryKey, true)
        @Expect(col.autoIncrement, true)
        @Expect(col.nullable, false)
    }

    @TestCase
    public func testIndexDefSingleColumn(): Unit {
        let idx = IndexDef("idx_name", ["name"])
        @Expect(idx.name, "idx_name")
        @Expect(idx.columns[0], "name")
        @Expect(idx.columns.size, 1)
    }

    @TestCase
    public func testIndexDefMultiColumn(): Unit {
        let idx = IndexDef("idx_a_b", ["a", "b"])
        @Expect(idx.columns.size, 2)
        @Expect(idx.columns[0], "a")
        @Expect(idx.columns[1], "b")
    }

    @TestCase
    public func testDataTypeOfInteger(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.Integer), "INTEGER")
    }

    @TestCase
    public func testDataTypeOfFloat(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.Float), "REAL")
    }

    @TestCase
    public func testDataTypeOfDecimal(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.Decimal), "NUMERIC")
    }

    @TestCase
    public func testDataTypeOfBool(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.`Bool`), "INTEGER")
    }

    @TestCase
    public func testDataTypeOfString(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.String), "TEXT")
    }

    @TestCase
    public func testDataTypeOfText(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.Text), "TEXT")
    }

    @TestCase
    public func testDataTypeOfJson(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.Json), "TEXT")
    }

    @TestCase
    public func testDataTypeOfBytes(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.Bytes), "BLOB")
    }

    @TestCase
    public func testDataTypeOfTimestamp(): Unit {
        @Expect(SQLiteMigrator.dataTypeOf(StorageType.Timestamp), "TEXT")
    }

    @TestCase
    public func testColumnDefSQLNotNull(): Unit {
        let col = ColumnDef("name", StorageType.Text, false, false, false)
        let sql = SQLiteMigrator.columnDefSQL(col)
        @Expect(sql, "\"name\" TEXT NOT NULL")
    }

    @TestCase
    public func testColumnDefSQLNullable(): Unit {
        let col = ColumnDef("email", StorageType.Text, false, false, true)
        let sql = SQLiteMigrator.columnDefSQL(col)
        @Expect(sql, "\"email\" TEXT NULL")
    }

    @TestCase
    public func testColumnDefSQLPrimaryKeyAutoIncrement(): Unit {
        let col = ColumnDef("id", StorageType.Integer, true, true, false)
        let sql = SQLiteMigrator.columnDefSQL(col)
        @Expect(sql, "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL")
    }

    @TestCase
    public func testColumnDefSQLPrimaryKeyOnly(): Unit {
        let col = ColumnDef("pk_id", StorageType.Integer, true, false, false)
        let sql = SQLiteMigrator.columnDefSQL(col)
        @Expect(sql, "\"pk_id\" INTEGER PRIMARY KEY NOT NULL")
    }

    @TestCase
    public func testColumnDefSQLFloat(): Unit {
        let col = ColumnDef("price", StorageType.Float, false, false, true)
        let sql = SQLiteMigrator.columnDefSQL(col)
        @Expect(sql, "\"price\" REAL NULL")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let schema = UserMigratorTestSchema()
        let sql = SQLiteMigrator.createTableSQL(schema)
        let expected = "CREATE TABLE IF NOT EXISTS \"user\" (" +
            "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
            "\"name\" TEXT NOT NULL, " +
            "\"email\" TEXT NULL, " +
            "\"age\" INTEGER NULL, " +
            "\"score\" REAL NULL)"
        @Expect(sql, expected)
    }

    // R-M17: 空 schema 生成的零列 CREATE TABLE 是非法 DDL（SQLite/MySQL/PG 均如此），
    // createTableSQL 必须 fail-fast 抛带表名的明确错误，而非产出 `"empty" ()`。
    @TestCase
    public func testCreateTableSQLEmptyThrows(): Unit {
        let schema = EmptySchema()
        try {
            let _ = SQLiteMigrator.createTableSQL(schema)
            @Fail("expected MigrationException for empty schema")
        } catch (e: MigrationException) {
            @Expect(e.message.contains("empty"), true)
            @Expect(e.message.contains("TableSchema.columns"), true)
        }
    }

    @TestCase
    public func testCreateTableSQLBool(): Unit {
        let schema = BoolSchema()
        let sql = SQLiteMigrator.createTableSQL(schema)
        @Expect(sql, "CREATE TABLE IF NOT EXISTS \"flags\" (\"active\" INTEGER NOT NULL)")
    }

    @TestCase
    public func testCreateTableSQLAllTypes(): Unit {
        let schema = AllTypesSchema()
        let sql = SQLiteMigrator.createTableSQL(schema)
        let expected = "CREATE TABLE IF NOT EXISTS \"all_types\" (" +
            "\"f_int\" INTEGER NULL, " +
            "\"f_real\" REAL NULL, " +
            "\"f_dec\" NUMERIC NULL, " +
            "\"f_bool\" INTEGER NULL, " +
            "\"f_str\" TEXT NULL, " +
            "\"f_text\" TEXT NULL, " +
            "\"f_json\" TEXT NULL, " +
            "\"f_blob\" BLOB NULL, " +
            "\"f_ts\" TEXT NULL)"
        @Expect(sql, expected)
    }

    @TestCase
    public func testAddColumnSQL(): Unit {
        let col = ColumnDef("nickname", StorageType.Text, false, false, true)
        let sql = SQLiteMigrator.addColumnSQL("user", col)
        @Expect(sql, "ALTER TABLE \"user\" ADD COLUMN \"nickname\" TEXT NULL")
    }

    @TestCase
    public func testAddColumnSQLNotNull(): Unit {
        // I5: SQLite 对非空表加 NOT NULL 列必须带 DEFAULT，否则 ADD COLUMN 失败
        let col = ColumnDef("age", StorageType.Integer, false, false, false)
        let sql = SQLiteMigrator.addColumnSQL("user", col)
        @Expect(sql, "ALTER TABLE \"user\" ADD COLUMN \"age\" INTEGER NOT NULL DEFAULT 0")
    }

    @TestCase
    public func testAddIndexSQLSingle(): Unit {
        let idx = IndexDef("idx_user_email", ["email"])
        let sql = SQLiteMigrator.addIndexSQL("user", idx)
        @Expect(sql, "CREATE INDEX IF NOT EXISTS \"idx_user_email\" ON \"user\" (\"email\")")
    }

    @TestCase
    public func testAddIndexSQLMulti(): Unit {
        let idx = IndexDef("idx_title_id", ["title", "id"])
        let sql = SQLiteMigrator.addIndexSQL("posts", idx)
        @Expect(sql, "CREATE INDEX IF NOT EXISTS \"idx_title_id\" ON \"posts\" (\"title\", \"id\")")
    }

    @TestCase
    public func testHasTableSQL(): Unit {
        let sql = SQLiteMigrator.hasTableSQL()
        @Expect(sql, "SELECT name FROM sqlite_master WHERE type='table' AND name=?")
    }

    @TestCase
    public func testDropTableSQL(): Unit {
        let schema = UserMigratorTestSchema()
        let sql = SQLiteMigrator.dropTableSQL(schema)
        @Expect(sql, "DROP TABLE IF EXISTS \"user\"")
    }

    @TestCase
    public func testDropColumnSQL(): Unit {
        let sql = SQLiteMigrator.dropColumnSQL("user", "age")
        @Expect(sql, "ALTER TABLE \"user\" DROP COLUMN \"age\"")
    }

    @TestCase
    public func testMigratorConstruct(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        @Expect(true, true)
    }

    @TestCase
    public func testMigratorCreateTable(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        let schema = UserMigratorTestSchema()
        migrator.createTable(schema)
        @Expect(true, true)
    }

    @TestCase
    public func testMigratorDropTable(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        migrator.dropTable(UserMigratorTestSchema())
        @Expect(true, true)
    }

    @TestCase
    public func testMigratorHasTable(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        let result = migrator.hasTable("users")
        @Expect(result, false)
    }

    @TestCase
    public func testMigratorAddColumn(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        migrator.addColumn("user", ColumnDef("nickname", StorageType.Text, false, false, true))
        @Expect(true, true)
    }

    @TestCase
    public func testMigratorAddIndex(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        migrator.addIndex("user", IndexDef("idx_name", ["name"]))
        @Expect(true, true)
    }

    @TestCase
    public func testMigratorDropColumn(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        migrator.dropColumn("user", "age")
        @Expect(true, true)
    }

    @TestCase
    public func testMigratorAlterColumn(): Unit {
        let db = DB(MockDatasource())
        let migrator = SQLiteMigrator(db)
        let old = ColumnDef("name", StorageType.Text, false, false, false)
        let colNew = ColumnDef("name", StorageType.String, false, false, true)
        try {
            migrator.alterColumn("user", old, colNew)
            @Fail("should have thrown")
        } catch (e: Exception) {
            @Expect(e.message, "SQLite does not support ALTER COLUMN")
        }
    }
}
