# 第二批 CRUD 增强实现计划：乐观锁 + 审计字段 + 事务隔离级别

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现乐观锁 `@Version`、审计字段 `created_at`/`updated_at` 自动填充、事务隔离级别三种能力，覆盖单条与批量操作，跨 MySQL/PostgreSQL 双库验证。

**Architecture:** 全部在宏层生成行为（`refine_macro.cj`），复用现有 FieldInfo 元数据管线。新增 `FieldInfo.isVersion` 标记、审计字段检测（created_at/updated_at 且 DateTime 类型）；在生成 save/update/batchSave/batchUpdate/upsert 的 Tx 扩展时注入审计时间、version 初始化/递增、WHERE version 校验。新增 `IsolationLevel` 枚举与 `transaction(level)` 重载，Dialect 接口加 `isolationSQL(level)`。

**Tech Stack:** 仓颉（Cangjie）语言，宏编程（std.ast / quote / MacroMessage），stdx 驱动（mariadb/pgsql），cjpm 构建。

---

### Task 1: 异常类型 OptimisticLockException

**Files:**
- Modify: `src/error.cj`
- Test: `src/error_test.cj`

**Step 1: 写失败测试**

在 `src/error_test.cj` 的 `RefineExceptionTest` 类末尾追加：

```cangjie
@TestCase
public func testCreateOptimisticLockException(): Unit {
    let e = OptimisticLockException("User", 42, 3, 5)
    @Expect(e.message.contains("User"), true)
    @Expect(e.message.contains("42"), true)
    @Expect(e.expected, 3)
    @Expect(e.actual, 5)
}
```

**Step 2: 运行确认失败**

Run: `cjpm test --filter 'RefineExceptionTest.testCreateOptimisticLockException'`
Expected: FAIL（类型不存在编译错误）

**Step 3: 实现**

在 `src/error.cj` 末尾追加：

```cangjie
public class OptimisticLockException <: RefineException {
    public var entityType: String
    public var pk: Int64
    public var expected: Int64
    public var actual: Int64
    public init(entityType: String, pk: Int64, expected: Int64, actual: Int64) {
        this.entityType = entityType
        this.pk = pk
        this.expected = expected
        this.actual = actual
        super("optimistic lock conflict on " + entityType + " pk=" + pk.toString() +
            " expected version " + expected.toString() + " got " + actual.toString())
    }
}
```

**Step 4: 运行确认通过**

Run: `cjpm test --filter 'RefineExceptionTest.testCreateOptimisticLockException'`
Expected: PASS

**Step 5: 提交**

```bash
git add src/error.cj src/error_test.cj
git commit -m "feat: OptimisticLockException"
```

---

### Task 2: IsolationLevel 枚举 + Dialect.isolationSQL

**Files:**
- Modify: `src/dialect.cj`
- Modify: `src/dialect_mysql.cj` / `src/dialect_postgres.cj` / `src/dialect_sqlite.cj`
- Test: `src/dialect_sqlite_test.cj` / `src/dialect_mysql_test.cj` / `src/dialect_postgres_test.cj`

**Step 1: 定义枚举与接口方法**

在 `src/dialect.cj` 顶部（Dialect 接口前）添加：

```cangjie
public enum IsolationLevel {
    | ReadUncommitted | ReadCommitted | RepeatableRead | Serializable
}

extend IsolationLevel <: ToString {
    public func toString(): String {
        match (this) {
            case ReadUncommitted => "READ UNCOMMITTED"
            case ReadCommitted => "READ COMMITTED"
            case RepeatableRead => "REPEATABLE READ"
            case Serializable => "SERIALIZABLE"
        }
    }
}
```

在 `Dialect` 接口加：`func isolationSQL(level: IsolationLevel): String`

**Step 2: 三个方言实现**

`dialect_mysql.cj` / `dialect_postgres.cj`：

```cangjie
public func isolationSQL(level: IsolationLevel): String {
    "SET TRANSACTION ISOLATION LEVEL " + level.toString()
}
```

`dialect_sqlite.cj`：

```cangjie
public func isolationSQL(level: IsolationLevel): String {
    throw RefineException("SQLite does not support transaction isolation levels")
}
```

**Step 3: 单元测试**

三个方言测试文件各加：

```cangjie
@TestCase
public func testIsolationSQL(): Unit {
    let d = MySQLDialect()
    @Expect(d.isolationSQL(IsolationLevel.Serializable), "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
}
```

