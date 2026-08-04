# Query\<T\>

查询构建器。通过链式 API 构造 SQL 查询，最终以 `all()` / `one()` / `count()` / `exists()` 执行。

## 创建 Query

```cangjie
// 手动创建
let q = Query<User>()

// 通过宏生成（推荐）
let q = User.query()
```

## 链式方法

所有方法返回 `this`，支持链式调用。

### select()

```cangjie
q.select([Expr.Column("id"), Expr.Column("name")])
```

> `select()` 接受 `Array<Expr>`。`Col<T>` 不是 `Expr`，所以需用 `Expr.Column("name")` 构造。宏生成的 `query()` 已自动设置 select，通常无需手动调用。

### from()

```cangjie
q.from("users")
```

默认由宏生成的 `query()` 自动设置。

### filter()

支持单个条件或条件数组。

```cangjie
// 单个
q.filter(User.col().age >= 18)

// 多个（AND 连接）
q.filter([
    User.col().age >= 18,
    User.col().status == "active"
])
```

### order()

```cangjie
q.order([User.col().id.desc()])
q.order([User.col().status.asc(), User.col().id.desc()])
```

### limit() / offset()

```cangjie
q.limit(10).offset(20)
```

### groupBy() / having()

`groupBy()` / `having()` 接受 `Array<Expr>`，需用 `Expr.Column()` 构造：

```cangjie
q.groupBy([Expr.Column("dept")])
q.having([Expr.Binary(Expr.Column("count"), BinOp.Gt, Expr.Value(5))])
```

### include()

```cangjie
// 预加载关联
q.include(UserRel.posts)
q.include(UserRel.profile)

// 指定关联返回字段
q.include(PostRel.author, [Col<Any>("name")])

// 嵌套 include：withInclude 链式声明两级预加载
q.include(PostRel.author.withInclude(UserRel.profile))

// 字符串点号路径，与 withInclude 链等价
q.includeAll(["author.profile", "tags"])
```

`include()` 采用分步批量查询（batch include）：主查询后按目标表执行 `WHERE 主键/fk IN (...)` 批量子查询回填，无 JOIN、无笛卡尔积。嵌套关联（`withInclude` / `includeAll`）递归批量装配。限制：目标实体须有单列 `id` 主键；复合主键主实体的集合 include 不支持；`includeAll` 路径不支持字段子集。

### using()

设置执行上下文。支持 `Refine` / `Session` / `Tx`。

```cangjie
q.using(rf)
q.using(rf.session())
q.using(tx)  // 在事务中使用
```

> **注意**：`q.using(DB)` 已在 0.6.0 移除——`DB` 是纯连接层，不含方言与参数偏移。需 ORM 查询请使用 `Refine`。

## 终止方法

### all()

```cangjie
let users: Array<User> = User.query().using(rf).all()
```

需已设置 mapper。宏生成的 `query()` 已自动设置。

### one()

```cangjie
let user: Option<User> = User.query().using(rf)
    .filter(User.col().id == 1)
    .one()
```

### count()

忽略 LIMIT/OFFSET，使用 `COUNT(*)`：

```cangjie
let count: Int64 = User.query().using(rf)
    .filter(User.col().age >= 18)
    .count()
```

### exists()

等价于 `count() > 0`：

```cangjie
let exists: Bool = User.query().using(rf)
    .filter(User.col().email == "test@example.com")
    .exists()
```

### sum() / avg() / min() / max()

聚合查询，忽略 LIMIT/OFFSET，保留 filter/groupBy/having 条件：

```cangjie
let total: Int64   = User.query().using(rf).sum(User.col().age)
let totalF: Float64 = User.query().using(rf).sum(User.col().score) // Col<Float64>
let avg: Float64   = User.query().using(rf).avg(User.col().age)
let min: Int64     = User.query().using(rf).min(User.col().age)
let max: Int64     = User.query().using(rf).max(User.col().age)
```

- `sum` 对 `Col<Int64>` 返回 `Int64`、对 `Col<Float64>` 返回 `Float64`；`avg` 恒返回 `Float64`
- 空结果集时 `sum` 为 0，`min`/`max` 为 0（SQL NULL 归一化）

### page()

一步分页，自动执行 COUNT + LIMIT/OFFSET，返回 `Page<T>`：

```cangjie
let pg: Page<User> = User.query().using(rf)
    .order([User.col().id.desc()])
    .page(2, 20)   // 第 2 页，每页 20 条
```

`Page<T>` 字段与方法：`items`（当前页）、`total`（总数）、`page`（页码）、`size`（每页条数）、`totalPages()`、`hasNext()`。页码从 1 开始，`page`/`size` 小于 1 抛 `QueryException`。

### forUpdate()

生成 `SELECT ... FOR UPDATE` 悲观锁，必须在事务中与 `using(tx)` 搭配：

```cangjie
rf.transaction { tx: Tx =>
    let rows = User.query().using(tx)
        .filter(User.col().id == 1)
        .forUpdate()
        .all()
}
```

## 批量写操作

以下方法执行后立即返回受影响行数，不返回实体：

### updateWhere()

按查询条件批量更新，返回 `Int64` 受影响行数：

```cangjie
let updated: Int64 = Post.query().using(rf)
    .filter(Post.col().user_id == author.id)
    .updateWhere(["title"], ["UPDATED"])
```

- `setCols`（列名）与 `setVals`（值）等长且一一对应；两者长度不一致或列数为 0 抛 `QueryException`
- 条件复用链式 `filter()`；不触发实体钩子

### deleteWhere()

按查询条件批量删除，返回 `Int64` 受影响行数：

```cangjie
let deleted: Int64 = Post.query().using(rf)
    .filter(Post.col().user_id == author.id)
    .deleteWhere()
```

- 条件复用链式 `filter()`；不加条件即删除全表，需自行保证 `WHERE` 已设置
- 不触发实体钩子

## 高级用法

### 自定义 Mapper

手动构造 `Query<T>` 时需设置 mapper。`columnMap` 以列名为 key，索引为 value：

```cangjie
let q = Query<User>()
q.select([Expr.Column("id"), Expr.Column("name")])
q.from("users")
q.setMapper({ result: QueryResult, columnMap: HashMap<String, Int64> =>
    let u = User()
    u.id = result.get<Int64>(columnMap.get("id").getOrThrow())
    u.name = result.get<String>(columnMap.get("name").getOrThrow())
    u
})
let users = q.using(rf).all()
```
