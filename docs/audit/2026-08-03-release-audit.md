# Refine ORM 发布前质检报告（0.5.0 大重构）

> 审查日期：2026-08-03
> 审查范围：0.5.0 版本全部改动（3 天、~140 提交）——batch include 重构、C/I 系列 Critical/Important、M 系列修复、M18 方言基类抽取、M20 Query 拆分
> 审查方式：三路并行深度审查（核心运行时 / 方言+迁移器 / 宏生成层），真实 PG/MySQL 容器验证 + 逐行核对
> 状态：**Not ready for release** — 存在 2 个 Critical + 9 个 Important + 若干 Minor，修复后需补测试沉淀。进度：**R-C1/R-C2 已修复（2026-08-03）**；**R-I1~R-I9 已修复（2026-08-03）**（R-I7 按 controller 裁决落地宏错误守卫、Option<DateTime> 完整支持延后 F4；R-I9 落地运行时预检 + 文档）；Minor 记录待处理。

---

## 一、总体评估

- **batch include 重构质量高**：装配引擎在已测路径上正确，分组/空集合跳过/共享目标去重/深度守卫/保序均验证通过，无重构引入的 Critical。
- **M18 抽取忠实**：AbstractDialect 基类与三方言原实现逐字节等价，无方言行为丢失。
- **M20 拆分干净**：方法体字节一致，public API 不变，859 测试零改动全绿。
- **M19/M10/M16/M22/M3 设计项**：实现正确、测试沉淀充分。
- **宏层标识符引号化主路径完整**：I19/I20/I21 全覆盖，级联环检测双轨正确。
- **发现问题集中在**：PG 方言 upsert 语义、参数绑定类型覆盖、AfterFind hook 触发路径、宏层关系检测白名单、DateTime 软删语义。

---

## 二、Critical（发布阻塞，Must Fix）

### R-C1. PG versioned upsert 生成非法 SQL —— 所有 PG 版本化实体 upsert 必炸
- **位置**：`src/dialect_postgres.cj:37`（upsertSQL versionCol 分支）
- **问题**：生成 `ON CONFLICT ("id") DO UPDATE SET "users"."version" = "users"."version" + 1`。真实 PG 17 实测：`SET target columns cannot be qualified with the relation name`（DO UPDATE SET 赋值目标不允许表名限定，SQLite/MySQL 允许，PG 禁止）；且 RHS 裸列名在 PG 中歧义。
- **正确形式**（实测通过）：`"version" = "users"."version" + 1`（LHS 裸列名，RHS 表限定）。
- **为什么测试没抓住**：`macro_test.cj:2231` 用 mock 把坏 SQL 固化成期望；`pgsql_integration_test.cj` 无任何 upsert 用例。
- **修法**：PG versionCol 分支改 `quoteIdentifier(c) + " = " + quoteIdentifier(table) + "." + quoteIdentifier(c) + " + 1"`，同步更新 macro_test.cj:2231，补真实 PG 集成用例；`dialect_sqlite.cj:24` 注释声称"与 PG 的 EXCLUDED 语义对应"需一并修正。

### R-C2. `dispatchSet` 静默写 NULL 给合法字段类型 —— 静默数据损坏
- **位置**：`src/db.cj:362-372`
- **问题**：`dispatchSet` 处理 Int64/Int32/String/Bool/Float64/DateTime/Array<UInt8>，其余落 `stmt.setNull(index)`。但宏接受 Int8/Int16/UInt8/UInt16/UInt32/UInt64/Float32 作为实体字段类型（`meta.cj:228-235`，无编译警告），所有写路径（save/update/upsert/batchSave）把字段值 upcast Any 传入 → UInt8/Float32 字段保存时**写 NULL**（可空列静默丢数据，NOT NULL 列报错）。
- **修法**：补缺失的 `set<...>` 分支，或（更安全）抛 `RefineException("unsupported param type ...")` 而非 setNull。补回归测试。属既有问题非重构回归，但在发布范围内。

---

## 三、Important（Should Fix）

### R-I1. `Refine.all/one` 不触发 AfterFind hook —— 静默行为不一致
- **位置**：`src/refine.cj:131-147` + `query_include.cj:136-141`
- **问题**：`rf.all(query)` 做 `query.copy().using(s)`，`using(exec)` 只设 executor/queryDialect/columnOffset **不设 ref**；copy 继承原 query 的 `ref = None`（宏 `query()` 从不设置）。故 `runAfterFindHooks` 见 ref=None 静默跳过 hook——即使绑定了注册 AfterFind 的 Refine 实例。`query.using(rf).all()` 触发，`rf.all(query)` 不触发。I14 测试未组合此场景。
- **修法**：`Refine.all/one` 设 `copy.ref = Some(this)`（或 `using()` 内传播 Session.ref）。补回归测试。

