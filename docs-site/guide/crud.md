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

> **级联**：`tx.save` 会沿已标记修改的关联字段级联保存子对象（has_many / has_one）并回填 fk，`ref_many` 会重建中间表；`ref_to` 只维护 fk 不动被引对象。详见 [关联 - 级联保存](./relations.md#级联保存)。

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
- 含审计字段（`created_at` / `updated_at`）的实体插入时自动填充，详见 [实体定义 - 审计字段](./entities.md#审计字段-created-at-updated-at)
- 空数组直接返回，不执行 SQL
- **不级联**：`batchSave` 只插入给定实体，不沿关联字段递归（不会级联保存子对象、不会重建 `ref_many` 中间表），需要级联时请逐个 `tx.save()`，详见 [关联 - 级联保存](./relations.md#级联保存)

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

注册 `TxBeforeCreate` 钩子在插入前校验：

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

`page(page, size)` 一步完成分页：自动执行一次 `COUNT(*)` 统计总数 + 一次 `LIMIT/OFFSET` 查询，返回 `Page<T>`：

```cangjie
let pg: Page<User> = User.query().using(rf)
    .order([User.col().id.desc()])
    .page(2, 20)   // 第 2 页，每页 20 条

pg.items        // Array<User> 当前页数据
pg.total        // Int64 总记录数
pg.page         // Int64 当前页码
pg.size         // Int64 每页条数
pg.totalPages() // Int64 总页数（total 为 0 时为 0）
pg.hasNext()    // Bool 是否有下一页
```

- 页码从 1 开始，`page` 或 `size` 小于 1 时抛异常
- 内部忽略链式设置的 `limit()` / `offset()`，以 `page`/`size` 为准
- 若想只取数据、自己维护分页元信息，可改用 `count()` + `limit()` + `offset()` 组合

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

// 求和 / 均值 / 最小 / 最大（Int64 与 Float64 字段均有重载）
let totalAge = User.query().using(rf).sum(User.col().age)
let avgAge   = User.query().using(rf).avg(User.col().age)   // 返回 Float64
let minAge   = User.query().using(rf).min(User.col().age)
let maxAge   = User.query().using(rf).max(User.col().age)
```

- `sum`/`avg`/`min`/`max` 与 `count` 一样忽略 LIMIT/OFFSET，但保留 `filter`/`groupBy`/`having` 条件
- `sum` 对 `Col<Int64>` 返回 `Int64`、对 `Col<Float64>` 返回 `Float64`；`avg` 恒返回 `Float64`
- 满足条件的行数为 0 时，`sum` 返回 0，`min`/`max` 返回 NULL（转换为 0）

### 悲观锁（SELECT ... FOR UPDATE）

`forUpdate()` 为查询加悲观锁，须在事务内使用，锁定本次查询命中行直到事务提交/回滚：

```cangjie
rf.transaction { tx: Tx =>
    let found = Post.query().using(tx)
        .filter(Post.col().id == 1)
        .forUpdate()
        .all()
    // SELECT ... FROM post WHERE id = 1 FOR UPDATE
    // 其他事务对被锁行执行 UPDATE/DELETE/FOR UPDATE 会阻塞，直到本事务结束
}
```

- 必须与 `using(tx)` 配合在事务中使用；在非事务上下文中锁无意义
- 锁在事务提交或回滚时自动释放，不会在 `closeExecutor` 时提前释放（锁归事务管）
- SQLite 方言渲染时忽略锁子句（SQLite 不支持行级锁，全库写锁由引擎自行管理）

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

> **乐观锁**：若实体含 `@Version` 字段，`tx.update` 自动在 WHERE 追加版本校验并递增 version，版本过期（或行被删）时抛 [OptimisticLockException](../api/error.md#optimisticlockexception)，详见 [实体定义 - 乐观锁](./entities.md#乐观锁-version)。建议在同一个事务内完成读-改-写。

> **级联**：`tx.update` 会沿已标记修改的关联字段级联更新子对象（子有 id → update、无 id → save），`ref_many` 会按关联列表重建中间表；列表移除不自动删库。详见 [关联 - 级联保存](./relations.md#级联保存)。

### 批量更新

`tx.batchUpdate(entities)` 用**单条 SQL** 更新多行不同值：

```cangjie
rf.transaction { tx: Tx =>
    let u1 = User()
    u1.id = 1
    u1.name = "Alice2"
    let u2 = User()
    u2.id = 2
    u2.name = "Bob2"

    tx.batchUpdate([u1, u2])
    // UPDATE users SET name = CASE id WHEN ? THEN ? WHEN ? THEN ? END WHERE id IN (?, ?)
}
```

- 单条 SQL 跨方言（MySQL / PostgreSQL / SQLite），CASE WHEN 是标准语法
- 复合主键支持：`CASE WHEN pk1 = ? AND pk2 = ? THEN ? ... WHERE (pk1, pk2) IN ((?, ?), ...)`
- 空数组直接返回；全主键表（无更新列）抛出异常
- 触发 `TxBeforeUpdate` / `TxAfterUpdate` 钩子（每个实体独立触发）
- 含审计字段的实体自动刷新 `updated_at`，详见 [实体定义 - 审计字段](./entities.md#审计字段-created-at-updated-at)
- 含 `@Version` 字段的实体，version 以 CASE 参与更新（值取 version+1），匹配行数不足时抛 [OptimisticLockException](../api/error.md#optimisticlockexception)，详见 [实体定义 - 乐观锁](./entities.md#乐观锁-version)
- 参数量为 2 × 列数 × 行数 + 主键数，大批量时注意 SQL 长度（业界同款方案，参考 GORM）
- **不级联**：`batchUpdate` 只更新给定实体本身，不沿关联字段递归（子对象、`ref_many` 中间表均不处理），需要级联时请逐个 `tx.update()`，详见 [关联 - 级联保存](./relations.md#级联保存)

### 条件更新

`updateWhere(cols, vals)` 按查询条件批量更新，返回受影响行数：

```cangjie
let updated: Int64 = Post.query().using(rf)
    .filter(Post.col().user_id == author.id)
    .updateWhere(["title"], ["UPDATED"])
// UPDATE post SET title = ? WHERE user_id = ?
```

- 列名与值须等长，按序一一对应；条件复用链式 `filter()`，仅 `WHERE`（及 JOIN）生效
- 返回受影响行数（数据库层面匹配的行数，MySQL 默认按变更行数统计）
- 不触发实体级 `TxBeforeUpdate` / `TxAfterUpdate` 钩子（未经过实体映射层），如需钩子请逐个实体 `tx.update()`

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

> **级联删除**：`tx.delete` 沿 has 系关联从库查询子对象并级联删除（子对象遵循自身软删/硬删策略），`ref_many` 清空中间表，`ref_to` 不动被引对象。不依赖内存关联列表。详见 [关联 - 级联保存](./relations.md#级联保存)。
>
> **⚠ 原子性**：级联删除会执行多条 SQL（父 + 子 + 中间表），`tx.delete` 不隐式开启事务——请在 `rf.transaction` 内调用以保证整体原子性（中途失败整体回滚），见 [事务](../guide/transactions.md) 与 [关联 - 原子性](./relations.md#级联保存)。

### 条件删除

`deleteWhere()` 按查询条件批量删除，返回受影响行数：

```cangjie
let deleted: Int64 = Post.query().using(rf)
    .filter(Post.col().user_id == author.id)
    .deleteWhere()
// DELETE FROM post WHERE user_id = ?
```

- 条件复用链式 `filter()`；若不加条件则删除全表，请务必先确认 `WHERE` 已设置
- 不触发 `TxBeforeDelete` / `TxAfterDelete` 钩子（未经过实体映射层）

