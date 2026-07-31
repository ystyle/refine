# CRUD 操作

所有写操作（save/update/delete）必须在事务中执行。

## Create

```cangjie
let user = User()
user.name = "Alice"
user.email = "alice@example.com"

rf.transaction { tx: Tx =>
    tx.save(user)
}
// save 后 user.id 自动填充为数据库自增 ID
```

### 批量插入

批量插入多条记录，生成单条 `INSERT ... VALUES (?, ?), (?, ?), ...` SQL：

```cangjie
rf.transaction { tx: Tx =>
    let u1 = User()
    u1.name = "Alice"
    u1.email = "alice@example.com"
    let u2 = User()
    u2.name = "Bob"
    u2.email = "bob@example.com"

    tx.batchSave([u1, u2])
    // INSERT INTO user (name, email) VALUES (?, ?), (?, ?)
    // 自增主键不回写，需要 id 时用 query() 查回
}
```

- 所有参数扁平化收集到单条 SQL，避免 N 次 INSERT
- **自增主键（Int64 id）不回写**：多值 INSERT 后 `lastInsertId` 只代表第一条，且 id 不保证连续，需取 id 时用 `Entity.query().filter(...)` 查回
- **String 主键（UUID/ULID）回写**：插入前预生成所有 ID，批量插入后实体已携带完整 id
- **Int64 非自增主键（`@Id[auto, false]`）回写**：插入前按需生成（id 为 0 时），可搭配 Sonyflake 雪花 ID 替代数据库自增
- 支持 `TxBeforeCreate` / `TxAfterCreate` 钩子（每个实体独立触发）
- 空数组直接返回，不执行 SQL

### Upsert

`tx.upsert(entity)` 按主键插入或更新（存在冲突时更新，无冲突时插入）：

```cangjie
rf.transaction { tx: Tx =>
    let user = User()
    user.id = 1
    user.name = "Alice"
    user.email = "alice@example.com"
    tx.upsert(user)
    // MySQL:        INSERT ... ON DUPLICATE KEY UPDATE name = VALUES(name), ...
    // PostgreSQL:   INSERT ... ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, ...
}
```

- 冲突判定列为主键；String 主键（UUID/ULID）为空时自动生成
- SQLite 不支持 upsert，调用时抛出异常
- 再次 upsert 相同主键不会产生重复行，更新非主键字段

### 钩子校验

注册 `BeforeCreate` 钩子在插入前校验：

```cangjie
rf.hook<User>("User", HookKind.TxBeforeCreate) { scope: Scope<User> =>
    if (scope.entity.name == "") {
        scope.abort(Exception("name required"))
    }
}
```

## Read

最常用的查询方式是通过 `Entity.query().using(rf)` 链式构建：

```cangjie
// 查全部
let all = User.query().using(rf).all()

// 按条件
let adults = User.query().using(rf)
    .filter(User.col().age >= 18)
    .all()

// 查单条
let admin: Option<User> = User.query().using(rf)
    .filter(User.col().email == "admin@example.com")
    .one()

// 排序
let sorted = User.query().using(rf)
    .order([User.col().id.desc()])
    .all()

// 宏生成的 query() 已自动设置 select 字段
// 如需覆盖，使用 Expr.Column() 传入字段名
```

### findOne / findAll

实体提供静态快捷方法，无需 `query().using(rf)` 链式：

```cangjie
// findAll：无条件查全部
let all = User.findAll(User.query().using(rf))

// findOne：按条件查单条
let admin = User.findOne(
    User.query().using(rf)
        .filter(User.col().email == "admin@example.com")
)
```

### 原始 SQL 查询

通过 `rowMapper()` 结合 `Tx.queryAll<T>()` / `Tx.queryOne<T>()` 执行原始 SQL：

```cangjie
rf.transaction { tx: Tx =>
    // 查多条
    let users = tx.queryAll(
        "SELECT * FROM user WHERE age > ?", [18],
        User.rowMapper()
    )

    // 查单条
    let user: Option<User> = tx.queryOne(
        "SELECT * FROM user WHERE id = ?", [1],
        User.rowMapper()
    )
}
```

`Session` 上也提供同样的 `queryAll<T>()` / `queryOne<T>()` 方法。

### 分页

分页的典型模式：先 `count()` 获取总数，再用 `limit()` + `offset()` 取当前页：

```cangjie
let page: Int64 = 1
let pageSize: Int64 = 20

// 总记录数（用于计算总页数）
let total = User.query().using(rf).count()

// 当前页数据
let users = User.query().using(rf)
    .order([User.col().id.desc()])
    .limit(pageSize)
    .offset((page - 1) * pageSize)
    .all()
```

### 聚合

```cangjie
// 计数（忽略 LIMIT/OFFSET，使用 COUNT(*)）
let count = User.query().using(rf)
    .filter(User.col().age >= 18)
    .count()

// 存在性检查（count > 0）
let exists = User.query().using(rf)
    .filter(User.col().email == "test@example.com")
    .exists()
```

## Update

```cangjie
rf.transaction { tx: Tx =>
    let user = User.query().using(tx)
        .filter(User.col().id == 1)
        .one()
        .getOrThrow()
    user.name = "New Name"
    tx.update(user)
}
```

## Delete

```cangjie
rf.transaction { tx: Tx =>
    let user = User.query().using(tx)
        .filter(User.col().id == 1)
        .one()
        .getOrThrow()
    tx.delete(user)
}
```

