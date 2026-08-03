# 关联预加载

## 四种关联类型

Refine 的关联体系按 **拥有** 和 **引用** 二分：

| 类型 | 语义 | Cangjie 字段 | include 批量查询 |
|---|---|---|---|
| `@Ref[Target, fk]` | 引用一个 | `Option<Target>` | `SELECT target.* WHERE target.id IN (fk 集合)` |
| `@Rel[has_one, Target, fk]` | 拥有一个 | `Option<Target>` | `SELECT target.* WHERE target.fk IN (父 id 集合)` |
| `@Rel[has_many, Target, fk]` | 拥有多个 | `ArrayList<Target>` | `SELECT target.* WHERE target.fk IN (父 id 集合)` |
| `@Ref[Target, via: ...]` | 引用多个 | `ArrayList<Target>` | junction 中间表 JOIN 目标表 + IN（源 id 集合） |

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

`include()` 支持嵌套预加载，关联的关联同样批量装配：

```cangjie
// 预加载 order.creator 及其 profile（两级）
let orders = Order.query().using(rf)
    .include(OrderRel.creator.withInclude(UserRel.profile))
    .all()

// 字符串点号路径，与上方 withInclude 链完全等价
let orders2 = Order.query().using(rf)
    .includeAll(["creator.profile"])
    .all()
```

`withInclude(sub)` 在关系上链式声明下一层关联，可多层嵌套；字符串路径 `includeAll(["a.b.c"])` 用点号分段，运行时逐段解析关系名（拼错的路径在运行时抛带清晰信息的 `QueryException`）。

## 如何工作的

`include()` 采用**分步批量查询**（batch include）架构，不生成 LEFT JOIN：主查询只渲染源表自身，返回主实体后按目标表执行批量子查询，再按主键/外键回填关联。

```sql
-- include(creator) + include(items)：2 条批量子查询
-- ① 主查询（无 JOIN）
SELECT * FROM orders WHERE ...
-- ② 批量 ref_to：外键 IN 查目标表
SELECT * FROM users WHERE id IN (?, ?, ...)
-- ③ 批量 has_many：fk IN 父主键查目标表
SELECT * FROM order_items WHERE order_id IN (?, ?, ...)
```

**无笛卡尔积**：主查询结果行数恒等于主实体数，`has_many` 子行不再乘入父查询；`page()` 的 total 恒为父实体计数。

**查询次数权衡**：批量 include 是「主查询 1 次 + 按目标表合并的 N 批子查询」。指向同一目标表的多个关联（如多个 `@Ref[User]`）合并为一次 IN 查询；has_one 与 has_many 共享同一 fk 也合并；主键/外键集合为空时跳过。相比单条 LEFT JOIN 大查询，查询次数增多，但消除了笛卡尔积、同表重复 JOIN、嵌套 include 不可用三个问题。

**同表多引用合并示例**：订单同时引用 `creator` 和 `updater` 两个 `User` 时，二者合并为一条 `WHERE id IN (...)`，返回值按 id 建查找表后分别按各外键回填。

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
addItems(tx: Tx, entity: OrderItem): Self   // 添加子实体（自动设置 fk）
loadItems(tx: Tx): ArrayList<OrderItem>    // 按 fk 加载所有子实体
clearItems(tx: Tx): Self                   // 删除所有子实体
removeItems(tx: Tx, entity: OrderItem): Self // 删除指定子实体
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

`tx.save(entity)` / `tx.update(entity)` / `tx.delete(entity)` 会沿关联字段自动级联处理子对象（不落库/删除被引对象本身）。所有级联写操作都在同一个 `tx` 上执行。

> **⚠ 级联不具跨语句原子性，请在事务中使用**：一次级联会执行多条 SQL（父 + 子 + 中间表）。`tx.save/update/delete` **不会隐式开启事务**——在自动提交（非事务）上下文中，每条 SQL 独立提交，中途失败会留下部分落库（部分子对象已写）。要保证整体原子性，请把级联写操作包在 `rf.transaction { tx => ... }`（或手动 `begin/commit/rollback`）内，回滚时级联产生的全部写入一起回滚。设计细节见仓库内 `docs/plans/2026-08-01-cascade-save-design.md` 第 6.6 节。

