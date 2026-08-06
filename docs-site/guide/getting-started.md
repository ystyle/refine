# 快速开始

## 添加依赖

从中心仓安装（推荐）：

```toml
[dependencies]
refine = "0.7.0"
```

或使用 git 依赖（开发版）：

```toml
[dependencies]
refine = { git = "https://atomgit.com/ystyle/refine.git", branch = "master" }
```

## 定义实体

实体使用 `@Refine` 宏标记，宏在编译期生成 SQL、Mapper、Schema 等代码。

```cangjie
import refine.*
import refine.macros.*

@Refine
class User {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""
}
```

`@Refine` 宏会为 `User` 自动生成：
- `User.query()` — 返回预配置的 `Query<User>`
- `User.col()` — 返回 `UserCols` 结构体，内含每个字段的 `Col<T>`
- `Tx.save(User)` / `Tx.update(User)` / `Tx.delete(User)` — CRUD 扩展方法
- `UserRowMapper` — 行映射器函数
- `UserSchema` — `TableSchema` 实现，用于迁移

## 数据库连接

```cangjie
// SQLite 方言渲染已支持，但暂无可用驱动；以下以 MySQL 为例
let rf = Refine.open("mariadb://127.0.0.1:3306", [
    ("username", "root"),
    ("password", "secret"),
    ("database", "myapp")
])
```

也支持 PostgreSQL（需在 `cjpm.toml` 引入驱动 `pgsql`，见 [配置](../guide/configuration.md#postgresql)）：

```cangjie
let rf = Refine.open("postgres://127.0.0.1:5432", [
    ("username", "postgres"),
    ("password", "secret"),
    ("database", "myapp"),
    ("sslmode", "disable")
])
```

## 创建表

```cangjie
rf.migrator().autoMigrate([UserSchema()])
```

## 增删改查

```cangjie
// 创建
let user = User()
user.name = "Alice"
user.email = "alice@example.com"
rf.transaction { tx: Tx =>
    tx.save(user)
}
// user.id 已被自动填充

// 查询
let users = User.query().using(rf)
    .filter(User.col().name == "Alice")
    .all()

// 条件组合
let results = User.query().using(rf)
    .filter(
        User.col().name.like("%lice%")
            .and(User.col().email != "")
    )
    .all()

// 单条
let found: Option<User> = User.query().using(rf)
    .filter(User.col().id == 1)
    .one()

// 或用静态快捷方法
let admin = User.findOne(
    User.query().using(rf)
        .filter(User.col().email == "admin@example.com")
)
let all = User.findAll(User.query().using(rf))

// 更新
let f = found.getOrThrow()
f.email = "bob@new.com"
rf.transaction { tx: Tx =>
    tx.update(f)
}

// 删除
rf.transaction { tx: Tx =>
    tx.delete(f)
}

// 计数 / 存在性
let count = User.query().using(rf).count()
let exists = User.query().using(rf).filter(User.col().id == 1).exists()
```

## 分页与排序

```cangjie
User.query().using(rf)
    .order([User.col().id.desc()])
    .limit(10)
    .offset(20)
    .all()
```

## 关联预加载（核心特色）

Refine 的关联体系按 **拥有**（`has_one` / `has_many`）和 **引用**（`ref_one` / `ref_many`）二分，编译期类型安全，无需运行时反射。

```cangjie
@Refine
class Order {
    var id: Int64 = 0
    var total: Float64 = 0.0
    var status: String = ""
    var user_id: Int64 = 0

    // ref_one: 引用创建人，删单人不删
    @Ref[User, user_id]
    var creator: Option<User> = None

    // has_many: 拥有明细，删单明细跟着删
    @Rel[has_many, OrderItem, order_id]
    var items: ArrayList<OrderItem> = ArrayList<OrderItem>()

    // has_one: 拥有一条发票，删单发票跟着删
    @Rel[has_one, Invoice, order_id]
    var invoice: Option<Invoice> = None

    // ref_many: 引用标签，删单标签还在
    @Ref[Tag, via: order_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

// 预加载：一次主查询带出所有关联（批量子查询回填，无 JOIN 笛卡尔积）
let orders = Order.query().using(rf)
    .include(OrderRel.creator)
    .include(OrderRel.items)
    .include(OrderRel.invoice)
    .include(OrderRel.tags)
    .all()
```
