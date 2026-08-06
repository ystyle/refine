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

## String 主键（UUID / ULID）

`id: String` 时启用 String 主键模式：INSERT 包含 id 列，`Tx.save` / `Tx.batchSave` 时 id 为空则自动调用 `Refine` 的 ID 生成器（默认 Sonyflake，可通过 `setIdGenerator(UlidIdGenerator())` 等切换），并回写实体。适合分布式无冲突 ID 场景：

```cangjie
@Refine
class Event {
    var id: String = ""    // String 主键，空时自动生成
    var name: String = ""
    var payload: String = ""
}

rf.setIdGenerator(UlidIdGenerator())
rf.transaction { tx: Tx =>
    let ev = Event()
    ev.name = "deploy"
    tx.save(ev)
    // ev.id 已填充，形如 "01KYVGFGPFCJEZRKBBHJ2Q59QW"
}
```

相关配置见 [Refine API - getIdGenerator/setIdGenerator](../api/refine.md)。

## Int64 非自增主键（应用侧生成）

`@Id[auto, false]` 关闭自增后，id 为 0 时自动调用 ID 生成器（结果经 `Int64.parse` 转换）并回写。可搭配 `SonyflakeIdGenerator`（趋势递增、索引友好）替代数据库自增，批量插入无需回写 id：

```cangjie
@Refine
class Order {
    @Id[auto, false]    // 不用数据库自增，应用侧生成雪花 ID
    var id: Int64 = 0
    var amount: Int64 = 0
}

rf.setIdGenerator(SonyflakeIdGenerator())
rf.transaction { tx: Tx =>
    let o = Order()
    o.amount = 100
    tx.save(o)
    // o.id 已填充雪花 ID
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

> **PostgreSQL 注意**：
> - 标识符统一按小写处理（未加引号的 SQL 会被 PostgreSQL 折叠为小写，Refine 已保证查询/建表/CRUD 三方一致）
> - 若类名映射的表名是 PostgreSQL 保留字（如 `User` → `user`、`Order` → `order`），必须用 `@Table` 指定其他表名，例如 `@Table["users"]`
> - 关系（`@Ref`/`@Rel`）的目标表名会跟随目标实体的 `@Table` 覆盖

## 命名约定（@Refine[naming]）

实体默认表名 = 类名首字母小写（`BlogPost` → `blogpost`），列名 = 字段名（`userName` 即列名，无转换）。通过 `@Refine[naming: "snake"]` 可将表名/列名统一转换为 snake_case：

```cangjie
@Refine[naming: "snake"]
class BlogPost {
    var id: Int64 = 0
    var userName: String = ""    // 列名 → user_name
}
```

行为说明：

- **表名**：`BlogPost` → `blog_post`；**列名**：`userName` → `user_name`（已 snake_case 的名称幂等不变）
- **优先级**：`@Table` / `@Field` 显式指定 > `@Refine[naming]` 策略 > 默认行为
- **支持策略**：`"none"`（默认，等价不转换）、`"snake"`；其他值编译期报错
- **关联中间表名**：显式 `via` 不转换；默认 `via`（关系字段名）跟随策略转换（`relatedPosts` → `related_authors` 对应中间表 `related_posts`）

> **⚠ 关联实体应统一命名策略**：`has_one` / `has_many` 的 `by` 外键字段位于**目标实体**上，Refine 按**源实体**的策略计算该外键列名。若关联双方命名策略不一致（如源实体用 `snake`、目标实体默认 `none`），转换后的外键列名可能无法匹配目标实体实际的列名，导致关联查询/维护静默失效（不报错、查不到行）。同一关联链上的实体请统一使用相同的命名策略；`ref_to` 的外键在源实体自身，不受跨实体策略差异影响。

## 字段类型映射

| Cangjie 类型 | StorageType | SQLite | MySQL | PostgreSQL |
|---|---|---|---|---|
| `Int64` / `Int32` / `Int16` / `Int8` / `UInt*` | `Integer` | `INTEGER` | `BIGINT` | `BIGINT` |
| `Float64` / `Float32` | `Float` | `REAL` | `DOUBLE` | `DOUBLE PRECISION` |
| `String` | `Text` | `TEXT` | `VARCHAR(255)` | `VARCHAR(255)` |
| `Bool` | `Bool` | `INTEGER` | `TINYINT(1)` | `BOOLEAN` |
| `DateTime` | `Timestamp` | `TEXT` | `DATETIME(6)` | `TIMESTAMP` |

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

四种关联：**`@Ref` = 引用，`@Rel` = 拥有**，各有一对一和一对多。

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

### @Ref\[Target, via: ...] — ref_many

引用多个。通过中间表间接引用。你删，目标还在。

```cangjie
@Refine
class Order {
    var id: Int64 = 0
    var total: Float64 = 0.0
    var status: String = ""

