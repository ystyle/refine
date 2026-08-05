# R-M19 设计：MariaDBDialect 分支 + 运行时服务器类型探测

> 日期：2026-08-04
> 目标：修复 MariaDB 服务端上 `tx.upsert` 语法错误——当前 `detectDialect("mariadb")` 返回 MySQLDialect，生成 `INSERT ... AS new`（MySQL 8.0.19+ 语法），真实 MariaDB 服务端不支持。

## 背景

- R-M19（audit/2026-08-03:133）：MySQL `VALUES(col)` 已废弃 → 迁到 `INSERT ... VALUES (...) AS new ON DUPLICATE KEY UPDATE col = new.col`
- 但 `AS new` 是 MySQL 8.0.19+ 语法，**MariaDB 服务端不支持**（仅支持 `VALUES(col)`）
- `detectDialect("mariadb")` 返回 MySQLDialect（refine.cj:167），真实 MariaDB 上 upsert 语法报错
- 之前仅测 MySQL 9.7，MariaDB 不兼容不可见

## 关键事实（本环境实测，2026-08-04）

1. **MariaDB 11.8.8 容器已拉起**（daocloud 镜像，端口 3307）
2. **`AS new` 在 MariaDB 上报错**：`ERROR 1064 syntax error near 'AS new ON DUPLICATE KEY UPDATE'`；`VALUES(col)` 正常（实测验证）
3. **mariadb 驱动能连 MariaDB 服务器**：`SELECT VERSION()` 返回 `11.8.8-MariaDB-ubu2404`（驱动握手兼容，无服务器类型检测，但连接/查询正常）
4. **驱动结果列 1-based**：`result.get<String>(0)` 抛 `The index must be greater than 0`，须 `get<String>(1)`（与 paramOffset 一致，已知约束）
5. **区分依据**：`SELECT VERSION()` 返回串含 `MariaDB` → MariaDB；否则 MySQL。**URL 协议不可靠**（项目自己用 `mariadb://` 连 MySQL 9.7）

## 设计

### 1. 新增 MariaDBDialect

```
class MariaDBDialect <: MySQLDialect
```

仅覆盖 `upsertSQL`：退回 `VALUES(col)` 写法（MariaDB 不支持 `AS new`）。其余继承 MySQLDialect（quoteIdentifier 反引号、dataTypeOf、migrator 等全部一致）。

- `name()` 返回 `"mariadb"`（与 detectParamOffset 的 driver 名对齐）
- `upsertSQL` 实现：与 MySQLDialect 相同结构，但
  - `VALUES` 后**不加** `AS new`
  - 非冲突列更新用 `col = VALUES(col)`（MariaDB 老语法）
  - version 自增：`col = VALUES(col) + 1`？——**需验证**：MariaDB 的 `VALUES(col)` 在 ON DUPLICATE KEY UPDATE 里引用新插入值，`VALUES(version) + 1` 是新值+1。与 MySQL `new.col` 语义等价。需真实 MariaDB 验证
  - 无操作更新（全冲突列）：`col = VALUES(col)`（恒等赋值，语法合法）
- 其余方法全部继承（无 override）

### 2. 运行时服务器类型探测

`detectDialect(driverName)` 无法区分（只认 URL 协议）。改为**建连后探测**：

```cangjie
func detectDialect(name: String): Dialect  // 保留，静态：URL 协议 → SQLite/MySQL/PG
func detectServerDialect(name: String, ds: Datasource): Dialect  // 新增：mariadb 时探测
```

`Refine.open` / `DatabaseConfig.toRefine`：
- `driverName` 非 `mariadb` → 走原 `detectDialect`（SQLite/MySQL/PG 不探测）
- `driverName == "mariadb"` → 建连执行 `SELECT VERSION()`（用 `get<String>(1)` 读），含 `MariaDB` → `MariaDBDialect()`，否则 `MySQLDialect()`
- 探测失败（连接异常等）→ 回退 `MySQLDialect()`（不阻断打开），记录？

**探测开销**：一次连接 + 一次查询。仅在 Refine.open 时执行一次，缓存到 Refine.dialect。可接受。

**探测时机**：`ds = drv.open(url, opts)` 后、`pooled = PooledDatasource(ds)` 前？——探测用 `ds.connect()` 拿一个连接执行查询后关闭，不影响池。

### 3. 手动覆盖入口

用户可显式指定方言（跳过探测）：
```cangjie
Refine.open(url, opts, dialect: Dialect)  // 新增重载
```
或配置。**本轮是否做？**——探测已覆盖绝大多数场景（真实 MySQL/MariaDB 自动识别）。手动覆盖用于特殊场景（如代理层隐藏版本）。**建议记档，不做**（YAGNI）。

### 4. 影响面

| 项 | 影响 |
|---|---|
| MySQLDialect | 不变（MySQL 9.7 继续用 AS new） |
| detectDialect | 保留静态版；新增 detectServerDialect |
| Refine.open / toRefine | mariadb 时走探测 |
| detectParamOffset | mariadb=1 不变（驱动属性） |
| 宏层 | 不变（upsertSQL 是方言方法） |
| DB 收敛 | DB 是纯连接层不含方言，不受影响 |

## 测试计划（TDD）

1. **单元**（dialect_mariadb_test.cj 新文件）：
   - `MariaDBDialect.name() == "mariadb"`
   - upsertSQL 生成 `VALUES (?)` + `col = VALUES(col)`（无 `AS new`）
   - version 自增 SQL 正确
   - 全冲突列无操作更新 SQL 正确
   - 继承 MySQL：quoteIdentifier 反引号、dataTypeOf
2. **探测**（refine_test.cj）：
   - `detectServerDialect` 对 MariaDB 探测串返回 MariaDBDialect
   - 对 MySQL 探测串返回 MySQLDialect
   - 探测失败回退 MySQLDialect
3. **真实集成**（mariadb_integration_test.cj 新文件，连 3307）：
   - `Refine.open("mariadb://127.0.0.1:3307")` 探测到 MariaDBDialect
   - upsert roundtrip：plain upsert 更新冲突行、versioned upsert 自增
   - 环境守卫（容器不在时跳过，如 tryMariaDB()）
4. **回归**：现有 MySQL 9.7 集成全绿（AS new 路径不受影响）

## 环境

- MariaDB 容器：`refine-mariadb-test`，端口 3307，库 refine_test
- 测试用 `mariadb://127.0.0.1:3307`，root/45dbe6a6-...

## 完成定义
- [ ] MariaDBDialect 存在，upsertSQL 用 VALUES(col)
- [ ] Refine.open / toRefine 对 mariadb 驱动做运行时探测
- [ ] 真实 MariaDB 集成 upsert roundtrip 通过
- [ ] MySQL 9.7 回归无影响
- [ ] 全量测试通过
- [ ] 审计 R-M19 标记已解决