SQLite 测试断言抛异常（`expectThrow` 或 try/catch 方式，参照现有测试风格）。

**Step 4: 运行测试确认通过**

Run: `cjpm test --filter 'DialectSqliteTest' && cjpm test --filter 'DialectMySQLTest' && cjpm test --filter 'DialectPostgresTest'`
Expected: 全部 PASS

**Step 5: 提交**

```bash
git add src/dialect.cj src/dialect_mysql.cj src/dialect_postgres.cj src/dialect_sqlite.cj src/dialect_sqlite_test.cj src/dialect_mysql_test.cj src/dialect_postgres_test.cj
git commit -m "feat: IsolationLevel 枚举与方言 isolationSQL"
```

---

### Task 3: Refine.transaction 隔离级别重载

**Files:**
- Modify: `src/db.cj`
- Modify: `src/refine.cj`（若 transaction 委托在 Refine 类）

**Step 1: 读现有 Refine 的 transaction 委托**

先读 `src/refine.cj` 确认 `Refine` 类如何委托 `DB.transaction`（上一批已确认 DB.transaction 存在）。找 `Refine` 类中 `transaction` 方法。

**Step 2: 实现 transaction(level) 重载**

在 DB 类加：

```cangjie
public func transaction<T>(level: IsolationLevel, action: (Tx) -> T): T {
    let conn = datasource.connect()
    let tx = Tx(conn, paramOffset)
    let d = getDialect()
    tx.execute(d.isolationSQL(level), [])
    tx.begin()
    try {
        let result = action(tx)
        tx.commit()
        return result
    } catch (e: Exception) {
        tx.rollback()
        throw e
    }
}
```

**Step 3: Refine 委托**

在 `Refine` 类加对应的 `transaction(level, action)` 委托方法。

**Step 4: 单元测试（mock 验证 SET 执行）**

`src/db_test.cj` 或新增隔离测试：使用内存 SQLite 时确认抛 RefineException（SQLite 不支持）；MySQL/PG 的隔离级别验证放在 Task 7 集成测试。

**Step 5: 提交**

```bash
git add src/db.cj src/refine.cj src/db_test.cj
git commit -m "feat: transaction 隔离级别重载"
```

---

### Task 4: 宏元数据——@Version 识别 + 审计字段检测

**Files:**
- Modify: `src/macros/refine_macro.cj`

**Step 1: FieldInfo 加 isVersion**

`FieldInfo` struct 增加 `var isVersion: Bool`，构造器加参数 `isVersion`（默认 false）。

**Step 2: @Version 属性宏**

```cangjie
public macro Version(attr: Tokens, input: Tokens): Tokens {
    let decl = parseDecl(input)
    setItem("fieldName", decl.identifier.value)
    input
}
```

**Step 3: applyAuditVersion 函数**

在 `applyIdAnnotations` 之后新增：

```cangjie
func applyAuditVersion(fields: ArrayList<FieldInfo>, versionMessages: ArrayList<MacroMessage>): ArrayList<FieldInfo> {
    var result = ArrayList<FieldInfo>()
    for (f in fields) {
        var updated = f
        for (m in versionMessages) {
            if (m.getString("fieldName") == f.name) {
                if (f.typeName != "Int64") { throw Exception("@Version field must be Int64: " + f.name) }
                updated.isVersion = true
            }
        }
        result.add(updated)
    }
    result
}

func findAuditFields(fields: ArrayList<FieldInfo>): (Bool, Bool) {
    var hasCreatedAt = false
    var hasUpdatedAt = false
    for (f in fields) {
        if (f.name == "created_at" && f.typeName == "DateTime") { hasCreatedAt = true }
        if (f.name == "updated_at" && f.typeName == "DateTime") { hasUpdatedAt = true }
    }
    (hasCreatedAt, hasUpdatedAt)
}
```

**Step 4: Refine 宏主流程接入**

在 `mergeFieldOverrides` 之后调用 `applyAuditVersion`；获取 `@Version` 子消息并传入。计算审计标记 `hasCreatedAt/hasUpdatedAt`，供后续 builder 使用。

**Step 5: 编译确认**

Run: `cjpm build`
Expected: 编译通过（新宏未使用，不影响现有实体）

**Step 6: 提交**

```bash
git add src/macros/refine_macro.cj
git commit -m "feat: 宏识别 @Version 与审计字段"
```

---

### Task 5: 单条 save/update 注入审计 + version

