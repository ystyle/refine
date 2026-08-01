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

ref_many 的完整关联管理 API（六件套）见下文 [ref_many 关联管理 API（六件套）](#ref-many-关联管理-api-六件套)。

## 级联保存

`tx.save(entity)` / `tx.update(entity)` / `tx.delete(entity)` 会沿关联字段自动级联处理子对象（引用对象除外）。所有级联写操作都在同一个事务中执行。

### 级联语义

| 关联 | `tx.save` | `tx.update` | `tx.delete` |
|---|---|---|---|
| `ref_to`（`@Ref[Target, fk]`） | 只维护 fk（见下），**不**保存/更新/删除被引对象 | 只维护 fk（见下） | 不动被引对象 |
| `has_one`（`@Rel[has_one]`） | 回填 fk 并级联 save/update 子对象 | 回填 fk 并级联 save/update 子对象 | 从库加载并级联删除子对象 |
| `has_many`（`@Rel[has_many]`） | 回填 fk 并级联 save/update 每个子对象 | 回填 fk 并级联 save/update 每个子对象 | 从库加载并逐个级联删除子对象 |
| `ref_many`（`@Ref[Target, via]`） | 按关联列表重建中间表 | 按关联列表重建中间表 | 清空中间表（不动目标表） |

### 级联保存示例

```cangjie
rf.transaction { tx: Tx =>
    let u = User()
    u.name = "Alice"
    u.email = "alice@example.com"

    let p1 = Post()
    p1.title = "P1"
    let p2 = Post()
    p2.title = "P2"
    let posts = ArrayList<Post>()
    posts.add(p1)
    posts.add(p2)
    u.posts = posts

    let prof = Profile()
    prof.bio = "bio"
    u.profile = Some(prof)

    tx.save(u)
}
// 一次 tx.save(u) 级联落库 posts + profile
// u.id / p1.id / p2.id / prof.id 均已回填
// p1.user_id == p2.user_id == prof.user_id == u.id
```

子对象无 id → `saveCascade`（INSERT）；已有 id → `updateCascade`（UPDATE），fk 均被回填为父实体 id。

### 修改标记

级联只在关联字段被**修改**时触发。`@Refine` 宏为每个关联字段生成一个修改标记（如 `_postsModified`）：

- **整体赋值** `user.posts = [...]` 触发：字段被重写为 `prop`，setter 将 `_postsModified` 置为 `true`，随后 `tx.save/update(user)` 会级联处理
- **`.add()` 等原地修改不触发**：`user.posts.add(p)` 走 getter 返回同一底层列表引用，不会经过 setter，标记保持 `false`

```cangjie
let u = User()
u.name = "Alice"
let ps = ArrayList<Post>()
ps.add(p1)
ps.add(p2)
u.posts = ps               // 整体赋值 → _postsModified = true
tx.save(u)                 // 级联保存 p1、p2

u.posts.add(p3)            // getter 原地 add → 标记不置位
tx.update(u)               // 仅更新 user 本身，p3 不会落库
```

行映射器加载（`include` 预加载）的实体，所有修改标记为 `false`——只改普通字段再 `tx.update` 不会误触发级联。

### ref_to 外键维护

`ref_to` 只维护 fk 列，完全不管被引对象的存续（不 insert/save/update/delete 源表）：

```cangjie
p.author = Some(u)      // u.id != 0 → p.user_id = u.id（回填）
p.author = Some(ghost)  // ghost.id == 0 → p.user_id = 0（清空）
p.author = None         // p.user_id = 0（清空）
```

- `Some(u)` 且 `u.id != 0`：fk 回填为 `u.id`
- `Some(u)` 且 `u.id == 0`：视为清空（JSON 反序列化中未保存的引用目标常出现 `id=0`）
- `None`：清空 fk
- 仅当标记置位时执行（同上，整体赋值触发）

### 级联更新

`tx.update(user)` 沿 has 系子对象逐层递归，规则与 save 一致：子无 id → save，有 id → update。子对象若带 `@Version`，级联 update 同样走乐观锁校验并递增 version。

**列表移除不自动删库**：从 `posts` 列表移除的子对象，其数据库行不会被删除（只更新仍留在列表中的子对象）。需要物理移除请显式 `tx.delete(child)`。

### 级联删除

`tx.delete(user)` 按以下顺序执行：

1. `has_many` / `has_one`：通过 `loadX(tx)` **从库查询**子对象（不依赖内存关联列表），逐个 `tx.deleteCascade`
2. `ref_many`：清空中间表（`DELETE FROM junction WHERE source_id = ?`）
3. 最后删除父实体本身

```
SELECT * FROM post WHERE user_id = ?       -- 加载子对象
DELETE FROM post WHERE id = ?              -- 删除子对象
DELETE FROM post_tags WHERE post_id = ?    -- 清空中间表
DELETE FROM user WHERE id = ?              -- 删除父
```

子对象删除遵循**自身策略**：软删除实体软删（`UPDATE deleted_at`）、物理删除实体硬删。`tx.physicalDelete(user)` 硬删父时，子对象仍按自身策略处理（软删子仍软删，可能留下引用已删父的行）。

### 环 / 菱形安全

- **save/update**：`visited` 按**对象引用**（`refEq`）去重，菱形共享（A→B、A→C、B→C 同一实例）不会重复插入
- **delete**：`visited` 按 `(type, id)` 键去重——`loadX` 每次新建实体实例，`refEq` 无法识别 DB 常驻环（如自引用表 A↔B），必须用 `"ClassName:pk"` 键终止递归，并阻止对同一 `(type, id)` 重复 DELETE

## ref_many 关联管理 API（六件套）

`@Ref[Target, via: ...]` 关联除 `loadX` / `getX` 外，还会为每个 `ref_many` 字段生成一套直接操作中间表的 API（以 `Post.tags` 为例，方法名 = 动词 + 字段名首字母大写）：

```cangjie
p.appendTags(tx, t: Tag): Post               // 添加关联：INSERT 中间表，返回 this
p.appendTags(tx, arr: Array<Tag>): Post      // 批量添加
p.replaceTags(tx, arr: Array<Tag>): Post     // 重建：先清空再批量添加
p.deleteTags(tx, t: Tag): Post               // 移除关联：DELETE 中间表对应行
p.deleteTags(tx, arr: Array<Tag>): Post      // 批量移除
p.clearTags(tx): Post                        // 清空所有关联：DELETE 全部中间表行
p.countTags(tx): Int64                       // 中间表记录数
p.loadTags(tx): ArrayList<Tag>               // 通过中间表加载全部关联
```

行为约定：

- 所有方法**必须传入 `tx`**（在事务内执行）
- 除 `countX` / `loadX` 外返回 `this`，可链式调用
- **目标 id 为空抛异常**：`append` / `delete` 传入的目标 `id == 0`（Int64 主键）或 `id == ""`（String 主键）时抛 `Exception`（消息形如 `"ref_many tags: target Tag has empty id, save it first"`）——先 `tx.save` 目标再关联
- 这些方法与 `loadX`/`getX` 互不干扰：直接操作中间表，不修改实体的关联列表

```cangjie
rf.transaction { tx: Tx =>
    let p = Post.query().using(tx)
        .filter(Post.col().id == 1)
        .one().getOrThrow()

    p.appendTags(tx, t1)                 // INSERT INTO post_tags (post_id, tag_id) VALUES (?, ?)
    p.appendTags(tx, [t2, t3])           // 批量
    p.countTags(tx)                      // 3
    p.replaceTags(tx, [t1])              // DELETE 全部 + INSERT 一条 → 1
    p.deleteTags(tx, t1)                 // 移除 → 0
    p.clearTags(tx)                      // 清空
    p.appendTags(tx, t1)                 // 重新关联
    let loaded = p.loadTags(tx)          // [t1]
}
```

## 已知限制

- **`has_one` 的 String 主键目标 include 加载暂不支持**：`@Rel[has_one, Target, fk]` 且目标主键为 `String` 时，`include`/JOIN 预加载无法正确还原子对象 id（宏层无法跨类内省目标主键类型）。`ref_to` 的 String 主键目标不受影响（fk 类型在当前表可直接推导）
- **`batchSave` / `batchUpdate` 不级联**：批量操作只处理传入的实体数组本身，不沿关联字段递归
- **update 列表移除不自动删库**：从关联列表移除子对象不会删除其数据库行
- **级联非事务内需自行保证原子性**：级联多次写库，若拆散在多个事务中执行，失败时需自行 `tx.rollback()` 保证一致
- **`physicalDelete` 硬删父**：子对象仍遵循自身删除策略，软删子仍软删，可能留下引用已删父的行
