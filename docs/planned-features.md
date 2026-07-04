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

---

## ⬜ 待实现

### 批量更新

> **状态：未确认方案。**

当前只有单条 `tx.update(entity)`，批量需 for 循环 N 次 UPDATE。

待设计批量更新 API，可能的方案：
- 宏生成 `batchUpdateSQL` + `Tx.batchUpdate<T>(entities)`（类似批量插入）
- 每条 UPDATE 用不同的参数值，但必须复用 `SET col = ? WHERE id = ?` 模板

### UUID 主键 + 用户自定义 ID

> **状态：待确认设计方案是否继续推进。**

核心方案：宏检测 `id` 字段类型，分叉代码生成。

| 特性 | `id: Int64`（现有） | `id: String`（新增） |
|------|-------------------|---------------------|
| INSERT | 不含 id 列，依赖自增 | **含 id 列** |
| 自动生成 | `result.lastInsertId` | **`idGenerator.generate()`**（空时才生成） |
| 用户自设 | 忽略，走自增 | **支持，不覆盖** |
