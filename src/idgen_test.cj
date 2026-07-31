package refine

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

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
