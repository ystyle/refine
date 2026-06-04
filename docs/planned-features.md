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

### UUID 主键 + 用户自定义 ID

> **状态：待确认设计方案是否继续推进。**

核心方案：宏检测 `id` 字段类型，分叉代码生成。

| 特性 | `id: Int64`（现有） | `id: String`（新增） |
|------|-------------------|---------------------|
| INSERT | 不含 id 列，依赖自增 | **含 id 列** |
| 自动生成 | `result.lastInsertId` | **`idGenerator.generate()`**（空时才生成） |
| 用户自设 | 忽略，走自增 | **支持，不覆盖** |
