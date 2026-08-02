package refine

import std.unittest.*
import std.unittest.testmacro.*

class PgDiffColumnSchema <: TableSchema {
    public func tableName(): String { "t8_diff_pg" }
    public func columns(): Array<ColumnDef> {
        [
            ColumnDef("val", StorageType.Text, false, false, true),
            ColumnDef("extra", StorageType.Integer, false, false, true),
        ]
    }
    public func indexes(): Array<IndexDef> { [] }
}

class PgCamelSchema <: TableSchema {
    var t: String
    var c: Array<ColumnDef>
    public init(name: String, cols: Array<ColumnDef>) { this.t = name; this.c = cols }
    public func tableName(): String { t }
    public func columns(): Array<ColumnDef> { c }
    public func indexes(): Array<IndexDef> { [] }
}

@Test
public class PostgreSQLMigratorTest {
    // ─── C8: 反向映射无有损（防迁移翻烙饼）──────────────────

    // numeric 之前被有损映射为 Float，导致每轮迁移产生假 diff
    @TestCase
    public func testDataTypeToStorageNumeric(): Unit {
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("numeric"), StorageType.Decimal)
    }

    @TestCase
    public func testDataTypeToStorageDoublePrecision(): Unit {
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("double precision"), StorageType.Float)
    }

    @TestCase
    public func testDataTypeToStorageReal(): Unit {
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("real"), StorageType.Float)
    }

    @TestCase
    public func testDataTypeToStorageBoolean(): Unit {
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("boolean"), StorageType.`Bool`)
    }

    @TestCase
    public func testDataTypeToStorageInteger(): Unit {
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("bigint"), StorageType.Integer)
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("integer"), StorageType.Integer)
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("smallint"), StorageType.Integer)
    }

    @TestCase
    public func testDataTypeToStorageString(): Unit {
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("character varying"), StorageType.String)
        @Expect(PostgreSQLMigrator.pgDataTypeToStorage("character"), StorageType.String)
    }

    // ─── C8: autoMigrate 恢复纯只加语义 ───────────────────

    // 已存在列类型不同也不得执行 ALTER COLUMN ... TYPE，只允许 ADD COLUMN
    @TestCase
    public func testAutoMigrateDoesNotAlterExistingColumn(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        let valRow = Array<Any>(3, {i =>
            if (i == 0) { "val" } else if (i == 1) { "character varying" } else { "NO" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [valRow]))
        conn.stmt.queryResultQueue.add(MockQueryResult())

        let db = DB(ds)
        let migrator = PostgreSQLMigrator(db)
        migrator.autoMigrate([PgDiffColumnSchema()])

        // 列检测错位时会把已存在的 val 误判为缺失并发起 ADD COLUMN "val"
        var addedExtra = false
        for (i in 0..conn.stmt.capturedSqlHistory.size) {
            let sql = conn.stmt.capturedSqlHistory[i]
            if (sql.contains("ALTER COLUMN")) {
                @Expect(true, false)
            }
            if (sql.contains("ADD COLUMN \"val\"")) {
                @Expect(true, false)
            }
            if (sql.contains("ADD COLUMN \"extra\"")) { addedExtra = true }
        }
        @Expect(addedExtra, true)
    }

    // ─── I2: 迁移器不得强制小写标识符（与方言一致，保留驼峰）──────────────────

    @TestCase
    public func testColumnDefSQLPreservesCamelCase(): Unit {
        let d = PostgreSQLDialect()
        @Expect(PostgreSQLMigrator.columnDefSQL(ColumnDef("userProfile", StorageType.String, false, false, false), d), "\"userProfile\" VARCHAR(255) NOT NULL")
        @Expect(PostgreSQLMigrator.columnDefSQL(ColumnDef("authorId", StorageType.Integer, false, false, true), d), "\"authorId\" BIGINT")
    }

    @TestCase
    public func testCreateTableSQLPreservesCamelCase(): Unit {
        let d = PostgreSQLDialect()
        let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                    ColumnDef("displayName", StorageType.String, false, false, false)]
        let schema = PgCamelSchema("userProfile", cols)
        let sql = PostgreSQLMigrator.createTableSQL(schema, d)
        @Expect(sql.contains("\"userProfile\""), true)
        @Expect(sql.contains("\"displayName\""), true)
        @Expect(sql.contains("userprofile"), false)
    }

    @TestCase
    public func testHasTablePassesOriginalCase(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        let db = DB(ds)
        let migrator = PostgreSQLMigrator(db)
        let exists = migrator.hasTable("userProfile")
        @Expect(exists, true)
        // 表名作为参数绑定（? 占位符），必须原样传递驼峰大小写
        let bound = match (conn.stmt.capturedSetValues[0]) {
            case s: String => s == "userProfile"
            case _ => false
        }
        @Expect(bound, true)
    }

    // I6: query 抛异常时 session 必须 finally 关闭（否则池化连接泄漏）
    @TestCase
    public func testHasTableClosesSessionOnQueryThrow(): Unit {
        let ds = ClosingTrackDatasource()
        let migrator = PostgreSQLMigrator(DB(ds))
        try {
            migrator.hasTable("t")
            @Fail("expected mock query failure")
        } catch (_: Exception) {
            @Expect(ds.conn.closedCount, 1)
        }
    }

    // I6: execute 抛异常时 session 必须 finally 关闭
    @TestCase
    public func testAddColumnClosesSessionOnExecuteThrow(): Unit {
        let ds = ClosingTrackDatasource()
        let migrator = PostgreSQLMigrator(DB(ds))
        try {
            migrator.addColumn("t", ColumnDef("x", StorageType.Text, false, false, true))
            @Fail("expected mock update failure")
        } catch (_: Exception) {
            @Expect(ds.conn.closedCount, 1)
        }
    }
}
