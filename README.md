# Refine ORM

仓颉语言编译期类型安全 ORM。零运行时反射，全部在编译期通过宏生成 SQL、Mapper、Schema。

## 特色

- **编译期类型安全** — 字段引用、查询条件、关联预加载均在编译期校验，没有运行时字符串拼写错误
- **四类关联体系** — `has_one` / `has_many`（拥有）和 `ref_one` / `ref_many`（引用），语义明确
- **关联预加载** — `include()` 一次查询带出所有关联，不产生 N+1 问题
- **多方言** — 内置 SQLite / MySQL / PostgreSQL 支持，各方言自动适配
- **数据迁移** — 从实体定义自动生成 `CREATE TABLE`，无需手写 DDL
- **生命周期钩子** — 实例级 Hook 系统，支持 `TxBeforeCreate` / `AfterFind` 等 7 种钩子

## 快速示例

```cangjie
import refine.*
import refine.macros.*
import std.collection.ArrayList

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

@Refine class User       { var id: Int64 = 0; var name: String = "" }
@Refine class OrderItem  { var id: Int64 = 0; var product: String = ""; var order_id: Int64 = 0 }
@Refine class Invoice    { var id: Int64 = 0; var invoice_no: String = ""; var order_id: Int64 = 0 }
@Refine class Tag        { var id: Int64 = 0; var name: String = "" }

let rf = Refine.open("mariadb://127.0.0.1:3306", [
    ("username", "root"),
    ("password", "secret"),
    ("database", "myapp")
])
rf.migrator().autoMigrate(Order.schemas())

// 创建订单
rf.transaction { tx: Tx =>
    let order = Order()
    order.total = 299.0
    order.status = "pending"
    order.user_id = 1
    tx.save(order)

    let item = OrderItem()
    item.product = "Widget"
    item.order_id = order.id
    tx.save(item)
}

// 预加载所有关联
let orders = Order.query().using(rf)
    .include(OrderRel.creator)
    .include(OrderRel.items)
    .include(OrderRel.invoice)
    .include(OrderRel.tags)
    .all()
```

## 关联体系

Refine 的核心特色：按 **拥有** 和 **引用** 二分，四种关联语义清晰。

| 注解 | 类型 | 语义 | 外键位置 | 删主表时 |
|---|---|---|---|---|
| `@Ref[Target, fk]` | ref_one | 引用一个 | 当前表 | 目标保留 |
| `@Rel[has_one, Target, fk]` | has_one | 拥有一个 | 目标表 | 级联删除 |
| `@Rel[has_many, Target, fk]` | has_many | 拥有多个 | 目标表 | 级联删除 |
| `@Ref[Target, via: ...]` | ref_many | 引用多个 | 中间表 | 目标保留 |

## 支持数据库

| 数据库 | 连接示例 | 状态 |
|---|---|---|
| MySQL / MariaDB | `Refine.open("mariadb://127.0.0.1:3306", [("username","root"),("password","secret"),("database","myapp")])` | ✅ 完整支持（`mariadb` 驱动） |
| PostgreSQL | `Refine.open("postgres://127.0.0.1:5432", [("username","postgres"),("password","secret"),("database","myapp"),("sslmode","disable")])` | ✅ 完整支持（`pgsql` 驱动，需显式 `sslmode=disable`，驱动暂不支持 SSL） |
| SQLite | — | ⚠️ 方言渲染已实现并有测试，但暂无可用 SQLite 驱动，`Refine.open("sqlite:...")` 暂不可用 |

> **MySQL upsert 版本要求**：`tx.upsert` 使用 `INSERT ... VALUES (...) AS new` 行别名语法，需 MySQL ≥ 8.0.19。`mariadb://` 连接目前走 `MySQLDialect`，但 MariaDB **服务端**不支持该语法（仅支持 `VALUES(col)`）——MariaDB 上 `tx.upsert` 会语法报错，需后续新增 MariaDB 方言分支（见审计 R-M19 跟进）。

PostgreSQL 表名若为保留字（如 `user`、`order`）需用 `@Table` 指定其他表名。

## 安装

从中心仓安装（推荐）：

```toml
[dependencies]
refine = "0.5.1"
```

或使用 git 依赖（开发版）：

```toml
[dependencies]
refine = { git = "https://atomgit.com/ystyle/refine.git", branch = "master" }
```

> GitHub 镜像：[`https://github.com/ystyle/refine`](https://github.com/ystyle/refine)

## 测试

单元 + 集成测试 **930 个全部通过**（`cjpm test`），其中包含针对真实 MySQL 与 PostgreSQL 的连接集成测试。

## 文档

- [在线文档](https://ystyle.top/refine/)
- [本地文档](docs-site/)
- [特性规划](docs/planned-features.md)

## 许可证

MIT