### R-I2. ref_to include 缺 fk 列时静默跳过 —— 回归 vs 旧 JOIN 路径
- **位置**：`src/query_batch.cj:66-75`
- **问题**：`.select([id, title]).include(PostRel.author)`（fk 列未选）时，C2 宽容 RowMapper 留 `user_id` 默认 0/""，`isEmptyFk` 过滤 → 批量跳过 → author 保持 None **无报错**。has_many 有守卫（`buildRawIdExtractor` 缺 pk 列抛 QueryException），ref_to 无。
- **修法**：assembleRefTo 守卫 fk 列存在于主查询结果（抛 QueryException，镜像 rawId 守卫）。

### R-I3. `one()` 对已 LIMIT 查询重复追加 LIMIT —— 语法错误
- **位置**：`src/query_exec.cj:91-95`
- **问题**：`one()` 复制全部子句（含已有 LimitClause）再追加 `LimitClause(1)` → `LIMIT 5 LIMIT 1`，三方言均语法错误。`page()` 正确剥离 Limit/Offset，`one()` 未做。
- **修法**：`one()` 像 page() 一样剥离 LimitClause/OffsetClause。

### R-I4. 共享 dialect 实例 render 非线程安全 —— 并发污染参数
- **位置**：`src/dialect_base.cj:23-24,72`
- **问题**：`params`/`paramIdx` 是实例字段，`render()` 重置后递归填充。运行时所有查询共用同一 dialect 实例（`Refine.open` 只建一次），连接池并发查询交叉污染参数缓冲与 PG `$n` 编号 → 错位 SQL。非 M18 引入（三方言原型同样），但 M18 收敛基类是修复最佳时机。
- **修法**：渲染状态收敛为局部 RenderContext（param buffer + counter）贯穿 renderBody/renderExpr，或对 render() 加锁。

### R-I5. page/count/exists/聚合丢 GROUP BY/HAVING —— total 与 items 不一致
- **位置**：`src/query_exec.cj:128-135`（copyDataClauses 只保留 From/Where/Join）
- **问题**：`q.groupBy(x).having(c).page(1,10)` 时数据 pager 含 GroupBy/Having 但 `total = COUNT(*)` 对未分组行 → total 与 items 不一致。count/exists/聚合对分组查询静默返回未分组结果。
- **修法**：count/聚合语句携带 GroupBy/Having（COUNT 对分组数据计数与 page 数据匹配），或显式拒绝/文档化。

### R-I6. I23 管理方法 SQL 仍为裸标识符 —— PG 驼峰名读写失败
- **位置**：`src/macros/relation_gen.cj:17-21`（refToSQL/hasManyLoadSQL/hasManyClearSQL/hasOneLoadSQL/hasOneRemoveSQL）
- **问题**：表名经 `TargetSchema().tableName()` 未引号拼接，`id` 与 `r.by` fk 列裸写。`@Table["CamelCase"]` 表名或驼峰 fk 在 PG 下折叠小写必然报错。用户可见 API（loadX/setX/clearX/removeX），非死路径。文档记录为 I23，本次质检确认为真实故障。
- **修法**：与 I21 相同，改 `tx.getDialect().quoteIdentifier`（方法均带 `tx: Tx`）。
- **✅ 已解决（2026-08-03）**：`relation_gen.cj` refToSQL/hasManyLoadSQL/hasManyClearSQL/hasOneLoadSQL/hasOneRemoveSQL 的目标表名、`id`、`r.by` fk 列全部经 `tx.getDialect().quoteIdentifier` 运行时引号化（与 I21 junction 引号化对齐）。既有级联/soft-delete/setProfile 测试的 SQL 断言同步更新为引号形式。新增 `ManagementSQLQuotingTest` 7 例（PG/SQLite/MySQL 三方言断言生成 SQL 引号化）+ 真实 PG/MySQL 集成测试 `testCamelCaseManagementMethods`（camelCase 表 + camelCase fk 的 loadX/clearX/setX/removeX 全链路）。

