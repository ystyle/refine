# DB 收敛为纯连接层 设计方案

> 日期：2026-08-03
> 目标：按 `docs/refine-architecture.md` 设计初衷，将 `DB` 收敛为纯连接层，消除 DB/Refine 双路径。

## 背景

`docs/refine-architecture.md`（早期架构设计）明确"将 DB（连接管理）与 Refine（运行时配置）合并为统一的 Refine 实例"，但**一直未执行完**——`DB` 类作为独立路径残留至今：

- `DB` 同时承担连接管理（datasource）+ ORM 职责（dialect/migrator/paramOffset）
- 与 `Refine` 几乎重复持有 datasource/dialect/paramOffset
- 但 `DB` 路径缺 hook（Session/Tx ref=None）、`using(db)` 缺 dialect/offset——因为 DB 不该有这些职责

生产代码（非测试）几乎不用 DB 路径（example 走 Refine，`DB.migrator()` 无生产调用方），只 `config.cj` 的 DatabaseConfig/Registry 自身用 DB。

## 目标状态

| | 收敛后 `DB`（连接层） | `Refine`（ORM 层） |
|---|---|---|
| 持有 | `datasource` + `paramOffset` + 连接池参数 | `DB` + `dialect` + `hookRegistry` + `idGenerator` |
| `session()` | ✅ 裸 Session（带 paramOffset） | 内部经 db.session() + 注入 ref |
| `transaction()` | ✅ 裸事务（带 paramOffset） | 内部经 db + 注入 ref |
| 方言 | ❌ 移除 | ✅ |
| paramOffset | ✅ 保留（**驱动适配属性**） | 经 DB |
| hook | ❌ | ✅ |
| migrator | ❌ 移除 | ✅（dialect.migrator(db)） |
| Query 绑定 | ❌ | ✅ |
| close() | ✅ | ✅（转调 db） |

### 关键设计点：paramOffset 归属 DB

paramOffset 是 **refine 适配 mariadb 驱动的补偿**（mariadb 强制 1-based 参数/结果索引，`parameters[index-1]`）。它属于**连接适配层**而非 SQL 渲染层——所以保留在 DB，`Session/Tx` 绑定参数时仍需要。

### 关键设计点：迁移器仍依赖 DB.session

迁移器（SQLiteMigrator/MySQLMigrator/PostgreSQLMigrator）用 `db.session()` 执行 DDL，且**自带 dialect 字段**（不依赖 DB.dialect）。收敛后迁移器继续接收 `DB` 参数——因为 DB 仍提供 session/execute。`dialect.migrator(db: DB)` 接口不变。

## 具体改动

### 1. `src/db.cj` — DB 类收敛

**移除**：
- `dialect` 字段 + `getDialect()` + 含 dialect 的构造（`init(ds, dialect)` / `init(ds, paramOffset, dialect)`）
- `migrator()`（extend DB 块）

**保留**：
- `datasource` + `paramOffset` + 连接池 props
- `init(ds)` / `init(ds, paramOffset)`
- `session()` / `transaction()` / `close()`
- `DB.open`（建 datasource + paramOffset，不再 detectDialect）

**Session/Tx 简化**：
- 移除 `dialectOpt` 字段 + 含 dialect 的构造（`Session(conn, paramOffset, dialect)` / `Tx(conn, paramOffset, dialect)`）
- `getDialect()` 只经 `ref`（`Some(rf) => rf.getDialect()`，`None => SQLiteDialect()` 降级或抛错？——见下）
- 保留 `ref` + `paramOffset`

**getDialect 降级问题**：DB 路径的 Session/Tx 无 dialect。`ExecutionContext.getDialect()` 被 `using(exec)` 用来设 `queryDialect`。裸 Session（DB 路径）getDialect 返回什么？方案：DB 路径不再有 ORM 查询能力（Query.using(DB) 废弃），裸 Session 主要用于手写 SQL。`getDialect()` 对裸 Session 抛明确错误（"bare DB session has no dialect, use Refine for ORM queries"），或返回 SQLiteDialect 降级。**决策：抛错**——DB 是纯连接，不该用于 ORM 渲染。

### 2. `src/refine.cj` — Refine 持有 DB

```cangjie
public class Refine {
    private var db: DB                    // 原来是 datasource + paramOffset
    private var dialect: Dialect
    private var hookRegistry = ...
    private var idGenerator = ...

    internal init(db: DB, dialect: Dialect) {
        this.db = db
        this.dialect = dialect
    }
}
```

