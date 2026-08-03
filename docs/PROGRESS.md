# Refine 设计进度

> 本文档追踪 Refine ORM 的全栈设计进度，按依赖关系排序。
> 状态：✅ 完成 | 🔧 设计中 | ⏳ 待开始 | 📝 需要迭代

---

## Phase 0：顶层设计（✅ 完成）

| 模块 | 状态 | 说明 |
|:---|:---:|:---|
| 关系模型（hasOne/hasMany/ref_to/ref_many） | ✅ | 拥有-引用二分 + 读写边界约束 |
| 宏体系（@Refine / @Rel / @Ref） | ✅ | 宏职能划分与 API 契约 |
| StorageType + TypeAdapter | ✅ | 逻辑类型映射体系 |
| Dialect 方言接口 | ✅ | 跨数据库方言抽象 |
| 物理类型映射表 | ✅ | 4 数据库 + StorageType 完整映射 |

---

## Phase 1：表达式系统与查询构建器（✅ 设计完成）

### 1.1 SQL 表达式系统（✅）

`docs/design.md#4` 已完成设计：

- **`Expr` 枚举**：`Column | Value | BinOp | UnaryOp | FuncCall | SubQuery | Raw`
- **`Col<T>` 字段描述符**：重载 `==` / `!=` / `>` / `<` / `>=` / `<=` 返回 `Expr`
- **`BinOp` / `UnaryOp`**：二元/一元操作符枚举
- **关键决策**：`&&` / `||` 不支持重载，使用 `Expr.and()` / `Expr.or()` 方法组合

### 1.2 Clause / Statement 构建器（✅）

- **`Clause` 枚举**：`SelectClause | FromClause | WhereClause | OrderByClause | LimitClause | OffsetClause | JoinClause`
- **`Statement`**：组合所有 Clause，提供 `render(dialect)` → `(sql, params)`

### 1.3 关系描述符 `Relation<TTarget>`（✅）

- **`Relation<TTarget>`**：类型安全的关联引用，替代字符串
- **`RefTo<T>` / `RefMany<T>`**：子类化 `Relation<TTarget>`，由宏生成
- **`Post.rel.author`**：编译期可检查的标识符，字符串藏在宏生成的代码中
- **`include(IRelation)`**：`Query<T>` 接收接口，支持 `fields()` 覆盖

### 1.4 查询构建器 `Query<T>`（✅）

- `where()` / `orderBy()` / `limit()` / `offset()` 构建链
- `include()` 接收 `IRelation`，编译期检查关联名和字段
- `all()` / `one()` / `count()` / `exists()` 执行方法

### 1.5 连接与 Session 管理（✅ 设计完成）

`docs/design.md#8` 已完成设计：

- **`DB`**：数据源入口，包装 `PooledDatasource`，提供连接池配置
- **`Session`**：连接会话，包装 `Connection`，提供 SQL 执行能力
- **`Tx`**：事务，继承 Session，+ `commit()` / `rollback()` / `save()`
- **事务传播**：`db.transaction { tx => ... }` 自动 commit/rollback，嵌套事务用保存点
- **`Query<T>.using(session|tx)`**：执行上下文绑定

### 1.6 结果映射 Row → Object（✅ 设计完成）

`docs/design.md#9` 已完成设计：

- **平坦映射**：`columnInfos.name` → index 映射，逐字段 `qr.get<T>(idx)`
- **嵌套映射**：~~JOIN 列前缀 `"author.id"` 分拆~~（2026-08-03 已由 batch include 取代）——主查询无 JOIN，include 走批量分步查询协议：主查询后按目标表 `WHERE id/fk IN (...)` 批量取目标，HashMap 查找表回填 + 嵌套递归（见 `docs/design.md#9.2`）
- **参数绑定**：`dispatchSet()` 运行时类型分发 `Array<Any>` → `Statement.set<T>()`
- 自定义类型走两层：`qr.get<NativeType>()` + `TypeAdapter.fromStored()`

---

## Phase 2：运行时与扩展（已设计 ⏳ 待实现）

| 模块 | 状态 | 说明 |
|:---|:---:|:---|
| Schema / 自动迁移 | ✅ 设计完成 | GORM 兼容：只加不减，diff 对比，宏生成 TableSchema |
| 生命周期钩子 | ✅ 设计完成 | 非侵入注册，按序执行，失败中止 |
| 错误处理体系 | ⏳ | RefineException 层次 |
| 日志与调试 | ⏳ | SQL 日志、慢查询、宏展开调试 |
| 配置与初始化 | ⏳ | 数据源配置、多数据源 |

## Phase 3：高级查询（✅ 设计完成）

| 模块 | 状态 | 说明 |
|:---|:---:|:---|
| GROUP BY / HAVING | ✅ | `GroupByClause` + `HavingClause`，`Query<T>.groupBy()` / `.having()` |
| 聚合函数 | ✅ | `Expr.FuncCall` 已有，`Query<T>.count()` / `.exists()` |
| 子查询 / JOIN 控制 | ✅ | `Expr.SubQuery` + `Clause.JoinClause` |
| 原生 SQL 逃生舱 | ✅ | `Expr.Raw` |
| Upsert | ⏳ | 待插入/更新生成时设计 |

---

## 依赖关系图

```
Expr 系统  ←── Relation 描述符 ──→ Col<T> 字段描述符
   ↑                ↑
   |                |
Clause/Statement    @Refine 宏
   ↑                ↑
   |                |
 Query<T> ──────────┘
   ↑
   |
DB/Session → 结果映射 (Row → Object) → Dialect → 物理 SQL
```

---

## 当前聚焦

**Phase 1 设计已完成，进入 Phase 2：**

下一个设计目标：**连接与 Session 管理**（`DB` 连接池、事务传播、Session 生命周期）。

或 **结果映射 Row → Object**（查询结果组装回实体与嵌套关联对象）。
