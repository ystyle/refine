package refine

import std.database.sql.{Connection, Datasource}
import std.unittest.*
import std.unittest.testmacro.*

class CaptureDatasource <: Datasource {
    public var conn: CaptureConnection = CaptureConnection()
    public func connect(): Connection { conn }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

// 已存在列 val 与 schema 声明类型不同（varchar vs text）、可空性不同（NO vs YES），
// autoMigrate 只加语义下必须原样保留，仅补充缺失列 extra
class DiffColumnSchema <: TableSchema {
    public func tableName(): String { "t8_diff" }
    public func columns(): Array<ColumnDef> {
        [
            ColumnDef("val", StorageType.Text, false, false, true),
            ColumnDef("extra", StorageType.Integer, false, false, true),
        ]
    }
    public func indexes(): Array<IndexDef> { [] }
}

// 已存在索引 idx_foo（STATISTICS 第 0 列），autoMigrate 只加语义下不得重复 CREATE INDEX
class IndexedDiffSchema <: TableSchema {
    public func tableName(): String { "t9_idx" }
    public func columns(): Array<ColumnDef> {
        [ ColumnDef("id", StorageType.Integer, true, true, false) ]
    }
    public func indexes(): Array<IndexDef> {
        [ IndexDef("idx_foo", ["id"]) ]
    }
}

// M15: 复合索引（STATISTICS 每列一行，同名多行）+ PRIMARY 混入的场景
class CompositeIdxSchema <: TableSchema {
    public func tableName(): String { "t10_composite" }
    public func columns(): Array<ColumnDef> {
        [ ColumnDef("id", StorageType.Integer, true, true, false) ]
    }
    public func indexes(): Array<IndexDef> {
        [ IndexDef("idx_multi", ["a", "b"]) ]
    }
}

@Test
public class MySQLMigratorTest {
    @TestCase
    public func testColumnDefSQL(): Unit {
        let d = MySQLDialect()
        @Expect(MySQLMigrator.columnDefSQL(ColumnDef("name", StorageType.Text, false, false, false), d), "`name` TEXT NOT NULL")
        @Expect(MySQLMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, true, false), d), "`id` BIGINT AUTO_INCREMENT PRIMARY KEY")
        @Expect(MySQLMigrator.columnDefSQL(ColumnDef("email", StorageType.Text, false, false, true), d), "`email` TEXT")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let d = MySQLDialect()
        let sql = MySQLMigrator.createTableSQL(UserMigratorTestSchema(), d)
        let expected = "CREATE TABLE IF NOT EXISTS `user` (" +
            "`id` BIGINT AUTO_INCREMENT PRIMARY KEY, " +
            "`name` TEXT NOT NULL, " +
            "`email` TEXT, " +
            "`age` BIGINT, " +
            "`score` DOUBLE)"
        @Expect(sql, expected)
    }

    // M24: 复合主键（junction 表）渲染表级 PRIMARY KEY，列级不再重复 PRIMARY KEY
    @TestCase
    public func testCreateTableSQLCompositePk(): Unit {
        let d = MySQLDialect()
        let sql = MySQLMigrator.createTableSQL(PostWithRel_TagsJunctionSchema(), d)
        @Expect(sql, "CREATE TABLE IF NOT EXISTS `post_tags` (" +
            "`postWithRel_id` BIGINT NOT NULL, " +
            "`tag_id` BIGINT NOT NULL, " +
            "PRIMARY KEY (`postWithRel_id`, `tag_id`))")
    }

    @TestCase
    public func testConstructAndCreate(): Unit {
        let db = DB(MockDatasource())
        let migrator = MySQLMigrator(db)
        migrator.createTable(UserMigratorTestSchema())
        @Expect(true, true)
    }

    // ─── C8: 反向映射无有损（防迁移翻烙饼）──────────────────

    // decimal 之前被有损映射为 Float，导致每轮迁移产生假 diff
    @TestCase
    public func testDataTypeToStorageDecimal(): Unit {
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("decimal", "decimal(65,30)"), StorageType.Decimal)
    }

    // MySQL Bool 列存储形态是 tinyint(1)，必须读回 Bool，否则读回 Integer 每轮翻转
    @TestCase
    public func testDataTypeToStorageTinyintOneIsBool(): Unit {
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("tinyint", "tinyint(1)"), StorageType.`Bool`)
    }

    @TestCase
    public func testDataTypeToStorageTinyintOtherIsInteger(): Unit {
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("tinyint", "tinyint"), StorageType.Integer)
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("tinyint", "tinyint(4)"), StorageType.Integer)
    }

    @TestCase
    public func testDataTypeToStorageInteger(): Unit {
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("bigint", "bigint"), StorageType.Integer)
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("int", "int"), StorageType.Integer)
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("smallint", "smallint"), StorageType.Integer)
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("mediumint", "mediumint"), StorageType.Integer)
    }

    @TestCase
    public func testDataTypeToStorageFloat(): Unit {
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("double", "double"), StorageType.Float)
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("float", "float"), StorageType.Float)
    }

    @TestCase
    public func testDataTypeToStorageString(): Unit {
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("varchar", "varchar(255)"), StorageType.String)
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("char", "char(10)"), StorageType.String)
    }

    // ─── C8: autoMigrate 恢复纯只加语义 ───────────────────

    // 已存在列类型不同也不得执行 MODIFY COLUMN，只允许 ADD COLUMN
    @TestCase
    public func testAutoMigrateDoesNotAlterExistingColumn(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        let valRow = Array<Any>(5, {i =>
            if (i == 0) { "val" } else if (i == 1) { "varchar" } else if (i == 2) { "NO" } else if (i == 3) { "" } else { "varchar(255)" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [valRow]))
        conn.stmt.queryResultQueue.add(MockQueryResult())

        let db = DB(ds)
        let migrator = MySQLMigrator(db)
        migrator.autoMigrate([DiffColumnSchema()])

        // 列检测错位时会把已存在的 val 误判为缺失并发起 ADD COLUMN `val`
        var addedExtra = false
        for (i in 0..conn.stmt.capturedSqlHistory.size) {
            let sql = conn.stmt.capturedSqlHistory[i]
            if (sql.contains("MODIFY COLUMN")) {
                @Expect(true, false)
            }
            if (sql.contains("ADD COLUMN `val`")) {
                @Expect(true, false)
            }
            if (sql.contains("ADD COLUMN `extra`")) { addedExtra = true }
        }
        @Expect(addedExtra, true)
    }

    // ─── C6: 结果列索引必须 paramOffset 感知，真实 MySQL（0-based）不偏移 ──

    // 默认 paramOffset=0 时 hasTable 读第 0 列（COUNT(*)），旧代码硬编码 1 会读到下一列
    @TestCase
    public func testHasTableReadsColumnZeroWithDefaultOffset(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        let row = Array<Any>(2, {i => if (i == 0) { 1 } else { 0 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [row]))
        let db = DB(ds)
        let migrator = MySQLMigrator(db)
        @Expect(migrator.hasTable("t8_has"), true)
    }

    // mariadb 走 paramOffset=1，hasTable 必须读第 1 列。
    // 第 0 列放 0（错读则 0>0=false 失败），第 1 列放 1（正读则 1>0=true 通过）
    @TestCase
    public func testHasTableReadsColumnOneWithMariadbOffset(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        let row = Array<Any>(2, {i => if (i == 0) { 0 } else { 1 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [row]))
        let db = DB(ds, 1)
        let migrator = MySQLMigrator(db)
        @Expect(migrator.hasTable("t8_has"), true)
    }

    // getExistingIndexNames 必须读 STATISTICS 第 0 列（paramOffset=0 时）；
    // 旧代码读第 1 列会拿到错误名字，导致已声明的 idx_foo 被误判缺失而重复 CREATE INDEX
    @TestCase
    public func testAutoMigrateSkipsExistingDeclaredIndex(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], []))
        let idxRow = Array<Any>(2, {i => if (i == 0) { "idx_foo" } else { "idx_wrong" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [idxRow]))

        let db = DB(ds)
        let migrator = MySQLMigrator(db)
        migrator.autoMigrate([IndexedDiffSchema()])

        var foundStats = false
        for (sql in conn.stmt.capturedSqlHistory) {
            if (sql.contains("information_schema.STATISTICS")) { foundStats = true }
        }
        @Expect(foundStats, true)
        for (i in 0..conn.stmt.capturedSqlHistory.size) {
            if (conn.stmt.capturedSqlHistory[i].contains("CREATE INDEX")) {
                @Expect(true, false)
            }
        }
    }

    // M15: 复合索引在 STATISTICS 中每列占一行（同名重复）且 PRIMARY 混入，autoMigrate
    // 必须去重 + 排除 PRIMARY，不得把已声明的 idx_multi 误判缺失而重复 CREATE INDEX
    @TestCase
    public func testAutoMigrateDedupsCompositeIndexAndSkipsPrimary(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], []))
        let r1 = Array<Any>(1, {i => "idx_multi"})
        let r2 = Array<Any>(1, {i => "idx_multi"})
        let r3 = Array<Any>(1, {i => "PRIMARY"})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [r1, r2, r3]))

        let db = DB(ds)
        let migrator = MySQLMigrator(db)
        migrator.autoMigrate([CompositeIdxSchema()])

        for (i in 0..conn.stmt.capturedSqlHistory.size) {
            if (conn.stmt.capturedSqlHistory[i].contains("CREATE INDEX")) {
                @Expect(true, false)
            }
        }
    }

    // M15: getExistingIndexNames 的查询本身必须 DISTINCT 去重 + 排除 PRIMARY
    @TestCase
    public func testGetExistingIndexNamesSQLUsesDistinctAndExcludesPrimary(): Unit {
        let ds = CaptureDatasource()
        let conn = ds.conn
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], []))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], []))
        let db = DB(ds)
        let migrator = MySQLMigrator(db)
        migrator.autoMigrate([CompositeIdxSchema()])
        var foundStats = false
        for (sql in conn.stmt.capturedSqlHistory) {
            if (sql.contains("information_schema.STATISTICS")) {
                foundStats = true
                @Expect(sql.contains("SELECT DISTINCT INDEX_NAME"), true)
                @Expect(sql.contains("INDEX_NAME != 'PRIMARY'"), true)
            }
        }
        @Expect(foundStats, true)
    }

    // C6: tinyint(1) unsigned 也是 Bool 列，不能只精确匹配 "tinyint(1)"
    @TestCase
    public func testDataTypeToStorageTinyintOneUnsignedIsBool(): Unit {
        @Expect(MySQLMigrator.mysqlDataTypeToStorage("tinyint", "tinyint(1) unsigned"), StorageType.`Bool`)
    }

    // I6: query 抛异常时 session 必须 finally 关闭（否则池化连接泄漏）
    @TestCase
    public func testHasTableClosesSessionOnQueryThrow(): Unit {
        let ds = ClosingTrackDatasource()
        let migrator = MySQLMigrator(DB(ds))
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
        let migrator = MySQLMigrator(DB(ds))
        try {
            migrator.addColumn("t", ColumnDef("x", StorageType.Text, false, false, true))
            @Fail("expected mock update failure")
        } catch (_: Exception) {
            @Expect(ds.conn.closedCount, 1)
        }
    }
}
