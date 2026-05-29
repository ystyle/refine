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
