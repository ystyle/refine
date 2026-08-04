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

    // R-M8: total 接近 Int64 max 时，原 (total + size - 1) 加法溢出为负。
    // 饱和公式 (total - 1) / size + 1 必须给出正确页数而非负数。
    @TestCase
    public func testTotalPagesNoOverflowNearInt64Max(): Unit {
        let maxTotal: Int64 = 9223372036854775807
        // size=1：直接等于 total（无 +1 溢出路径）
        let p1 = Page<Int64>([], maxTotal, 1, 1)
        @Expect(p1.totalPages(), maxTotal)
        // size=2：pages = maxTotal-1 除以 2 后 +1，仍为正
        let p2 = Page<Int64>([], maxTotal, 1, 2)
        @Expect(p2.totalPages(), 4611686018427387904)
        // 普通大数：不溢出时语义与原公式一致
        let p3 = Page<Int64>([], 9223372036854775806, 1, 3)
        @Expect(p3.totalPages(), 3074457345618258602)
    }

    @TestCase
    public func testTotalPagesCeilSemanticsPreserved(): Unit {
        // (total-1)/size + 1 与 ceil(total/size) 等价：覆盖整除与非整除边界
        let a = Page<Int64>([], 10, 1, 5)
        @Expect(a.totalPages(), 2)
        let b = Page<Int64>([], 11, 1, 5)
        @Expect(b.totalPages(), 3)
        let c = Page<Int64>([], 1, 1, 100)
        @Expect(c.totalPages(), 1)
    }
}
