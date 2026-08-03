package refine

import std.collection.ArrayList
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import sonyflake.*

func isValidUlid(id: String): Bool {
    if (id.size != 26) { return false }
    let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    for (i in 0..id.size) {
        var found = false
        for (c in alphabet) {
            if (id[i] == c) { found = true; break }
        }
        if (!found) { return false }
    }
    true
}

@Test
class IdGeneratorTest {

    @TestCase
    public func testUlidGeneratorFormat(): Unit {
        let g = UlidIdGenerator()
        for (_ in 0..10) {
            @Expect(isValidUlid(g.generate()), true)
        }
    }

    @TestCase
    public func testUlidGeneratorUnique(): Unit {
        let g = UlidIdGenerator()
        var seen = ArrayList<String>()
        for (_ in 0..100) {
            let id = g.generate()
            @Expect(seen.contains(id), false)
            seen.add(id)
        }
        @Expect(seen.size, 100)
    }

    @TestCase
    public func testUlidGeneratorNonEmpty(): Unit {
        let g = UlidIdGenerator()
        @Expect(g.generate() != "", true)
    }
}

// M3: Sonyflake machineId 可配置。默认随机（多进程共库时不同进程的 machineId
// 可能撞车导致 ID 冲突），显式构造传 machineId 可在部署时为每个进程配置唯一值。
@Test
class SonyflakeIdGeneratorTest {

    @TestCase
    public func testConfiguredMachineId(): Unit {
        let g = SonyflakeIdGenerator(42)
        for (_ in 0..5) {
            let id = UInt64.parse(g.generate())
            let parts = Decompose(id)
            @Expect(parts.get("machine-id").getOrThrow(), UInt64(42))
        }
    }

    @TestCase
    public func testConfiguredMachineIdNonEmpty(): Unit {
        let g = SonyflakeIdGenerator(7)
        for (_ in 0..10) {
            @Expect(g.generate() != "", true)
        }
    }

    @TestCase
    public func testDefaultRandomMachineId(): Unit {
        let g = SonyflakeIdGenerator()
        for (_ in 0..10) {
            @Expect(g.generate() != "", true)
        }
    }

    @TestCase
    public func testDifferentMachineIdsDiffer(): Unit {
        let g1 = SonyflakeIdGenerator(1)
        let g2 = SonyflakeIdGenerator(2)
        // 同一时刻生成的 ID 在 machine-id 位段必然不同（其余位段相同）
        let id1 = UInt64.parse(g1.generate())
        let id2 = UInt64.parse(g2.generate())
        let m1 = Decompose(id1).get("machine-id").getOrThrow()
        let m2 = Decompose(id2).get("machine-id").getOrThrow()
        @Expect(m1 != m2, true)
    }
}
