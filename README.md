# Refine ORM

仓颉语言编译期类型安全 ORM。零运行时反射，全部在编译期通过宏生成 SQL、Mapper、Schema。

## 特色

- **编译期类型安全** — 字段引用、查询条件、关联预加载均在编译期校验，没有运行时字符串拼写错误
- **四类关联体系** — `has_one` / `has_many`（拥有）和 `ref_one` / `ref_many`（引用），语义明确
- **关联预加载** — `include()` 一次查询带出所有关联，不产生 N+1 问题
- **多方言** — 内置 SQLite / MySQL / PostgreSQL 支持，各方言自动适配
- **数据迁移** — 从实体定义自动生成 `CREATE TABLE`，无需手写 DDL
- **生命周期钩子** — 事务内/外两套 Hook 系统，支持 BeforeCreate / AfterFind 等 15 种钩子

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

let rf = Refine.open("sqlite::memory:")
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

## 安装

```toml
[dependencies]
refine = { git = "https://atomgit.com/ystyle/refine.git", branch = "master" }
```

> GitHub 镜像：[`https://github.com/ystyle/refine`](https://github.com/ystyle/refine)

## 文档

- [在线文档](https://ystyle.top/refine/)
- [本地文档](docs-site/)
- [特性规划](docs/planned-features.md)

## 许可证

MIT