**Files:**
- Modify: `src/macros/refine_macro.cj`

**Step 1: buildAuditTokens 辅助**

生成 save 前注入 created_at/updated_at 的 tokens：

```cangjie
func buildAuditCreateTokens(auditFields: ...): Tokens {
    // created_at = DateTime.now(); updated_at = DateTime.now();
    // 仅当用户未手动设置（值为 default）时注入——DateTime 默认无法判断，故始终注入，文档说明会覆盖
}

func buildAuditUpdateTokens(auditFields: ...): Tokens {
    // updated_at = DateTime.now();
}
```

**Step 2: buildVersionInitTokens**

save/upsert 时 version 初始化（0 → 1）。

**Step 3: buildTxSaveExtend 接入**

在钩子执行**之前**注入审计字段（created_at/updated_at）与 version 初始化。

**Step 4: buildTxUpdateExtend 重构**

- 在钩子前注入 `updated_at`
- `buildUpdateSQLString`：有 version 时 SET 不含 version（version 由代码递增），WHERE 追加 `AND version = ?`；参数末尾追加当前 `version`
- 执行后：`rowCount == 0` 抛 `OptimisticLockException`（需要知道实际版本——先查库拿实际版本再抛，或异常里 actual 用 -1，标注由用户重查；**采用先 SELECT 实际版本再抛**，语义完整）
- 成功后：`entity.version += 1`

**Step 5: 更新 buildUpdateSQLString / buildUpdateEntityArrayTokens**

version 字段在 SET 中排除（保持 `f.isPk || isRelationField || f.isVersion`），WHERE 追加 `AND version = ?`，参数追加 entity.version。

**Step 6: 编译 + 现有测试通过**

Run: `cjpm build && cjpm test`
Expected: 全绿（现有实体无 @Version/审计字段，行为不变）

**Step 7: 提交**

```bash
git add src/macros/refine_macro.cj
git commit -m "feat: save/update 注入审计字段与 version"
```

---

### Task 6: 批量 save/update/upsert 注入审计 + version

**Files:**
- Modify: `src/macros/refine_macro.cj`

**Step 1: buildTxBatchSaveExtend 接入**

循环内每实体：注入 created_at/updated_at、version 初始化（0→1）。

**Step 2: buildTxBatchUpdateExtend + buildBatchUpdateSQLFunc**

- batchUpdate：每个实体刷新 updated_at
- version：SET 不含 version；`buildBatchUpdateSQLFunc` 的 WHERE 部分（pk IN 前）追加 version 校验有难度（CASE 结构复杂），**方案**：version 参与 CASE WHEN 的 pk 匹配条件？不行——batchUpdate 的 WHERE 是 `pk IN (...)`。改为：在 SET 中追加 `version = CASE pk WHEN ? THEN ?+1 ...`，即把 version 当普通列参与 CASE，值传 `entity.version + 1`；WHERE 仍按 pk。冲突时无行匹配返回，需校验 rowCount 是否等于 entities.size，不足则抛异常。
- `buildTxBatchUpdateExtend`：执行后校验 `result.rowCount == entities.size`，不等则抛 `OptimisticLockException`（实际版本未知，actual=-1，文档说明）
- 编译期版本初始化

**Step 3: buildTxUpsertExtend 接入**

- 插入侧：created_at/updated_at 注入、version 初始化
- 冲突更新侧：MySQL `ON DUPLICATE KEY UPDATE` 需追加 `version = version + 1, updated_at = <time>`；PG `ON CONFLICT DO UPDATE` 同理。需扩展 `Dialect.upsertSQL` 签名或新增 `upsertSQLWithAudit`。**方案**：`upsertSQL` 增加可选审计参数，或宏内自行拼接。先实现 MySQL/PG 追加 `updated_at` 与 version 递增，SQLite 抛异常不变。

**Step 4: 编译 + 现有测试通过**

Run: `cjpm build && cjpm test`
Expected: 全绿

**Step 5: 提交**

```bash
git add src/macros/refine_macro.cj src/dialect*.cj
git commit -m "feat: batchSave/batchUpdate/upsert 审计与 version"
```

---

### Task 7: 双库集成测试

**Files:**
- Modify: `example/src/entity.cj`
- Modify: `example/src/service_test.cj`

**Step 1: 新增带审计 + version 的实体**

在 `example/src/entity.cj` 加：

