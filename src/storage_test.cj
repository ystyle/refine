package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class StorageTest {
    @TestCase
    public func testStorageTypeInteger(): Unit {
        @Expect(StorageType.Integer, StorageType.Integer)
    }

    @TestCase
    public func testStorageTypeFloat(): Unit {
        @Expect(StorageType.Float, StorageType.Float)
    }

    @TestCase
    public func testStorageTypeDecimal(): Unit {
        @Expect(StorageType.Decimal, StorageType.Decimal)
    }

    @TestCase
    public func testStorageTypeBool(): Unit {
        @Expect(StorageType.`Bool`, StorageType.`Bool`)
    }

    @TestCase
    public func testStorageTypeString(): Unit {
        @Expect(StorageType.String, StorageType.String)
    }

    @TestCase
    public func testStorageTypeText(): Unit {
        @Expect(StorageType.Text, StorageType.Text)
    }

    @TestCase
    public func testStorageTypeJson(): Unit {
        @Expect(StorageType.Json, StorageType.Json)
    }

    @TestCase
    public func testStorageTypeBytes(): Unit {
        @Expect(StorageType.Bytes, StorageType.Bytes)
    }

    @TestCase
    public func testStorageTypeTimestamp(): Unit {
        @Expect(StorageType.Timestamp, StorageType.Timestamp)
    }

    @TestCase
    public func testStringAdapterStorageType(): Unit {
        let adapter = StringAdapter()
        @Expect(adapter.storageType(), StorageType.String)
    }

    @TestCase
    public func testStringAdapterToStored(): Unit {
        let adapter = StringAdapter()
        let stored = adapter.toStored("hello")
        match (stored) {
            case s: String => @Expect(s, "hello")
            case _ => @Fail("expected String")
        }
    }

    @TestCase
    public func testStringAdapterFromStored(): Unit {
        let adapter = StringAdapter()
        let result = adapter.fromStored("world")
        @Expect(result, "world")
    }

    @TestCase
    public func testStringAdapterRoundtrip(): Unit {
        let adapter = StringAdapter()
        let original = "roundtrip test"
        let stored = adapter.toStored(original)
        let result = adapter.fromStored(stored)
        @Expect(result, original)
    }
}

public class StringAdapter <: TypeAdapter<String> {
    public func storageType(): StorageType { StorageType.String }
    public func toStored(value: String): Any { value }
    public func fromStored(stored: Any): String {
        match (stored) {
            case s: String => s
            case _ => ""
        }
    }
}
