# Relation

关联映射。四类关联 `RefTo`(ref_one) / `HasOne`(has_one) / `HasMany`(has_many) / `RefMany`(ref_many) 均实现 `IRelation` 接口，用于 `Query.include()`。

## 四种关联语义

| 类 | 注解 | 语义 | 外键位置 | 级联删除 |
|---|---|---|---|---|
| `RefTo<T>` | `@Ref[Target, fk]` | 引用一个（ref_one） | 当前表 | 不删除 |
| `HasOne<T>` | `@Rel[has_one, Target, fk]` | 拥有一个 | 目标表 | 随主表删除 |
| `HasMany<T>` | `@Rel[has_many, Target, fk]` | 拥有多个 | 目标表 | 随主表删除 |
| `RefMany<T>` | `@Rel[ref_many, Target, via]` | 引用多个 | 中间表 | 不删除 |

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
    | RefManyRel   // @Rel[ref_many]
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

## 字段覆盖

`include()` 的第二个参数可以覆盖关联目标返回的字段：

```cangjie
q.include(OrderRel.creator, [Col<Any>("name")])
// 只预加载 creator.name，不加载其他字段
```
