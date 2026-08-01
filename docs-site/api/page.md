# Page\<T\>

分页结果，由 `Query<T>.page(page, size)` 返回。

## 字段

```cangjie
struct Page<T> {
    items: Array<T>  // 当前页数据
    total: Int64     // 满足条件的总记录数
    page: Int64      // 当前页码（从 1 开始）
    size: Int64      // 每页条数
}
```

## 方法

```cangjie
let pg: Page<User> = User.query().using(rf).page(2, 20)

pg.totalPages() // Int64：总页数（total 为 0 时为 0）
pg.hasNext()    // Bool：当前页之后是否还有数据
```

## 语义

- 页码从 1 开始，`page`/`size` 小于 1 时抛 `QueryException`
- 内部忽略链式设置的 `limit()` / `offset()`，以 `page`/`size` 为准
- 执行两次查询：一次 `COUNT(*)` 统计 total，一次 `LIMIT/OFFSET` 取当前页