    @Ref[Tag, via: order_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}
```

`via` 参数指定中间表名。中间表需含 `sourceTable_id` 和 `targetTable_id` 两列。

### @Rel\[kind, Target, foreignKey]

| kind | 语义 | Cangjie 类型 | include 批量查询 |
|---|---|---|---|
| `has_many` | 拥有多个 | `ArrayList<Target>` | `SELECT target.* WHERE target.fk IN (父 id 集合)` |
| `has_one` | 拥有一个 | `Option<Target>` | `SELECT target.* WHERE target.fk IN (父 id 集合)` |

```cangjie
@Refine
class Order {
    var id: Int64 = 0
    var total: Float64 = 0.0
    var status: String = ""
    var user_id: Int64 = 0

    // has_many: 拥有明细，删单明细跟着删
    @Rel[has_many, OrderItem, order_id]
    var items: ArrayList<OrderItem> = ArrayList<OrderItem>()

    // has_one: 拥有一条发票记录，删单发票跟着删
    @Rel[has_one, Invoice, order_id]
    var invoice: Option<Invoice> = None
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

## 审计字段（created_at / updated_at）

实体声明 `created_at` / `updated_at`（`DateTime` 类型）字段即自动启用审计，与软删除的字段名约定一致，零配置：

```cangjie
import std.time.DateTime

@Refine
class Note {
    var id: Int64 = 0
    var content: String = ""
    var created_at: DateTime = DateTime.now()
    var updated_at: DateTime = DateTime.now()
}
```

行为说明：

- `Tx.save` / `Tx.batchSave`：插入时自动注入 `created_at` 与 `updated_at`（`DateTime.now()`）
- `Tx.update` / `Tx.batchUpdate` / `Tx.upsert` 冲突更新侧：自动刷新 `updated_at`；对于从数据库加载的实体，`created_at` 保持不变（仅 `updated_at` 刷新）；手动构造的新实体执行 update 时其 `created_at` 会被写入
- 注入发生在钩子之前，`TxBeforeCreate` / `TxBeforeUpdate` 钩子中可见已填好的值
- 若需自定义时间，在钩子中覆盖即可
- **注意**：`updateWhere` / `deleteWhere`（条件批量操作）不经过实体映射层，不自动填充，由用户自行处理

## 乐观锁（@Version）

`@Version` 注解标记实体的 `Int64` 版本字段，`Tx.update` 时自动校验版本冲突：

```cangjie
@Refine
class Note {
    var id: Int64 = 0
    var content: String = ""
    @Version
    var version: Int64 = 0
}
```

行为说明：

- 字段必须为 `Int64`，且每个实体至多一个 `@Version` 字段（违反则编译报错）
- `Tx.save` / `Tx.batchSave` / `Tx.upsert` 插入时 version 为 0 自动置 1
- `Tx.update`：SQL 的 WHERE 追加 `AND version = ?`，更新成功则 version 自动 +1（内存与数据库同步）；若匹配行数为 0（版本过期或行被删）抛 [OptimisticLockException](../api/error.md#optimisticlockexception)
- `Tx.batchUpdate`：version 参与 CASE 更新（值取 version+1），执行后若匹配行数不足（有行不存在）抛 [OptimisticLockException](../api/error.md#optimisticlockexception)
- **注意**：`batchUpdate` 只检测「行缺失」，**不校验存量行的版本是否过期**（CASE 更新不比较旧版本）；若并发修改了同一行，batchUpdate 会静默覆盖并写回 version+1。需要逐行版本强校验时，请使用 `tx.update` 逐条更新
- `Tx.upsert` 冲突更新侧：version 自动 +1
- **注意**：`Tx.upsert` 冲突更新时仅数据库侧的 version 递增，实体内存中的 version 不回写；若 upsert 后需继续 `tx.update(entity)`，请先重新查询实体以获取最新 version
- **注意**：`updateWhere` / `deleteWhere` 不校验 version
- **注意**：`tx.update` 前若查询了实体，建议在同一个事务内完成读-改-写，避免长时间持有旧 version

## 软删除

实体包含 `deleted_at` 字段时自动启用软删除。`Tx.delete()` 会将 `deleted_at` 置为非零值而非物理删除，查询自动过滤已删除记录：

```cangjie
@Refine
class SoftUser {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
}

// 软删除：UPDATE softUser SET deleted_at = 1 WHERE id = ?
rf.transaction { tx: Tx => tx.delete(user) }

// 物理删除：DELETE FROM softUser WHERE id = ?
rf.transaction { tx: Tx => tx.physicalDelete(user) }
```

### @HardDelete

`@HardDelete` 注解标记的实体即使有 `deleted_at` 字段也走物理删除：

```cangjie
@Refine
@HardDelete
class Log {
    var id: Int64 = 0
    var message: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
}
```

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
| `User.findAll(q)` | 静态快捷方法，调用 `q.all()` |
| `User.findOne(q)` | 静态快捷方法，调用 `q.one()` |
| `Tx.save(User)` | INSERT 扩展方法 |
| `Tx.update(User)` | UPDATE 扩展方法 |
| `Tx.delete(User)` | DELETE 扩展方法（软删除实体为 UPDATE `deleted_at`） |
| `Tx.physicalDelete(User)` | 物理 DELETE 扩展方法（绕过软删除） |
| `UserRowMapper` | 行映射器函数 |
| `UserColumnNames` | 列名数组函数 |
| `UserSchema` | `TableSchema` 实现 |
