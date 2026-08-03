package refine

public struct Page<T> {
    public var items: Array<T>
    public var total: Int64
    public var page: Int64
    public var size: Int64

    public init(items: Array<T>, total: Int64, page: Int64, size: Int64) {
        this.items = items
        this.total = total
        this.page = page
        this.size = size
    }

    // M7: size<=0 除零守卫。page() 校验 size>=1，size=0 只可能来自手工构造 Page；
    // 抛 RefineException 而非静默返回 0/1，让调用方立即发现非法状态。
    public func totalPages(): Int64 {
        if (size <= 0) { throw RefineException("invalid page size: " + size.toString() + "; size must be >= 1") }
        if (total == 0) { return 0 }
        (total + size - 1) / size
    }

    public func hasNext(): Bool {
        page < totalPages()
    }
}
