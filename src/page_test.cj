package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PageTest {
    @TestCase
    public func testTotalPagesNormal(): Unit {
        let p = Page<Int64>([1, 2], 10, 1, 3)
        @Expect(p.totalPages(), 4)
        @Expect(p.hasNext(), true)
    }

    @TestCase
    public func testTotalPagesExactlyDivisible(): Unit {
        let p = Page<Int64>([1, 2, 3], 9, 1, 3)
        @Expect(p.totalPages(), 3)
    }

    @TestCase
    public func testTotalPagesZeroTotal(): Unit {
        let p = Page<Int64>([], 0, 1, 3)
        @Expect(p.totalPages(), 0)
    }

    // M7: size=0 时 (total+size-1)/size 除零。page() 校验 size>=1，此处只可能来自手工构造。
    @TestCase
    public func testTotalPagesZeroSizeThrows(): Unit {
        let p = Page<Int64>([], 10, 1, 0)
        try {
            let _ = p.totalPages()
            @Fail("expected RefineException for size=0")
        } catch (e: RefineException) {
            @Expect(e.message.contains("size"), true)
        }
    }

    @TestCase
    public func testHasNextAtLastPage(): Unit {
        let p = Page<Int64>([1, 2, 3], 9, 3, 3)
        @Expect(p.hasNext(), false)
    }
}