### 级联语义

| 关联 | `tx.save` | `tx.update` | `tx.delete` |
|---|---|---|---|
| `ref_to`（`@Ref[Target, fk]`） | 只维护 fk（见下），**不**保存/更新/删除被引对象 | 只维护 fk（见下） | 不动被引对象 |
| `has_one`（`@Rel[has_one]`） | 回填 fk 并级联 save/update 子对象 | 回填 fk 并级联 save/update 子对象 | 从库加载并级联删除子对象 |
| `has_many`（`@Rel[has_many]`） | 回填 fk 并级联 save/update 每个子对象 | 回填 fk 并级联 save/update 每个子对象 | 从库加载并逐个级联删除子对象 |
| `ref_many`（`@Ref[Target, via]`） | 按关联列表重建中间表 | 按关联列表重建中间表 | 清空中间表（不动目标表） |

> **注意**：`ref_many` 列表整体赋值后，列表中的目标对象须先 `tx.save` 获取 id（`id != 0`），否则级联在 `appendX` 守卫处抛异常（见 [六件套 - 目标 id 校验](#ref-many-关联管理-api六件套)）。

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

- **整体赋值** `user.posts = [...]` 触发：字段被重写为 `prop`，setter 将 `_postsModified` 置为 `true`，随后 `tx.save/update(user)` 会级联处理该列表
- **一次性语义**：级联处理完该字段后标记复位为 `false`——后续 `tx.update` 不再重放子列表，直到再次整体赋值
- **`.add()` 等原地修改不触发**：`user.posts.add(p)` 走 getter 返回同一底层列表引用，不会经过 setter，标记保持 `false`；需要同步时请重新整体赋值

```cangjie
let u = User()
u.name = "Alice"
let ps = ArrayList<Post>()
ps.add(p1)
ps.add(p2)
u.posts = ps               // 整体赋值 → _postsModified = true
tx.save(u)                 // 级联保存 p1、p2，处理完标记复位为 false

tx.update(u)               // 标记已复位 → 仅更新 user 本身，子列表不重放

let ps2 = ArrayList<Post>()
ps2.add(p1)
ps2.add(p2)
ps2.add(p3)
u.posts = ps2              // 再次整体赋值 → 标记重新置位
tx.update(u)               // 重新级联：p1/p2 已有 id 走 update，p3 无 id 落库

u.posts.add(p4)            // getter 原地 add → 标记不置位
tx.update(u)               // 不级联，p4 不会落库（需重新整体赋值）
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

> **注意（幽灵对象边界）**：被引对象须先 `tx.save` 获取 id，再赋值给父实体并 save/update；否则 fk 会按 `id == 0` 视为清空，标记在第一次 save 后复位，后续 update 不再回填。需重新整体赋值才回填。
>
> ```cangjie
> p.author = Some(u)   // u.id == 0（幽灵对象）
> tx.save(p)           // user_id = 0，标记复位
> tx.save(u)           // u 得 id
> tx.update(p)         // 标记已复位 → user_id 仍为 0（不回填）
>
> p.author = Some(u)   // 重新整体赋值 → 标记置位
> tx.update(p)         // 回填 user_id = u.id
> ```

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

子对象删除遵循**自身策略**：软删除实体软删（`UPDATE deleted_at`）、物理删除实体硬删。

**`tx.physicalDelete(parent)` 硬删父 + 软删子的孤儿策略**：父物理删时，软删子仍走软删（`UPDATE deleted_at`，行保留），随后父行被物理删除——子行 `deleted_at` 置位但外键指向已删父，成为**孤儿行**。这是有意的：软删子保留历史/审计/恢复能力，物理删父不应连带抹掉子历史。若不允许孤儿，需在删父前手动按需删除子对象。全软删路径（`tx.delete`）不会产生孤儿（父、子均只 `UPDATE deleted_at`，行都在）。

### 环 / 菱形安全

- **save/update**：`visited` 按**对象引用**（`refEq`）去重，菱形共享（A→B、A→C、B→C 同一实例）不会重复插入
- **delete**：`visited` 按 `(type, id)` 键去重——`loadX` 每次新建实体实例，`refEq` 无法识别 DB 常驻环（如自引用表 A↔B），必须用 `"ClassName:pk"` 键终止递归，并阻止对同一 `(type, id)` 重复 DELETE

## ref_many 关联管理 API（六件套）

`@Ref[Target, via: ...]` 关联除 `loadX` / `getX` 外，还会为每个 `ref_many` 字段生成一套直接操作中间表的 API（以 `Post.tags` 为例，方法名 = 动词 + 字段名首字母大写）：

```cangjie
appendTags(tx: Tx, tag: Tag): Post               // 添加关联：INSERT 中间表，返回 this
appendTags(tx: Tx, arr: Array<Tag>): Post        // 逐条 INSERT（循环）
replaceTags(tx: Tx, arr: Array<Tag>): Post       // 重建：先清空再逐条添加
deleteTags(tx: Tx, tag: Tag): Post               // 移除关联：DELETE 中间表对应行
deleteTags(tx: Tx, arr: Array<Tag>): Post        // 逐条移除（循环）
clearTags(tx: Tx): Post                          // 清空所有关联：DELETE 全部中间表行
countTags(tx: Tx): Int64                         // 中间表记录数
loadTags(tx: Tx): ArrayList<Tag>                 // 通过中间表加载全部关联
```

行为约定：

- 所有方法**必须传入 `tx`**（在事务内执行）
- 除 `countX` / `loadX` 外返回 `this`，可链式调用
- **目标 id 为空抛异常**：`append` / `delete` 传入的目标 `id == 0`（Int64 主键）或 `id == ""`（String 主键）时抛 `Exception`（消息形如 `"ref_many tags: target Tag has empty id, save it first"`）——先 `tx.save` 目标再关联
- **源实体需先 `tx.save`（`this.id != 0`）**：空 id 守卫只校验目标，未保存的源实体调用 `append` / `delete` 会向中间表写入 0 值源 id 的脏关联
- 这些方法与 `loadX`/`getX` 互不干扰：直接操作中间表，不修改实体的关联列表

```cangjie
// t1/t2/t3 为已 tx.save 的 Tag
rf.transaction { tx: Tx =>
    let p = Post.query().using(tx)
        .filter(Post.col().id == 1)
        .one().getOrThrow()

    p.appendTags(tx, t1)                 // INSERT INTO post_tags (post_id, tag_id) VALUES (?, ?)
    p.appendTags(tx, [t2, t3])           // 逐条 INSERT
    p.countTags(tx)                      // 3
    p.replaceTags(tx, [t1])              // DELETE 全部 + 逐条 INSERT → 1
    p.deleteTags(tx, t1)                 // 移除 → 0
    p.clearTags(tx)                      // 清空
    p.appendTags(tx, t1)                 // 重新关联
    let loaded = p.loadTags(tx)          // [t1]
}
```

## 已知限制

- **目标实体必须有单列 `id` 主键**：批量 IN 以目标 `id` 为键，嵌套 include 的目标主键读取也硬编码 `id`（`@Id` 自定义主键名目标、复合主键目标不支持）
- **复合主键主实体的集合 include 不支持**：`has_many` / `has_one` / `ref_many` 需要主实体单列主键的原始值，复合主键主实体执行前抛带说明的 `QueryException`
- **字符串路径 `includeAll` 不支持字段子集**：路径只能由纯点号关系名组成（如 `"author.profile"`），不能携带字段；需要字段子集请用 `include(rel, fields)` 或 `withInclude` 链手写
- **`batchSave` / `batchUpdate` 不级联**：批量操作只处理传入的实体数组本身，不沿关联字段递归
- **update 列表移除不自动删库**：从关联列表移除子对象不会删除其数据库行
- **级联操作不隐式开启事务**：由单个 `tx.save/update/delete` 触发，全程共用同一个 `tx`，但**不改变底层连接的提交模式**——非事务（自动提交）下每条级联 SQL 独立提交，中途失败无原子性；请在 `rf.transaction` 内使用，失败自动回滚
- **`physicalDelete` 硬删父**：子对象仍遵循自身删除策略，软删子仍软删（行保留，`deleted_at` 置位），父行物理删除后软删子成为孤儿——属有意的历史保留策略，见[级联删除](#级联删除)
