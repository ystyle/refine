# 实体定义

## 基本结构

使用 `@Refine` 宏标记的类会被识别为实体。id 字段约定为 `Int64` 类型的主键。

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

## 自定义表名

默认表名是类名的驼峰转小写（`User` → `user`, `BlogPost` → `blogpost`）。使用 `@Table` 覆盖：

```cangjie
@Refine
@Table["sys_users"]
class User {
    var id: Int64 = 0
    var name: String = ""
}
```

## 字段类型映射

| Cangjie 类型 | StorageType | SQLite | MySQL | PostgreSQL |
|---|---|---|---|---|
| `Int64` / `Int32` / `Int16` / `Int8` / `UInt*` | `Integer` | `INTEGER` | `BIGINT` | `BIGINT` |
| `Float64` / `Float32` | `Float` | `REAL` | `DOUBLE` | `DOUBLE PRECISION` |
| `String` | `Text` | `TEXT` | `VARCHAR(255)` | `VARCHAR(255)` |
| `Bool` | `Bool` | `INTEGER` | `TINYINT(1)` | `BOOLEAN` |

## 自定义存储类型

使用 `@Field[StorageType]` 覆盖字段的存储类型：

```cangjie
@Refine
class Article {
    var id: Int64 = 0
    @Field[String]
    var title: String = ""
    @Field[Text]
    var body: String = ""
}
```

## 关联字段

四种关联：引用 (ref) 和拥有 (has)，各有一对一和一对多。

### @Ref\[Target, foreignKey] — ref_one

引用一个。你的外键指向目标表。你删，目标还在。

```cangjie
@Refine
class Order {
    var id: Int64 = 0
    var total: Float64 = 0.0
    var status: String = ""
    var user_id: Int64 = 0

    @Ref[User, user_id]
    var creator: Option<User> = None
}
```

### @Rel\[kind, Target, foreignKey/via]

| kind | 语义 | Cangjie 类型 | SQL |
|---|---|---|---|
| `has_many` | 拥有多个 | `ArrayList<Target>` | LEFT JOIN ON source.id = target.fk |
| `has_one` | 拥有一个 | `Option<Target>` | LEFT JOIN ON source.id = target.fk |
| `ref_many` | 引用多个 | `ArrayList<Target>` | 两次 LEFT JOIN（via 中间表） |

```cangjie
@Refine
class Order {
    var id: Int64 = 0
    var total: Float64 = 0.0
    var status: String = ""
    var user_id: Int64 = 0

    // ref_one: 引用创建人，人不在了订单还在
    @Ref[User, user_id]
    var creator: Option<User> = None

    // has_many: 拥有明细，删单明细跟着删
    @Rel[has_many, OrderItem, order_id]
    var items: ArrayList<OrderItem> = ArrayList<OrderItem>()

    // has_one: 拥有一条发票记录，删单发票跟着删
    @Rel[has_one, Invoice, order_id]
    var invoice: Option<Invoice> = None

    // ref_many: 引用标签，删单标签还在
    @Rel[ref_many, Tag, order_tags]
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

- `has_one` / `has_many`：被关联物外键指向你的 id（外键在目标表），你拥有其生命周期
- `ref_many`：`via` 参数指定中间表名（如 `order_tags`），中间表需含 `source_id` 和 `target_id`

## 自动生成的代码

`@Refine` 宏为每个实体生成以下代码（以 `User` 为例）：

| 生成项 | 说明 |
|---|---|
| `UserCols` | 字段描述符结构体，内含 `Col<T>` 字段 |
| `UserRel` | 关联定义类，内含 `IRelation` 字段 |
| `User.query()` | 预配置的 `Query<User>` 工厂方法 |
| `User.col()` | 返回 `UserCols()` |
| `User.rowMapper()` | 返回 `UserRowMapper` 函数引用，用于 `queryAll/queryOne` |
| `User.schemas()` | 返回所有 Schema（主表 + junction 表），用于迁移 |
| `Tx.save(User)` | INSERT 扩展方法 |
| `Tx.update(User)` | UPDATE 扩展方法 |
| `Tx.delete(User)` | DELETE 扩展方法 |
| `UserRowMapper` | 行映射器函数 |
| `UserColumnNames` | 列名数组函数 |
| `UserSchema` | `TableSchema` 实现 |
