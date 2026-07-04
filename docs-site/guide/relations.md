# 关联预加载

## 四种关联类型

Refine 的关联体系按 **拥有** 和 **引用** 二分：

| 类型 | 语义 | Cangjie 字段 | SQL |
|---|---|---|---|
| `@Ref[Target, fk]` | 引用一个 | `Option<Target>` | `LEFT JOIN target ON source.fk = target.id` |
| `@Rel[has_one, Target, fk]` | 拥有一个 | `Option<Target>` | `LEFT JOIN target ON source.id = target.fk` |
| `@Rel[has_many, Target, fk]` | 拥有多个 | `ArrayList<Target>` | LEFT JOIN + 结果去重 |
| `@Ref[Target, via: ...]` | 引用多个 | `ArrayList<Target>` | 两次 LEFT JOIN（via 中间表） |

### 拥有 vs 引用

- **拥有关系**（`has_one` / `has_many`）：被关联物的外键指向你的 id。删除你时被关联物一并删除。
  - `Order has_many OrderItem` → `order_item.order_id` 指向 `order.id`
- **引用关系**（ref_one / ref_many）：你的外键指向被关联物的 id（或通过中间表）。删除你时被引用物不受影响。
  - `Order ref_one User` → `order.user_id` 指向 `user.id`
  - `Order ref_many Tag` → 通过中间表 `order_tags` 间接引用

## 实体定义

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

    @Ref[User, user_id]
    var creator: Option<User> = None

    @Rel[has_many, OrderItem, order_id]
    var items: ArrayList<OrderItem> = ArrayList<OrderItem>()

    @Rel[has_one, Invoice, order_id]
    var invoice: Option<Invoice> = None

    @Ref[Tag, via: order_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

@Refine
class OrderItem {
    var id: Int64 = 0
    var product: String = ""
    var quantity: Int64 = 0
    var price: Float64 = 0.0
    var order_id: Int64 = 0
}

@Refine
class Invoice {
    var id: Int64 = 0
    var invoice_no: String = ""
    var amount: Float64 = 0.0
    var order_id: Int64 = 0
}

@Refine
class Tag {
    var id: Int64 = 0
    var name: String = ""
}
```

这个例子覆盖全部四种关系：

| 关联 | 示例 | 关系 | 被删时 |
|---|---|---|---|
| ref_one | 订单 → 创建人 | 引用 | 创建人还在 |
| has_many | 订单 → 明细 | 拥有 | 明细被删 |
| has_one | 订单 → 发票 | 拥有 | 发票被删 |
| ref_many | 订单 → 标签 | 引用 | 标签还在 |

## 预加载

```cangjie
// 预加载 ref_one
let orders = Order.query().using(rf)
    .include(OrderRel.creator)
    .all()

// 预加载 has_one
let orders = Order.query().using(rf)
    .include(OrderRel.invoice)
    .all()

// 预加载 has_many
let orders = Order.query().using(rf)
    .include(OrderRel.items)
    .all()

// 预加载 ref_many
let orders = Order.query().using(rf)
    .include(OrderRel.tags)
    .all()
```

## 预加载关联的关联

只支持一层 include。关联结构是编译期从 `@Ref` / `@Rel` 注解推断的。

## 如何工作的

`include()` 在 SQL 层面生成 LEFT JOIN 并选择关联表的字段。对于 `has_many` 和 `ref_many`（集合关联），查询结果可能在多行中包含重复的主实体数据，Refine 使用 `aggregateWithCollections` 按主实体 ID 去重并聚合子实体。

```sql
-- has_many LEFT JOIN 示例
SELECT o.*, oi.id AS items.id, oi.product AS items.product
FROM orders o
LEFT JOIN order_items oi ON o.id = oi.order_id

-- ref_many 两次 LEFT JOIN 示例
SELECT o.*, t.id AS tags.id, t.name AS tags.name
FROM orders o
LEFT JOIN order_tags ot ON o.id = ot.order_id
LEFT JOIN tags t ON ot.tag_id = t.id
```

## 指定关联字段

默认预加载关联目标的所有字段。可以使用 `include()` 的第二个参数指定：

```cangjie
Order.query().using(rf)
    .include(OrderRel.creator, [Col<Any>("name")])
    .all()
```

## 关联方法的编译期生成

`@Refine` 宏还会为每个实体生成关联导航方法：

### @Rel[has_many] 生成

```
addItem(tx: Tx, entity: OrderItem): Self   // 添加子实体（自动设置 fk）
loadItems(tx: Tx): ArrayList<OrderItem>    // 按 fk 加载所有子实体
clearItems(tx: Tx): Self                   // 删除所有子实体
removeItem(tx: Tx, entity: OrderItem): Self // 删除指定子实体
```

### @Rel[has_one] 生成

```
setInvoice(tx: Tx, entity: Invoice): Self  // 设置关联（自动设 fk）
loadInvoice(tx: Tx): Option<Invoice>       // 加载关联
removeInvoice(tx: Tx): Self                // 删除关联
```

### @Ref 生成（ref_one）

```
loadCreator(tx: Tx): Option<User>    // 按 fk 加载关联
getCreator(): Option<User>           // 返回已预加载的关联
```

### @Ref[ref_many] 生成

```
loadTags(tx: Tx): ArrayList<Tag>     // 通过中间表加载关联
getTags(): ArrayList<Tag>            // 返回已预加载的关联
```
