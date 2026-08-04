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
    // R-M8: 原公式 `(total + size - 1) / size` 在 total 接近 Int64 max 时加法溢出
    // 为负（total + size - 1 回绕），总页数被算成负数/错误值。改为饱和形式
    // `(total - 1) / size + 1`：total>=1 时 total-1 不会下溢，除后再 +1 的中间值
    // 至多 Int64.max（size>=1），全程无溢出；语义与 ceil(total / size) 完全等价。
    public func totalPages(): Int64 {
        if (size <= 0) { throw RefineException("invalid page size: " + size.toString() + "; size must be >= 1") }
        if (total == 0) { return 0 }
        (total - 1) / size + 1
    }

    public func hasNext(): Bool {
        page < totalPages()
    }
}
