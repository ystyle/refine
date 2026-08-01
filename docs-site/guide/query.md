# 查询构建

## Query\<T\> 链式 API

所有查询方法均返回 `this`，支持链式调用。

```cangjie
let q = User.query().using(rf)
    .filter(User.col().age >= 18)
    .filter(User.col().email != "")
    .order([User.col().id.desc()])
    .limit(10)
    .offset(20)
```

### using()

查询需要一个执行上下文。支持四种方式：

```cangjie
// 通过 Refine 实例（自动获取方言和参数偏移）
User.query().using(rf)

// 通过 Session
User.query().using(rf.session())

// 通过 Tx（在事务内使用）
rf.transaction { tx: Tx =>
    User.query().using(tx).all()
}

// 通过 DB
User.query().using(DB.open("mariadb://127.0.0.1:3306"))
```

## 查询条件

### Col\<T\> 操作符

```cangjie
User.col().id == 1            // 等于
User.col().id != 1            // 不等于
User.col().age >  18          // 大于
User.col().age <  65          // 小于
User.col().age >= 18          // 大于等于
User.col().age <= 65          // 小于等于
```

### Col\<T\> 方法

```cangjie
User.col().name.like("%lice%")         // String 类型专属
User.col().id.anyOf([1, 2, 3])            // IN 查询
User.col().id.notAnyOf([4, 5])            // NOT IN
User.col().id.asc()                     // ORDER BY ASC
User.col().id.desc()                    // ORDER BY DESC
```

### Expr 组合

```cangjie
// AND / OR / NOT
let activeOrVip = User.col().status == "active"
    .or(User.col().vip == true)

let notBanned = User.col().status != "banned"

let complex = activeOrVip.and(notBanned)

// 直接在 filter 中使用
User.query().using(rf)
    .filter(complex)
    .all()
```

### 多条件 AND

`filter()` 接收数组时，所有条件以 AND 连接（方言层的 WHERE 子句使用 `,` 分隔实现 AND）：

```cangjie
User.query().using(rf)
    .filter([
        User.col().age >= 18,
        User.col().status == "active"
    ])
    .all()
```

### 原始 Expr 构造

大部分场景使用 `User.col().field` 类型安全语法即可。某些高级场景需直接构造 `Expr`：

```cangjie
// 类型安全写法（推荐）
User.col().age > 18

// 等价于原始 Expr 构造
Expr.Binary(Expr.Column("age"), BinOp.Gt, Expr.Value(18))

// IS NULL
Expr.Unary(UnaryOp.IsNull, Expr.Column("deleted_at"))

// SQL 函数
Expr.FuncCall("UPPER", [Expr.Column("name")])

// 原始 SQL 片段（如日期范围过滤）
User.query().using(rf)
    .filter(Expr.Raw("created_at > NOW() - INTERVAL 7 DAY"))
    .all()
```

## 排序

```cangjie
// 单个排序字段
User.query().using(rf)
    .order([User.col().id.desc()])
    .all()

// 多字段排序
User.query().using(rf)
    .order([User.col().status.asc(), User.col().id.desc()])
    .all()
```

## 分页

`page(page, size)` 一步完成分页（自动 COUNT + LIMIT/OFFSET），返回 `Page<T>`：

```cangjie
let pg: Page<User> = User.query().using(rf)
    .order([User.col().id.desc()])
    .page(2, 20)

pg.items        // 当前页数据
pg.total        // 总记录数
pg.totalPages() // 总页数
pg.hasNext()    // 是否有下一页
```

手动控制时用 `limit()` + `offset()`：

```cangjie
User.query().using(rf)
    .limit(10)
    .offset(20)
    .all()
```

## 分组与聚合

`groupBy()` 和 `having()` 接受 `Array<Expr>`，需使用 `Expr.Column()` 构造列引用：

```cangjie
User.query().using(rf)
    .groupBy([Expr.Column("dept")])
    .having([Expr.Binary(Expr.Column("count"), BinOp.Gt, Expr.Value(5))])
    .all()
```

内置聚合终止方法（均忽略 LIMIT/OFFSET，保留 filter/groupBy/having 条件）：

```cangjie
let cnt = User.query().using(rf).count()                 // COUNT(*) → Int64
let sum = User.query().using(rf).sum(User.col().age)     // Int64 → Int64；Float64 → Float64
let avg = User.query().using(rf).avg(User.col().age)     // 恒 → Float64
let min = User.query().using(rf).min(User.col().age)     // → Int64
let max = User.query().using(rf).max(User.col().age)     // → Int64
```

## 悲观锁

`forUpdate()` 生成 `SELECT ... FOR UPDATE`，必须在事务中使用：

```cangjie
rf.transaction { tx: Tx =>
    User.query().using(tx)
        .filter(User.col().id == 1)
        .forUpdate()
        .all()
}
```

## 原生 SQL

ORM 不支持的场景（DDL、复杂 JOIN、批量操作等）可直接执行原生 SQL。

### 在事务中执行

```cangjie
rf.transaction { tx: Tx =>
    // INSERT/UPDATE/DELETE
    tx.execute("INSERT INTO logs (msg) VALUES (?)", ["hello"])

    // SELECT — 手动逐字段映射
    let r = tx.query("SELECT * FROM users WHERE id = ?", [1])
    while (r.next()) {
        let name = r.get<String>(1)
        let email = r.get<String>(2)
    }
}
```

### 在会话中执行（只读、无事务）

```cangjie
let s = rf.session()
let r = s.query("SELECT COUNT(*) FROM users", [])
if (r.next()) {
    let total = r.get<Int64>(0)
}
s.close()
```

> `r.get<T>(index)` 的列索引：SQLite/PostgreSQL 从 0 开始，MariaDB/MySQL 从 1 开始。

### 自动映射到实体

使用 `queryAll<T>()` / `queryOne<T>()` 可以直接将查询结果映射为实体对象，无需手动 `r.get()`：

```cangjie
rf.transaction { tx: Tx =>
    let users = tx.queryAll("SELECT * FROM users WHERE age > ?", [18], User.rowMapper())
    // users: Array<User>

    let user = tx.queryOne("SELECT * FROM users WHERE id = ?", [1], User.rowMapper())
    // user: Option<User>
}
```

### 常见场景

```cangjie
// 创建 junction 表（autoMigrate 暂未自动创建多对多中间表）
rf.transaction { tx: Tx =>
    tx.execute("""
        CREATE TABLE IF NOT EXISTS post_tags (
            post_id BIGINT NOT NULL,
            tag_id  BIGINT NOT NULL
        )
    """, [])
}

// 批量插入
rf.transaction { tx: Tx =>
    for (userId in userIds) {
        tx.execute("INSERT INTO user_roles (user_id, role) VALUES (?, ?)", [userId, "admin"])
    }
}
```
