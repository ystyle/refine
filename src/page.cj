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

    public func totalPages(): Int64 {
        if (total == 0) { return 0 }
        (total + size - 1) / size
    }

    public func hasNext(): Bool {
        page < totalPages()
    }
}
