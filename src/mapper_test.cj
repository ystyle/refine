package refine

import std.collection.HashMap
import std.database.sql.{QueryResult, ColumnInfo, SqlDbType}
import std.unittest.*
import std.unittest.testmacro.*

class MapperMockColumnInfo <: ColumnInfo {
    public prop displaySize: Int64 { get() { _displaySize } }
    public prop length: Int64 { get() { _length } }
    public prop name: String { get() { _name } }
    public prop nullable: Bool { get() { _nullable } }
    public prop scale: Int64 { get() { _scale } }
    public prop typeName: String { get() { _typeName } }

    private var _displaySize: Int64 = 0
    private var _length: Int64 = 0
    private var _name: String = ""
    private var _nullable: Bool = false
    private var _scale: Int64 = 0
    private var _typeName: String = ""

    public init(name: String, nullable: Bool) {
        this._name = name
        this._nullable = nullable
    }
}

class MapperMockQueryResult <: QueryResult {
    public prop columnInfos: Array<ColumnInfo> { get() { _columnInfos } }

    private var _columnInfos: Array<ColumnInfo> = []
    private var rows: Array<Array<Any>> = []
    private var currentRow: Int64 = -1

    public init(columnInfos: Array<ColumnInfo>, rows: Array<Array<Any>>) {
        this._columnInfos = columnInfos
        this.rows = rows
    }

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func next(): Bool {
        let nextRow = currentRow + 1
        if (nextRow < rows.size) {
            currentRow = nextRow
            return true
        }
        return false
    }
    public func next(_values: Array<SqlDbType>): Bool { false }
    public func get<T>(index: Int): T {
        match (rows[currentRow][index]) {
            case v: T => v
            case _ => throw Exception("type mismatch")
        }
    }
    // 模拟真实驱动语义：列值为 T 类型返回 Some(v)；NULL/类型不匹配返回 None。
    // 修复前恒返回 None，导致基于 getOrNull 的 isNullId 判空无法区分有值与 NULL。
    public func getOrNull<T>(index: Int): ?T {
        match (rows[currentRow][index]) {
            case v: T => Some(v)
            case _ => None
        }
    }
}

@Test
public class MapperTest {
    @TestCase
    public func testBuildColumnMapBasic(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("name", false)
        let col3: ColumnInfo = MapperMockColumnInfo("email", false)
        let cols = [col1, col2, col3]
        let map = buildColumnMap(cols)
        @Expect(map.get("id").getOrThrow(), 0)
        @Expect(map.get("name").getOrThrow(), 1)
        @Expect(map.get("email").getOrThrow(), 2)
    }

    @TestCase
    public func testBuildColumnMapWithNullable(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("bio", true)
        let cols = [col1, col2]
        let map = buildColumnMap(cols)
        @Expect(map.get("id").getOrThrow(), 0)
        @Expect(map.get("bio").getOrThrow(), 1)
    }

    @TestCase
    public func testBuildColumnMapEmpty(): Unit {
        let cols: Array<ColumnInfo> = []
        let map = buildColumnMap(cols)
        @Expect(map.size, 0)
    }

    @TestCase
    public func testReadFieldInt64(): Unit {
        let col: ColumnInfo = MapperMockColumnInfo("id", false)
        let row = Array<Any>(1, {i => 42})
        let result = MapperMockQueryResult([col], [row])
        result.next()
        let value: Int64 = readField<Int64>(result, 0)
        @Expect(value, 42)
    }

    @TestCase
    public func testReadFieldString(): Unit {
        let col: ColumnInfo = MapperMockColumnInfo("name", false)
        let row = Array<Any>(1, {i => "hello"})
        let result = MapperMockQueryResult([col], [row])
        result.next()
        let value: String = readField<String>(result, 0)
        @Expect(value, "hello")
    }
}
