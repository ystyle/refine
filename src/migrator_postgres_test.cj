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

        var added = false
        for (i in 0..conn.stmt.capturedSqlHistory.size) {
            let sql = conn.stmt.capturedSqlHistory[i]
            if (sql.contains("ALTER COLUMN")) {
                @Expect(true, false)
            }
            if (sql.contains("ADD COLUMN")) { added = true }
        }
        @Expect(added, true)
    }
}
