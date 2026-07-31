# 特性规划

## ✅ 已完成

### 钩子事务上下文 + 类型分类

HookKind 拆分为事务内/外两套，`Tx.save/update/delete` 触发 `TxBefore*` / `TxAfter*` 系列，且 `scope.db = Some(tx)`。

```cangjie
enum HookKind {
    | TxBeforeCreate | TxAfterCreate     // 事务内
    | TxBeforeUpdate | TxAfterUpdate
    | TxBeforeDelete | TxAfterDelete
    | BeforeCreate | AfterCreate          // 事务外
    | BeforeUpdate | AfterUpdate
    | BeforeDelete | AfterDelete
    | BeforeSave | AfterSave | AfterFind  // 保留
}
```

### 原始 SQL 自动映射

宏为每个实体生成 `Entity.rowMapper()` 静态方法，`Tx` / `Session` 新增 `queryAll<T>()` / `queryOne<T>()` 通用方法：

```cangjie
let users = tx.queryAll("SELECT * FROM users WHERE age > ?", [18], User.rowMapper())
let user  = tx.queryOne("SELECT * FROM users WHERE id = ?", [1], User.rowMapper())
```

### 批量插入

宏生成 `ClassNameBatchInsertSQL(entities: Array<T>)`，`Tx` 新增 `batchSave<T>(entities)` 扩展方法：

```cangjie
rf.transaction { tx =>
    let users = [user1, user2, user3]
    tx.batchSave(users)
    // 单条 INSERT INTO user (...) VALUES (?, ?), (?, ?), (?, ?)
    // user1.id = lastInsertId, user2.id = lastInsertId + 1, ...
}
```

- 宏自动生成对应行数的 `(?, ?)` 占位符，所有参数扁平化收集到单条 SQL
- 支持 TxBeforeCreate / TxAfterCreate 钩子（每个实体独立触发）
- 空输入（`entities.size == 0`）直接返回，不执行 SQL
- ID 写回：`result.lastInsertId` 为 baseId，按 `baseId + i` 推算后续 ID（适用自增主键）
- 与 `tx.save(entity)` 行为语义一致

### 多对多中间表自动迁移

宏为 `@Rel[ref_many, Target, via]` 自动生成 junction 表 Schema。调用 `Entity.schemas()` 获取所有 Schema（含 junction）：

```cangjie
rf.migrator().autoMigrate(Post.schemas())
// 自动创建：post 表 + post_tags 中间表
```

### 软删除

实体包含 `deleted_at: Int64` 字段时自动启用。查询自动加 `WHERE deleted_at = 0`，`Tx.delete()` 执行 UPDATE 而非 DELETE。

- `@HardDelete` 注解标记的实体即使有 `deleted_at` 也走物理删除
- `Tx.physicalDelete()` 方法绕过软删除，直接物理删除

### UUID / String 主键

实体 `id: String` 时自动启用 UUID 主键模式：

```cangjie
@Refine
class Order {
    var id: String = ""  // UUID 主键
    var name: String = ""
}

tx.save(order)
// 空 id 时自动 IdGenerator.generate()
// INSERT INTO \"order\" (id, name) VALUES (?, ?)
// 支持用户自定义 id：order.id = "my-id" 时不覆盖
```

- `id: Int64`（默认）→ 自增主键，INSERT 不含 id 列
- `id: String` → UUID 主键，INSERT 含 id 列，空时自动生成
- `tx.batchSave` 对 String id 实体预先生成所有 ID 后再组 SQL

### @Id 注解 + `@Id[auto, false]` + 复合主键

`@Id` 注解显式标记主键字段，支持自增开关和复合主键：

```cangjie
@Refine
class ManualIdPost {
    @Id[auto, false]    // Int64 但手动设置 id
    var id: Int64 = 0
    var title: String = ""
}

@Refine
class OrderTag {
    @Id[]               // 复合主键
    var order_id: Int64 = 0
    @Id[]
    var tag_id: Int64 = 0
}
```

- `@Id[auto, false]` 关闭自增，INSERT 包含 id 列
- 多个 `@Id[]` 声明复合主键，UPDATE/DELETE WHERE 使用所有 PK 字段
- 无 `@Id` 时自动检测 `id: Int64` 为自增主键

### aggregateWithCollections 统一 String key

`aggregateWithCollections` 从 `HashMap<Int64, T>` 改为 `HashMap<String, T>`，通过生成的 `EntityKeyFromResult` 函数提取主键字符串：

- `id: Int64` → key = `id.toString()`
- `id: String` → key = id
- 复合主键 → key = `pk1:pk2`（冒号拼接）

---

## ⬜ 待实现

### 批量更新

> **状态：未确认方案。**

当前只有单条 `tx.update(entity)`，批量需 for 循环 N 次 UPDATE。

待设计批量更新 API，可能的方案：
- 宏生成 `batchUpdateSQL` + `Tx.batchUpdate<T>(entities)`（类似批量插入）
- 每条 UPDATE 用不同的参数值，但必须复用 `SET col = ? WHERE id = ?` 模板