### R-I7. DateTime 软删端到端不可用 —— IS NULL 对非 Option 列恒假，静默查不到数据
- **位置**：`src/macros/refine_macro.cj:119-127` + `macro_test.cj:479`
- **问题**：唯一可编译的软删模型是非 Option DateTime（有默认值非 NULL），而生成过滤 `IS NULL` 恒假：INSERT 写入 `DateTime.now()` 后 `query()` 永远过滤所有行。正确 `Option<DateTime>` 被 `isRelationField` 当 ref_to 阻断（meta.cj:204-206）。F4 记录准确。
- **修法**：按 F4 修法落地（isRelationField 排除可空时间戳 + nullable schema 列 + None/Some 绑定）；在此之前宏层对非 Option DateTime 的 deleted_at 直接抛宏错误而非静默生成恒假过滤。
- **✅ 已解决（2026-08-03，controller 裁决：仅宏错误守卫，F4 完整支持延后）**：`refine_macro.cj` 软删检测在 isSoftDelete 成立且 `deleted_at` 为非 Option DateTime 时抛编译期宏错误 `"soft delete field 'deleted_at' of type DateTime requires Option<DateTime> (unimplemented, see F4); use Int64 deleted_at instead"`——消除静默恒假过滤。Int64 deleted_at 路径不变。原 `DateTimeSoftDeleteEntity` fixture 与 `DateTimeSoftDeleteTest`（3 例）随守卫移除。守卫经 example 项目 probe 验证：非 Option DateTime 实体编译失败并输出明确错误；Int64 软删路径（SoftDeleteTest）全绿。Option<DateTime> 可空软删字段支持仍记 F4。

### R-I8. `Array<UInt8>`（Bytes）被误判为 ref_many —— Bytes 类型不可达
- **位置**：`src/macros/meta.cj:42-49`（detectRelations 把一切 `Array<X>` 当 ref_many）+ `meta.cj:204-206`（isRelationField）
- **问题**：`var data: Array<UInt8>` 生成 `RefMany<UInt8>` 并引用不存在的 `UInt8Schema`/`UInt8Rel` → 难懂编译错误。Bytes 是一等存储类型（meta.cj:235、sql_gen.cj BYTEA、db.cj:370 绑定）但**不可通过实体 DSL 触达**。根因与 F4 同源：关系检测未对已知标量存储类型做白名单。
- **修法**：关系检测加已知标量类型白名单（Array<UInt8> → Bytes 而非 ref_many）。补 `Array<UInt8>` 实体测试。
- **✅ 已解决（2026-08-03）**：根因核实——`vd.declType.toTokens().toString()` 对泛型渲染为 `Array < UInt8 >`（带空格），导致两条路径失效：`isRelationField` 的 `contains("Array")` 子串误中（把 Bytes 字段当关系字段跳过 → 不可达），而 `typeNameToStorageType` 的 `"Array<UInt8>"` 字面量与带空格形式失配（Bytes 分支死代码）。修复：白名单函数 `isBytesArrayType`（归一化去空格比较）在 `detectRelations`/`isRelationField`/`typeNameToStorageType` 三处统一使用——`Array<UInt8>` → Bytes 而非 ref_many，`typeNameToStorageType` 正确映射 Bytes。新增 `ByteBlobFieldTest` 5 例（schema 映射 Bytes / 列名含 data / save 绑定 Array<UInt8> / RowMapper 读回 / Array<Tag> 仍是 ref_many 回归）+ 真实 PG/MySQL 集成 `testBytesFieldRoundtrip`。

### R-I9. ref_many 目标列恒 Integer —— String-pk 目标端到端运行期类型错误
- **位置**：`src/macros/schema_gen.cj:86` + `relation_gen.cj:105,126`
- **问题**：junction 目标列硬编码 Integer，String-pk 目标时绑定 String id → 真实 DB 插入 String 进 INTEGER 列报错。已文档化（schema_gen.cj:66-69）+ schema 级测试，但失败模式是运行期 SQL 类型错误而非编译期拦截，无端到端测试。
- **修法**：宏层无法内省目标类时，对 String-pk 目标场景加文档红线或运行时预检。
- **✅ 已解决（2026-08-03，controller 裁决：运行时预检 + 文档）**：`relation_gen.cj` 的 ref_many append/delete 生成代码在 `targetIdCheck` 内追加 String-pk 守卫——目标 id 为 String 时在 `tx.execute` 之前抛明确 `RefineException("ref_many <field>: target <Target> uses String primary key but junction target column is Integer — unimplemented, see audit R-I9")`（把 DB 类型错误转成清晰 ORM 错误；Int64-pk 目标 `case _` 分支不受影响）。`RefManyStringPkTargetTest` 新增 3 例（append/delete/replace 抛 RefineException 且 `capturedSql` 为空证明未触达 DB）+ 真实 PG 集成 `testStringPkTargetAppendThrowsBeforeDb`（守卫执行前抛出，junction 表保持 0 行）。`buildJunctionSchema` 注释同步更新。Int64 目标回归由既有 I21 junction 测试覆盖。

