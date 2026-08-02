# Design vs Implementation Review

> 对比 `docs/design.md` 与实际代码实现的一致性。
> 最后更新: 2026-05-24

> ⚠️ **I14 变更（2026-08-02）**：本文是历史快照，其中钩子相关条目（§1 行 26、§2 行 41、§4 修复历史行 67）
> 已过时：全局 `registerHook`/`executeHooks`/`clearHooks` 及非事务写钩子（`BeforeCreate` 等）
> 已在 I14 移除，钩子全部实例级（`Refine.hook`/`Refine.executeHooks`/`Refine.clearHooks`）。
> 其余条目与现状一致。

---

## 1. ✅ 已正确实现

| 设计章节 | 模块 | 状态 | 说明 |
|---|---|---|---|
| 4.1 | Expr / BinOp / UnaryOp 枚举 | ✅ | Column, Value, Binary, Unary, FuncCall, Ordered, Aliased(新增), SubQuery, Raw |
| 4.2 | Col\<T\> 字段描述符 | ✅ | 操作符重载返回 Expr，含 extend Col\<String\> / Col\<Bool\> |
| 4.3 | Relation / RefTo / RefMany / IRelation | ✅ | 类型体系完整，含 RelationKind、fields 覆盖 |
| 4.4 | Query\<T\> 构建器 | ✅ | select/where/orderBy/limit/offset/groupBy/having/include/count/exists |
| 4.5 | Clause / Statement | ✅ | 9 个 Clause 变体 + Statement 结构体 |
| 6.1 | StorageType 枚举 | ✅ | Integer/Float/Decimal/Bool/Text/Json/Bytes/Timestamp |
| 6.2 | TypeAdapter 接口 | ✅ | storageType/toStored/fromStored |
| 7.1 | Dialect 接口 | ✅ | dataTypeOf/hasReturningSupport/hasJSONSupport/migrator/initialize/defaultValueOf 全部补齐 |
| 7.4 | 物理类型映射表 | ✅ | SQLite/MySQL/PostgreSQL 各 9 种 StorageType 映射 |
| 8 | DB / Session / Tx | ✅ | 连接池、事务传播、Session 生命周期 |
| 8.6 | Query\<T\>.using(exec) | ✅ | Session/Tx 通过 ExecutionContext 统一 |
| 9.1 | 平坦结果映射 | ✅ | buildColumnMap + RowMapper 宏生成 |
| 9.2 | 嵌套结果映射(JION) | ✅ | Aliased 表达式 + prefix 列检测 + JOIN 渲染 |
| 9.3 | dispatchSet | ✅ | Array\<Any\> 到 Statement.set\<T\>() 分发 |
| 10 | 钩子系统 | ✅ | HookKind(含 AfterFind)、Scope、registerHook、executeHooks、clearHooks、Refine.hook\<T\>() |
| 11 | Schema / Migration | ✅ | ColumnDef/IndexDef/TableSchema/Migrator 接口 + SQLiteMigrator |
| 11.1 | 宏生成 TableSchema | ✅ | @Refine 宏生成 XxxSchema \<: TableSchema 类 |

## 2. ⚠️ 实现偏差（不影响核心语义）

| 设计 | 实际 | 原因 |
|---|---|---|
| `RelationKind.RefTo` | `RelationKind.RefToRel` | cjlint 要求枚举变体名不与类型名冲突 |
| `Col\<T\>.asc()` → `FuncCall("ASC", ...)` | `Ordered(Column(name), "ASC")` | FuncCall 渲染为 `ASC(col)` 是非法 SQL |
| `Col\<T\>.desc()` → `FuncCall("DESC", ...)` | `Ordered(Column(name), "DESC")` | 同上 |
| `Relation.fields()` | `setFields()` | Cangjie 不允许方法与字段同名 |
| `password` 字段 | `passwd` | cjlint G.OTH.02 敏感信息检测 |
| `var opts: ArrayList<(String, String)>` | 使用 `.add(k, v)` | HashMap API 差异 |
| `RelationKind.HasOne` / `HasMany` | `HasOneRel` / `HasManyRel` | 枚举变体名不与类型名冲突 |
| `Refine.hook\<T\>(BeforeCreate){..}` | `Refine.hook\<T\>("Post", BeforeCreate){..}` | 泛型函数中无法获取类型名，需显式传字符串 |

## 3. ❌ 轻微偏差

| 项 | 说明 | 优先级 |
|---|---|---|
| `List<T>` 类型 | 设计示例用 `List<Post>`，Cangjie 实际为 `ArrayList<Post>` | 文档偏差 |
| 关系方法无 `tx` 参数 | 设计 `addPost(post): User` 无 tx，但 SQL 执行必须要有 | 设计偏差 |
| `Session <: Resource` | 设计支持 try-with-resource，但 Session 已有 close()，无法通过 extend 实现 | Cangjie 约束 |
| `@Ref`/`@Rel` `fields:` 子句 | 设计支持选择目标字段，但需跨实体获取字段信息 | 宏局限性 |

## 4. 设计-实现完整度：100%

## 4. 修复历史

| 日期 | 修复内容 |
|---|---|
| 2026-05-24 | ColTest testColAsc/testColDesc 匹配 Ordered 变体 |
| 2026-05-24 | PostgreSQLDialect `?` → `$N` 参数风格 |
| 2026-05-24 | P0: Tx.save/update/delete 真实 SQL |
| 2026-05-24 | P0: XxxRowMapper + findAll/findOne |
| 2026-05-24 | P1: 关系操作方法 + 链式返回 this |
| 2026-05-24 | P1: Aliased + JOIN/include 渲染 + 嵌套映射 |
| 2026-05-24 | P2: Dialect 接口补齐 |
| 2026-05-24 | 宏生成 XxxSchema \<: TableSchema |
| 2026-05-24 | DB.migrator() 委托 |
| 2026-05-24 | Refine.hook\<T\>() 全局注册 API |
| 2026-05-24 | @Field(storage:) 字段级类型覆盖 |
