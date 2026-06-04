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
```

### using()

设置执行上下文。支持 `Refine` / `Session` / `Tx` / `DB`。

```cangjie
q.using(rf)
q.using(rf.session())
q.using(tx)  // 在事务中使用
q.using(db)
```

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