---

## 四、Minor（Nice to Have）

- **R-M1** `keyExtractor` 是 write-only 死代码（query.cj:29,77,144；rawIdExtractor 取代后无人读）。
- **R-M2** `Query.db` 字段 write-only 死代码（query_include.cj:143-147）。
- **R-M3** `processIncluded` 是 public no-op（query_include.cj:161-163），死 API 面。
- **R-M4** `page()` 缺 "No auto-mapper" 友好守卫（query_exec.cj:38 用 raw Option 错误，all/one 有 QueryException）。
- **R-M5** Session/Tx `queryAll`/`queryOne` 两个逐字节相同的 extend 块（db.cj:312-354）。
- **R-M6** `formatAny` 缺 Int8/Int16/UInt*/Float32（log.cj:81-100）。
- **R-M7** `setIsolation` post-commit 未守卫（M19 有意为之，但调用无效果，补注释）。
- **R-M8** `Page.totalPages` `(total + size - 1)` Int64 溢出（page.cj:21）。
- **R-M9** `assembleRefMany` 重复 junction 行 → 同组同实例两次（需 DB 损坏触发，注释）。
- **R-M10** Diamond include 重复嵌套 has_many 子对象（query_batch.cj:287-292，已记档延期）。
- **R-M11** 预绑定 query + Refine.all/one 连接泄漏组合（refine.cj:131-138 + query_include.cj:149-155）。
- **R-M12** 手动 commit 后外层 commit 抛 "not active"（refine.cj:54-56；wrapper 只处理 throw-after-manual-commit 情况）。
- **R-M13** 迁移器标识符未转义，与 C9 方言层不一致（migrator_*.cj 用裸 `"`/`` ` `` 包裹）。
- **R-M14** PG `alterColumn` 忽略 `_old`，主键变更语义不完整（migrator_postgres.cj:125-139）。
- **R-M15** SQLite `defaultValueOf(Timestamp)="0"` 与 TEXT 列语义不一致（dialect_sqlite.cj:75，建议 `'1970-01-01 00:00:00'`）。
- **R-M16** MySQL 无「裸 OFFSET 哨兵 + FOR UPDATE」组合测试（dialect_base.cj:150-151）。
- **R-M17** 空 schema 生成 `CREATE TABLE IF NOT EXISTS "empty" ()`（migrator_sqlite.cj:39-49，SQLite 非法 DDL）。
- **R-M18** SQLite `getExistingIndexNames` 读到 `sqlite_autoindex_*`（migrator_sqlite.cj:178）。
- **R-M19** MySQL `VALUES(col)` 已废弃（dialect_mysql.cj:47，8.0.20 起废弃，应迁 `INSERT ... AS new`）。
- **R-M20** 审计文档状态头行与正文矛盾：状态行称 "I23 已修复"，正文与代码均为"未修复、后续排期"（2026-08-02-full-audit.md:6）。

---

## 五、修复优先级建议

```
第一优先级（发布阻塞，Critical）：
  R-C1  PG versioned upsert 非法 SQL（真实 PG 实测炸）        ✅ 已修复
  R-C2  dispatchSet 静默写 NULL（Int8/UInt8/Float32 等）       ✅ 已修复

第二优先级（Important，行为正确性）：
  R-I1  Refine.all/one 不触发 AfterFind                          ✅ 已修复
  R-I2  ref_to 缺 fk 列静默跳过                                  ✅ 已修复
  R-I3  one() 重复 LIMIT                                        ✅ 已修复
  R-I4  共享 dialect render 非线程安全                           ✅ 已修复
  R-I5  page/count 丢 GROUP BY/HAVING                            ✅ 已修复
  R-I6  I23 管理方法裸标识符（PG 驼峰）                          ✅ 已修复
  R-I7  DateTime 软删恒假过滤（宏守卫，F4 支持延后）              ✅ 已修复
  R-I8  Array<UInt8> 误判 ref_many（Bytes 不可达）               ✅ 已修复
  R-I9  ref_many String-pk 目标运行期类型错误（运行时预检）      ✅ 已修复

第三优先级（Minor）：
  R-M1 ~ R-M20（记录，择机处理）
```
