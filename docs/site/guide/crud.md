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

### 钩子校验

注册 `BeforeCreate` 钩子在插入前校验：

```cangjie
rf.hook<User>("User", HookKind.BeforeCreate) { scope: Scope<User> =>
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

