# Eager Loading (include) 设计与实现

## 问题

`include()` 生成 `SELECT *, alias_cols` 导致列名冲突，且无法精确控制加载的关联字段。

## 设计

### SQL 生成

- **所有列用 AS 指定别名**，基表列无前缀，关联列用 `关系名.列名` 做前缀
- 基表 SELECT 由宏在 `query()` 中预置完整列列表（替代现在的 `select([])`）
- JOIN 仅加在有关联的列上

```sql
-- User.query().include(UserRel.posts).all()
SELECT
  user.id    AS "id",
  user.name  AS "name",
  user.email AS "email",
  posts.id       AS "posts.id",
  posts.title    AS "posts.title",
  posts.content  AS "posts.content",
  posts.body     AS "posts.body",
  posts.user_id  AS "posts.user_id"
FROM user
LEFT JOIN post posts ON user.id = posts.user_id
```

### 列前缀与结果映射

- 无前缀列 → 主实体字段
- `前缀.列名` → 关联实体字段，按前缀分组
- HasMany/RefMany → 多行按主键聚合成 `ArrayList`

### @Ref/@Rel fields 解析

- 宏解析 `@Ref[User, user_id, fields: ["id", "name"]]` 或 `@Ref[target: User, by: "user_id", fields: ["id", "name"]]`
- 未指定时加载所有非敏感字段
- 生成的 `PostRel.author` 使用指定的 field 列表

### RowMapper

- 基表字段映射同现有逻辑
- 关联前缀列在 `include()` 场景下，由生成的 RowMapper 填充 `getAuthor()` / `getPosts()` 缓存
- HasMany 需要聚合：`HashMap<主键, 实体>` 累积行

## 实现步骤

1. 宏：`query()` 生成完整 SELECT 列列表（替代 `select([])`）
2. 宏：`@Ref/@Rel` 解析 `fields` 参数
3. 宏：生成的 IRelation 常量使用正确 fields
4. `processIncluded`：SELECT 列只加 `*` 改为显式列
5. `processIncluded`：对 RefTo/HasOne 不做聚合，HasMany/RefMany 聚合
6. RowMapper：处理前缀列

## 不做

- `TypeAdapter` 集成 — 后续再做
- RefMany 中间表 JOIN — 后续再做
