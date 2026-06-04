# 待实现特性（已确认设计方向）

## UUID 主键 + 用户自定义 ID

**核心方案：宏检测 `id` 字段类型，分叉代码生成。**

| 特性 | `id: Int64`（现有） | `id: String`（新增） |
|------|-------------------|---------------------|
| INSERT | 不含 id 列，依赖自增 | **含 id 列** |
| 自动生成 | `result.lastInsertId` | **`idGenerator.generate()`**（空时才生成） |
| 用户自设 | 忽略，走自增 | **支持，不覆盖** |
| 聚合 key | `entity.id.toString()` → `HashMap<String, T>` | entity.id → `HashMap<String, T>` |

- `aggregateWithCollections` 统一用 `HashMap<String, T>`（内部 key 永远是 String）
- `id: String` 用户自行设 id 时框架不覆盖，为空时自动生成
- IdGenerator 接口可替换（UUID/ULID/Snowflake 等），默认 UUID
- 通过 Hook 机制实现自动生成，不侵入核心流程

## 软删除

**方案：默认全局软删除 + 实体级 `@HardDelete` 覆盖**

- 实体默认软删除：`deleted_at` 字段标记，查询自动加 `WHERE deleted_at IS NULL`
- `@HardDelete` 注解标记的实体走物理删除
- `forceDelete()` 方法绕过软删除
- 宏在生成查询时自动附加 `deleted_at IS NULL` 条件
- 需要迁移支持：老表自动添加 `deleted_at` 列

## 多对多中间表自动迁移

`@Rel[ref_many, Tag, post_tags]` 中的 `via` 中间表目前需要手动 `CREATE TABLE`。待实现：

- 宏为 `ref_many` 关联自动生成中间表 Schema
- `autoMigrate` 检测到 `ref_many` 关系时自动创建 `via` 表
- 中间表列：`source_id` + `target_id`（均为 `BIGINT NOT NULL`）

## 原始 SQL 结果对象映射

**痛点：** 当前 `tx.query(sql, params)` 返回 `QueryResult`，需要手动 `while(r.next()) { r.get<T>(idx) }` 逐字段提取，繁琐且容易出错。

**方案：宏暴露 rowMapper + Tx/Session 通用映射方法，复用现有基础设施。**

已可用复用组件：
- `buildColumnMap(columnInfos, offset)` — 列名→索引映射
- `UserRowMapper(result, columnMap) → User` — 宏已生成
- `paramOffset` — Tx/Session 已持有

计划 API：

```cangjie
// 宏生成（在 Entity 上添加）
extend User {
    public static func rowMapper(): (QueryResult, HashMap<String, Int64>) -> User {
        UserRowMapper
    }
}

// Tx/Session 通用方法
let users = tx.queryAll("SELECT * FROM users WHERE age > ?", [18], User.rowMapper())
let user  = tx.queryOne("SELECT * FROM users WHERE id = ?", [1], User.rowMapper())
```

- 不需要反射，编译期类型安全
- `queryOne` 自动处理 `Option<T>`（无结果返回 `None`）
- 自动处理列索引偏移（MariaDB）

## 钩子事务上下文 + 类型分类

**痛点：** 当前 `Tx.save` 和 `Entity.save` 共用同一套 `BeforeCreate/AfterCreate`，无法区分注册。且 `Scope<T>.db` 从未赋值，钩子内拿不到当前事务。

### HookKind 拆分为两套

```cangjie
enum HookKind {
    // 事务内钩子 —— 在 Tx.save/update/delete 中触发，scope.db = Some(tx)
    | TxBeforeCreate | TxAfterCreate
    | TxBeforeUpdate | TxAfterUpdate
    | TxBeforeDelete | TxAfterDelete

    // 事务外钩子 —— 在 Entity.save/update/delete 中触发，scope.db = None
    | BeforeCreate | AfterCreate
    | BeforeUpdate | AfterUpdate
    | BeforeDelete | AfterDelete

    // 保留
    | BeforeSave | AfterSave | AfterFind
}
```

| 分类 | 示例 | `scope.db` | 回滚影响 | 典型用途 |
|---|---|---|---|---|
| **事务内** | `TxBeforeCreate` | `Some(tx)` | abort 会回滚整个事务 | 关联创建、唯一性校验、审计日志 |
| **事务外** | `BeforeCreate` | `None` | abort 仅阻止本次操作 | 格式校验、缓存清理、事件通知 |

### 宏生成映射

- `Tx.save/update/delete` → 触发 `TxBefore* / TxAfter*` 钩子，`scope.db = Some(this)`
- `Entity.save/update/delete` → 触发 `Before* / After*` 钩子，`scope.db = None`

### 完整示例

```cangjie
// 事务内钩子：自动写入审计日志，与订单创建在同一事务
rf.hook<Order>("Order", HookKind.TxBeforeCreate) { scope: Scope<Order> =>
    let tx = scope.db.getOrThrow()
    tx.execute("INSERT INTO audit_logs (entity, action) VALUES (?, ?)",
        ["Order", "create"])
}

// 事务外钩子：格式校验，不依赖数据库
rf.hook<Order>("Order", HookKind.BeforeCreate) { scope: Scope<Order> =>
    if (scope.entity.total < 0) {
        scope.abort(Exception("negative total"))
    }
}
```