- `Refine.open` → 建 `DB(pooled, offset)` → `Refine(db, detectDialect(driverName))`
- `session()` → `let s = db.session(); s.ref = Some(this); s`（注入 ref）
- `transaction()` → 经 `db.transaction` 但需要注入 ref——DB.transaction 返回 Tx 但 Tx 无 ref。改：Refine.transaction 直接操作 db.datasource？或 DB.transaction 接受 ref 参数。**决策**：DB.transaction 保留裸事务（无 ref）；Refine.transaction 自己用 `db` 的内部连接构建 Tx（ref=Some(this)）。看 DB 是否暴露 datasource——DB 的 datasource 是 private。方案：Refine.transaction 走 `db.transaction` 但 Tx 需要 ref → 需要 DB 提供 `transactionWithRef(action)` 或暴露连接获取。**设计**：DB 增加 `func connect(): Connection`（内部用），Refine.transaction 用它建 Tx(conn, this, offset)。或 DB.transaction 接受 `ref: Option<Refine>`。评估最干净的——倾向 DB.transaction 加可选 ref 参数（默认 None），Refine 传 Some(this)。

- `getParamOffset()` → `db.getParamOffset()`（DB 需暴露）
- `migrator()` → `dialect.migrator(this.db)`（不再临时建 DB）
- `close()` → `db.close()`

### 3. `src/config.cj` — DatabaseConfig/Registry

- `DatabaseConfig.toDB()` → 改为 `toDB()` 返回**纯 DB**（去 dialect）或 `toRefine()` 返回 Refine？
  - 现状 `toDB()` 建 `DB(pooled, offset, d)`。收敛后 DB 不再要 dialect。
  - **决策**：`DatabaseConfig` 增加 `toRefine(): Refine`（建纯 DB + dialect），`toDB()` 保留返回纯 DB（供 DatabaseRegistry 用）。DatabaseRegistry 从存 DB 改为存 Refine？——Registry 是"数据库实例注册表"，收敛后应存 Refine（完整 ORM 实例）。**决策**：`DatabaseRegistry` 存 `Refine`（`instances: HashMap<String, Refine>`），`get(name)` 返回 Refine，`register/config` 不变。这是破坏性 API 变更（get 返回类型 DB→Refine），测试需更新。

### 4. `src/query_include.cj` — `using(DB)` 重载

`using(database: DB)` 现在只设 executor（缺陷）。收敛后 DB 是纯连接，不该用于 ORM Query。**决策：移除 `using(DB)` 重载**（用户应 `Refine.open` 后 `using(rf)`）。或者保留但抛错提示用 Refine。**倾向移除**——它是缺陷 API。

### 5. `dialect_*.cj` — `migrator(db: DB)` 不变

迁移器继续接收 DB（用 session 跑 DDL），接口不变。但 `Refine.migrator()` 传 `this.db`。

## 破坏性变更清单

1. `DB` 移除 `getDialect()`/`migrator()`/dialect 构造
2. `Session/Tx` 移除 dialect 构造 + dialectOpt
3. `DatabaseRegistry.get()` 返回 `Refine`（原 DB）
4. `Query.using(DB)` 移除
5. 裸 Session.getDialect() 抛错

## 测试影响

- `db_test.cj`（~25 处 DB 使用）：DB 构造去 dialect、getDialect 断言删除/改
- `migrator_*_test.cj`：`DB(MockDatasource())` 仍可用（DB 保留无 dialect 构造）；`migrator(db)` 不变
- `config_test.cj`（~44 处）：toDB 改 toRefine、Registry.get 返回 Refine
- `refine_test.cj`：Refine.open 内部变化不影响外部 API
- 方言测试 `dialect_*_test.cj` 里 `DB(MockDatasource(), MySQLDialect())` 构造 → 需改为 `DB(MockDatasource())` + 迁移器显式传方言

## 完成定义

- [ ] DB 只含 datasource + paramOffset + 连接池，无 dialect/migrator
- [ ] Refine 持有 DB，session/transaction 注入 ref，hooks 正常
- [ ] DatabaseRegistry 存 Refine，get 返回 Refine
- [ ] using(DB) 移除
- [ ] 全部测试更新，全绿
- [ ] docs/refine-architecture.md 标注已落地