```cangjie
@Refine
@Table["audit_notes"]
public class AuditNote {
    var id: Int64 = 0
    var title: String = ""
    var created_at: DateTime = DateTime.now()
    var updated_at: DateTime = DateTime.now()
    @Version
    var version: Int64 = 0
}
```

（init 默认值避免构造器显式赋值问题；ORM 会覆盖注入）

**Step 2: ServiceChecks 共享断言**

在 `example/src/service_test.cj` 的 `ServiceChecks` 加：

- `auditFieldsFilled`：save 后 created_at/updated_at 非零、version==1
- `auditFieldsOnUpdate`：update 后 updated_at 变化、created_at 不变、version 递增
- `optimisticLockConflict`：事务内查出实体→模拟并发改库（直接 UPDATE 库 version+1）→tx.update 抛 OptimisticLockException→事务回滚
- `isolationLevel`：`rf.transaction(IsolationLevel.Serializable)` 正常执行，PG 端可查 `SHOW TRANSACTION ISOLATION LEVEL` 断言

**Step 3: 两个测试类接入**

MySQL/PostgreSQL 两个测试类各加 4 个 @TestCase 方法调用共享断言。审计表经 autoMigrate 自动建表（先 DROP 再建，遵循 initOnce 模式）。

**Step 4: 运行双库集成测试**

Run: `cjpm test`
Expected: 全部 PASS（含新 8 个用例）

**Step 5: 提交**

```bash
git add example/src/entity.cj example/src/service_test.cj
git commit -m "test: 乐观锁/审计字段/隔离级别双库集成测试"
```

---

### Task 8: 文档

**Files:**
- Modify: `docs-site/guide/crud.md`
- Modify: `docs-site/guide/entities.md`
- Modify: `docs-site/guide/transactions.md`
- Modify: `docs-site/api/query.md`（若无涉略则跳过）
- Modify: `docs-site/api/refine.md` / `docs-site/api/transaction.md`

**Step 1: entities.md**

新增「审计字段」与「乐观锁」章节：字段名约定、@Version 注解、行为说明、updateWhere 不处理的边界。

**Step 2: crud.md**

save/update/batch 章节补充审计字段自动填充与 version 语义；批量冲突抛异常说明。

**Step 3: transactions.md**

补充隔离级别用法：`rf.transaction(IsolationLevel.Serializable)`、SQLite 不支持、默认行为。

**Step 4: API 参考**

`api/error.md` 加 OptimisticLockException；`api/refine.md` 加 transaction 重载；`api/col.md` 无需动。

**Step 5: 文档站构建验证**

Run: `cd docs-site && npm run docs:build`
Expected: build complete

**Step 6: 提交**

```bash
git add docs-site/
git commit -m "docs: 第二批功能文档 - 乐观锁/审计字段/隔离级别"
```

---

### Task 9: 全量回归 + 收尾

**Step 1: 全量测试**

Run: `cjpm test`
Expected: TOTAL 全 PASS，无 SKIPPED/ERROR

**Step 2: 检查宏展开调试输出**

Run: `ls src/*.cj.macrocall` 确认无残留调试文件；如有 `audit_notes` 相关 macrocall 检查 SQL 正确性。

**Step 3: 合并 master 并推送**

```bash
git checkout master && git merge feature/batch2 && git push origin master
```

---

## 风险与注意

- **DateTime 默认值判断**：DateTime 无法用 `== default` 判断用户是否手动设置，设计决策为「始终注入」，用户若需自定义时间需在 TxBeforeCreate 钩子中覆盖（钩子在注入之后执行，可覆盖）
- **batchUpdate 乐观锁**：CASE 结构下 version 递增走「version 当普通 SET 列，值传 version+1」，冲突检测靠 `rowCount == entities.size`；**注意**：MySQL 默认 rowCount 是变更行数，若某行值完全相同则不计数，可能导致误报。需在 SET 中始终让 version 参与变更（version+1 保证每行必变），规避该问题
- **upsert 审计**：Dialect.upsertSQL 签名扩展需同步三个方言实现；SQLite 不支持
- **实体默认值**：审计字段默认值用 `DateTime.now()` 初始化字段，避免编译器要求显式 init；宏始终覆盖注入
- **宏报错**：@Version 非 Int64 或同时出现多个 @Version 时宏阶段抛错（用 Exception 即可，宏阶段会转编译错误）
- **多 @Version 禁止**：applyAuditVersion 中对重复 version 字段抛异常
