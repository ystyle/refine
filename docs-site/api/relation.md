# Relation

关联映射。四类关联 `RefTo`(ref_one) / `HasOne`(has_one) / `HasMany`(has_many) / `RefMany`(ref_many) 均实现 `IRelation` 接口，用于 `Query.include()`。

## 四种关联语义

| 类 | 注解 | 语义 | 外键位置 | 级联删除 |
|---|---|---|---|---|
| `RefTo<T>` | `@Ref[Target, fk]` | 引用一个（ref_one） | 当前表 | 不删除 |
| `HasOne<T>` | `@Rel[has_one, Target, fk]` | 拥有一个 | 目标表 | 随主表删除 |
| `HasMany<T>` | `@Rel[has_many, Target, fk]` | 拥有多个 | 目标表 | 随主表删除 |
| `RefMany<T>` | `@Ref[Target, via: ...]` | 引用多个 | 中间表 | 不删除 |

## IRelation 接口

```cangjie
import refine.*
import std.collection.HashMap
import std.database.sql.QueryResult

public interface IRelation {
    func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>)
    func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any
    func getFieldSetter(): (Any, Any) -> Unit
}
```

返回元组：`(关联类型, 关联名, 目标表名, 外键, via表, 字段列表)`

## 关联类型枚举

```cangjie
enum RelationKind {
    | RefToRel     // @Ref — ref_one
    | HasOneRel    // @Rel[has_one]
    | HasManyRel   // @Rel[has_many]
    | RefManyRel   // @Ref[Tag, via: ...] — ref_many
}
```

## RefTo\<T\> — ref_one

引用关联（外键在当前表）。你引用别人，别人不受你生命周期影响。

```cangjie
let rel = RefTo<User>("creator", Col<Any>("user_id"),
    [Col<Any>("id"), Col<Any>("name")],
    "users", creatorMapper, creatorSetter)
```

### 生成的 SQL

```sql
LEFT JOIN users creator ON orders.user_id = creator.id
```

## HasOne\<T\> — has_one

拥有关联（外键在目标表）。你拥有一个，被关联物随你删除。

```cangjie
let rel = HasOne<Invoice>("invoice", "order_id",
    [Col<Any>("id")], "invoices",
    invoiceMapper, invoiceSetter)
```

### 生成的 SQL

```sql
LEFT JOIN invoices invoice ON orders.id = invoice.order_id
```

## HasMany\<T\> — has_many

拥有集合关联（外键在目标表）。你拥有多个，被关联物随你删除。

```cangjie
let rel = HasMany<OrderItem>("items", "order_id",
    [Col<Any>("id"), Col<Any>("product")], "order_items",
    itemMapper, itemSetter)
```

### 生成的 SQL

```sql
LEFT JOIN order_items items ON orders.id = items.order_id
```

### 去重

`has_many` 和 `ref_many` 使用 `aggregateWithCollections()` 对结果集按 `(主实体ID : 关联名 : 子实体ID)` 去重。

## RefMany\<T\> — ref_many

引用集合关联（通过中间表）。你引用多个，被引用物不受你的生命周期影响。

```cangjie
let rel = RefMany<Tag>("tags", "order_tags",
    [Col<Any>("id"), Col<Any>("name")], "tags",
    tagMapper, tagSetter)
```

### 生成的 SQL

```sql
LEFT JOIN order_tags tags_junction ON orders.id = tags_junction.order_id
LEFT JOIN tags tags ON tags_junction.tag_id = tags.id
```

中间表约束：`via` 表名对应的中间表必须包含 `sourceTable_id` 和 `targetTable_id` 两列。

### 关联管理方法（六件套）

`@Refine` 宏为每个 `ref_many` 字段生成一套直接操作中间表的实例方法（以 `Post.tags` 为例，方法名 = 动词 + 字段名首字母大写）：

| 方法 | 返回 | 行为 |
|---|---|---|
| `appendTags(tx: Tx, t: Tag): Post` | 链式 `this` | `INSERT` 中间表一行 |
| `appendTags(tx: Tx, arr: Array<Tag>): Post` | 链式 `this` | 逐条 `INSERT`（循环） |
| `replaceTags(tx: Tx, arr: Array<Tag>): Post` | 链式 `this` | 清空后重建（`DELETE` 全部 + 逐条 `INSERT`） |
| `deleteTags(tx: Tx, t: Tag): Post` | 链式 `this` | `DELETE` 中间表对应行 |
| `deleteTags(tx: Tx, arr: Array<Tag>): Post` | 链式 `this` | 逐条 `DELETE`（循环） |
| `clearTags(tx: Tx): Post` | 链式 `this` | `DELETE` 中间表全部行 |
| `countTags(tx: Tx): Int64` | `Int64` | `SELECT COUNT(*)` |
| `loadTags(tx: Tx): ArrayList<Tag>` | 列表 | JOIN 加载全部关联 |

约定：

- 所有方法**必须传 `tx`**（在事务内执行）
- 目标 id 为空（Int64 `id == 0` / String `id == ""`）时 `append` / `delete` 抛 `Exception`（`"ref_many <field>: target <Target> has empty id, save it first"`）
- **源实体需先 `tx.save`（`this.id != 0`）**：空 id 守卫只校验目标，未保存的源实体调用 `append` / `delete` 会写入 0 值源 id 的脏关联
- 除 `countX` / `loadX` 外均返回 `this` 支持链式
- 直接操作中间表，不修改实体关联列表（与 `loadX`/`getX` 互不干扰）

## 字段覆盖

`include()` 的第二个参数可以覆盖关联目标返回的字段：

```cangjie
q.include(OrderRel.creator, [Col<Any>("name")])
// 只预加载 creator.name，不加载其他字段
```
