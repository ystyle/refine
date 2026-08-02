# Refine ORM 全库代码质量审查报告

> 审查日期：2026-08-02
> 审查范围：全部 `src/` 运行时 + `src/macros/` 宏层 + 三方言 + 三迁移器
> 审查方式：三路并行深度审查（核心运行时 / 方言+迁移 / 宏生成层），逐行核对 + 交叉验证
> 状态：**Not ready for release** — 存在 9 个 Critical + 19 个 Important，修复后需补测试沉淀。下一项排期：**I19** 宏写路径未引号标识符（由 I2 修复暴露，2026-08-02）

---

## 一、总体评估

### Strengths（做得好的地方）

1. **表达式树设计干净**：`Expr`/`BinOp`/`UnaryOp` 独立变体 + 手动 `Equatable`，`Binary` 命名规避仓颉同名约束（`expr.cj:3-58`）；`and()/or()/not()` 弥补 `&&`/`||` 不可重载缺陷。
2. **`Col<T>` 泛型操作符设计是核心亮点**：`==(rhs: T)` vs `==(rhs: Col<T>)` 重载区分字面量与列间比较，编译期类型安全（`col.cj:10-18`）；`anyOf/notAnyOf` 对空数组返回恒真/恒假避免空 IN 语法错误。
3. **级联环检测双轨**：save/update 用对象引用 refEq、delete 用 `(type,id)` 键，正确解决 DB 常驻自引用环（`relation_gen.cj:211-230`）；注释区分 load-bearing 与 defense-in-depth 到位。
4. **修改标记一次性语义**：`_XxxModified` 显式赋值才同步一次，Query 装配写 backing 不置标记，避免"加载即触发级联"经典 bug。
5. **PostgreSQL `$n` 参数编号**：UpdateClause 先于 WhereClause 入数组保证编号连续不错位（`dialect_postgres.cj:17,59,96-100`）。
6. **MariaDB 1-based 偏移贯通链路**：`paramOffset=1` 从 `Refine.open` → Session/Tx 绑定 → `buildColumnMap` 全链路一致（`refine.cj:34`、`db.cj:109,117`、`mapper.cj:13`）。
7. **ref_many 六件套空 id 保护**：`targetIdCheck` 拒绝未保存的幽灵对象写入中间表（`relation_gen.cj:88-96`）。
8. **SQLiteMigrator 严格只加不改**（`migrator_sqlite.cj:64-77`），`alterColumn` 明确抛异常拒绝。
9. **FOR UPDATE 渲染正确**：mysql/pg 追加在 LIMIT/OFFSET 后，SQLite 正确忽略。
10. **软删/物理删双轨**：`@HardDelete` 注解 + `deleted_at` 字段检测，宏自动生成过滤与两套 API。
11. **join 子句插入位置正确**（`statement.cj:27-38`）：插到首个 WHERE/GROUP/HAVING/ORDER/LIMIT 之前。

---

## 二、Critical（Must Fix）

### C1. `all()` 静默吞掉映射/hook 异常 → 数据残缺返回
- **位置**：`query.cj:371-383`
- **问题**：`try { ... } catch (_: Exception) { () }` 吞掉 mapper 抛出的任何异常（SQL 类型转换、列缺失、AfterFind hook 错误），该行被静默丢弃。查询"成功"返回但缺行，无任何告警。
- **为什么重要**：ORM 最危险的行为——业务数据被悄悄截断。
- **修法**：让异常向上传播（删除 catch），或至少记录日志并标记结果不完整。

### C2. include 预加载装配必然丢行/漏字段（核心功能实际不可用）
- **位置**：`query.cj:323-335` + `method_gen.cj:44-48` + `method_gen.cj:208-214`
- **问题**：`wrapMapper` 调 `targetMapper`（完整 `UserRowMapper`），它读取 target 所有非关系字段；`stripPrefix` 后只剩 include 的 fields 子集（默认 `["id"]`），`columnMap.get("email").getOrThrow()` 必抛 → 被 C1 吞掉 → **ref_to/has_one 路径整行丢失**。has_many/ref_many 集合路径（`aggregateWithCollections`）无 try/catch → **直接抛异常**。
- **修法**：装配必须基于 include 的 fields 子集生成轻量 mapper，而非复用完整 RowMapper。

### C3. 静态 `Entity.save/update/delete` 不落库，只跑 hook —— API 信任事故
- **位置**：`method_gen.cj:104-144`
- **问题**：名为 `save/update/delete` 的静态方法**不执行任何 SQL**，且调用全局 `hookRegistry` 而非实例级注册表。用户按直觉调用 `Post.save(post)` 以为持久化了，实际零落库、零报错。
- **为什么重要**：与 `Tx.save`（真落库）形成强烈对比，灾难性的静默失败 API。
- **修法**：要么让静态方法真正持久化（需要 db 上下文），要么重命名（如 `runHooks`）并文档红线；绝不能以 `save` 命名却不保存。

### C4. `page()` 与 hasMany include 组合返回重复父实体 + total 计数错误
- **位置**：`query.cj:107-132` + `query.cj:445-467`
- **问题**：`all()/one()` 对集合 include 走 `aggregateWithCollections` 按主键去重，但 `page()` 逐行映射——hasMany 展开的每行都生成一个父实体；同时 `countWith` 拷贝 JoinClause，`COUNT(*)` 在 JOIN 后对每行计数，total 被放大。
- **修法**：`page()` 走与 `all()` 相同的集合去重路径；`countWith` 对含集合 include 应用 `COUNT(DISTINCT 主键)` 或子查询计数。

### C5. PostgreSQL 子查询参数 `$n` 编号冲突（跨库不一致）
- **位置**：`dialect_postgres.cj:112-115`
- **问题**：`case SubQuery(s) => render(s)` 递归调用重置 `paramIdx=1`，子查询内部从 `$1` 重新编号。外层已有参数时 SQL 出现两个 `$1` 对应不同值——PostgreSQL 报错或错误绑定。MySQL/SQLite 用 `?` 不受影响。
- **现有测试**：dialect_postgres_test.cj:268-281 的子查询不含参数，未覆盖此路径。
- **修法**：`render` 增加起始编号参数，子查询按 `base+1` 平移。

### C6. MySQLMigrator 结果列索引硬编码 1-based，真实 MySQL 下完全错位
- **位置**：`migrator_mysql.cj:36,93-96,120`
- **问题**：`get<Int64>(1)` / `get<String>(1..4)` 硬编码 1-based。标准驱动 `get()` 是 0-based，仅 `mariadb` 走 `paramOffset=1`；`detectDialect` 把 `"mysql"` 也映射到 MySQLDialect，真实 MySQL 连接下整行错位。
- **现有测试**：集成测试只连 MariaDB（mysql_integration_test.cj:13 `"mariadb://"`），MySQL 驱动路径从未验证。
- **修法**：迁移器内走 0-based 索引，或统一用 `columnOffset`（与 query 层一致）。

### C7. DB 类完全不感知方言，自动迁移会向 MySQL/PG 发 SQLite DDL
- **位置**：`db.cj:48-50`（getDialect 硬编码 SQLite）、`db.cj:277-281`（DB.migrator 硬编码 SQLiteMigrator）、`config.cj:21-34`（DatabaseConfig.toDB 走此路径）
- **问题**：`DB.open("mysql://...")` / `DatabaseConfig.toDB()` 全走 SQLite 渲染——标识符用 `"` 引用、无 FOR UPDATE、autoMigrate 生成 SQLite DDL 打在 MySQL/PG 上。**静默错误**，用户无任何报错。且 `Tx.upsert` 的 `this.ref.getOrThrow()` 在 DB 路径必崩。
- **修法**：废弃 DB 独立路径统一走 Refine，或 DB 注入 dialect。

### C8. autoMigrate 违反"只加不减不改类型"契约（PG/MySQL）+ 反向映射有损引发迁移翻烙饼
- **位置**：`migrator_postgres.cj:85-89`、`migrator_mysql.cj:75-79`；反向映射 `migrator_mysql.cj:103-114`、`migrator_postgres.cj:112-124`
- **问题**：PG/MySQL 在 storageType/nullable 不同时自动 `alterColumn`，违反设计 §11.3"修改列类型 ❌ 不操作"。且反向映射有损：`"decimal"` → `Float`、`"tinyint"` → `Integer`（Bool 列 TINYINT(1) 读回 Integer）→ **每轮迁移必产生假 diff 并翻转列类型**，有数据截断/锁表风险。SQLite 版本只加列（符合设计），三方言行为不一致。
- **修法**：`decimal/numeric → StorageType.Decimal`，tinyint 依据 COLUMN_TYPE 判断 Bool；autoMigrate 统一恢复纯只加语义。

### C9. 标识符通道未封闭（SQL 注入风险）
- **位置**：`dialect_sqlite.cj:10-12`、`dialect_mysql.cj:10-12`、`dialect_postgres.cj:11-13`
- **问题**：`quoteIdentifier` 用 `"`+name+`"` 直接拼接不转义嵌入引号。`updateWhere(setCols)` 与 `from(table)` 的标识符来自 API 参数，含引号可逃逸构造任意 SQL。值参数化做得好但标识符通道未封闭。
- **修法**：转义标识符内引号（`"` → `""`）。

---

## 三、Important（Should Fix）

### I1. include 后 ORDER BY/GROUP BY/HAVING 未做表名限定 → 歧义报错
- **位置**：`query.cj:302-312`
- **问题**：`processIncluded` 只对 WhereClause 调 `qualifyExpr`，OrderBy/GroupBy/Having 被遗漏。include 后 join 表通常也有 id 列，`ORDER BY "id"` 在三方言都报 ambiguous。
- **修法**：对 OrderBy/GroupBy/Having 同样递归 qualifyExpr。

### I2. PostgreSQL `quoteIdentifier` 强制小写 → 驼峰字段映射失败 + include 别名错位
- **位置**：`dialect_postgres.cj:11-13`
- **问题**：`name.toAsciiLower()` 使 SELECT 生成 `"authorid"`，而宏 mapper 用 `columnMap.get("authorId")`（驼峰）查找 → 抛错 → 被 C1 吞 → PG 上所有驼峰字段查询丢行。include 的列别名也被小写，`stripPrefix` 按原大小写匹配 → 驼峰字段/关系名在 PG 上静默映射为 null。MySQL/SQLite 保留原样，方言间不一致。
- **修法**：PG 方言不强制小写；标识符一律原样引号包裹。

### I3. MySQL 裸 OFFSET 渲染出非法 SQL
- **位置**：`dialect_mysql.cj:50-51`
- **问题**：`SELECT ... OFFSET n` 无 LIMIT 在 MySQL 是语法错误（必须 `LIMIT 18446744073709551615 OFFSET n`）。`.offset(n)` 不带 `.limit()` 即触发。
- **修法**：MySQL 方言检测到只有 OFFSET 时补发 LIMIT 哨兵。

### I4. UPDATE/DELETE 渲染路径静默丢弃 JOIN（及其参数）
- **位置**：`dialect_sqlite.cj:67-73`、`dialect_mysql.cj:68-74`、`dialect_postgres.cj:72-78`
- **问题**：update/delete 分支只追加 updateSQL/deleteSQL + whereClause，joins/orderBy/limit/lock 全部丢弃。`deleteWhere`/`updateWhere` 明确复制了 JoinClause——用户期望 `DELETE ... JOIN` 却被静默退化成无 JOIN 删除，删错行。更糟：被丢弃 JOIN 的 ON 参数仍加入 params 数组，PG 上 WHERE 的 `$n` 与绑定值错位。
- **修法**：按方言实现 DELETE/UPDATE+JOIN，或在构建器层直接拒绝 join。

### I5. SQLite 对已存在数据的表加 NOT NULL 列必失败
- **位置**：`migrator_sqlite.cj:37-39` + `autoMigrate:70`
- **问题**：`ALTER TABLE ADD COLUMN "x" TEXT NOT NULL`（无 DEFAULT）在非空表上报错。设计 §11.3 明确"已有行使用 DEFAULT 或 NULL"，但 `defaultValueOf` 是死方法返回空串。
- **修法**：SQLite addColumn 对 NOT NULL 列自动补 DEFAULT，或先加可空列再回填。

### I6. Session 无 try/finally，异常时泄漏连接
- **位置**：所有迁移器方法（如 `migrator_sqlite.cj:53-58`）、`migrator_mysql.cj:57-63`、`migrator_postgres.cj:60-66`
- **问题**：`let s = db.session(); ...; s.close()` 模式，`query/execute` 抛异常时 `s.close()` 不执行，池化连接泄漏。全库通用模式。
- **修法**：统一 `try ... finally { s.close() }`。

### I7. `isNullId` 依赖驱动边界行为，脆弱且注释与实现不符
- **位置**：`query.cj:550-557`
- **问题**：`try { result.get<String>(idx); false } catch { true }` 用 get<String> 读 Int64 主键列判断 NULL，依赖 std 驱动对 NULL 的异常行为，跨驱动未验证；`query.cj:592` 还用 `get<String>` 读 Int64 id。测试注释写 get<Int64>、实现是 get<String>。
- **修法**：用 `getOrNull<T>` 判空，并补真实行为测试。

### I8. `include(rel, fields)` 双参重载装配不完整（只填 id）
- **位置**：`query.cj:213-216` vs `relation.cj:61-64`
- **问题**：双参重载只加入 `FieldOverrideRelation` 不调 `wrapMapper`，装配走 base mapper 前缀检查只读取 `fieldName.id`——fields 覆盖完全失效。链式 `include(rel.setFields([...]))` 单参路径则正常。同一意图两条路径行为不一致。
- **修法**：双参重载同样包 wrapMapper。

### I9. Refine.all/one 修改 Query 内部状态 + 双重关闭 session
- **位置**：`refine.cj:113-129`
- **问题**：`query.queryDialect = dialect` 等直接写传入的 Query（并发/复用竞态）；`all()` 内部 `closeExecutor` 已关闭 session，`refine.cj:118` 的 `s.close()` 是第二次关闭；异常路径 session 可能不关闭。
- **修法**：Query 改为 copy-on-write 或局部状态；session 关闭集中 finally。

### I10. 文档与实现脱节，破坏 AI 友好核心目标
- **位置**：design.md 3.2.1 / 4.3.2 / 4.1 vs `meta.cj:23-52`、`method_gen.cj:78-98`、`attr_macros.cj`
- **问题**：(a) 文档示例用 `Option<List<Post>>`，实现只识别 `Option</ArrayList</Array<`；(b) 文档声称"拼错字段 → 编译报错"，实现是 `Col<Any>("authorId")` 字符串拼接零校验；(c) `fields()` 方法文档 vs 实际 `setFields()`。
- **修法**：同步文档与实现；`Col<Any>` 改为宏校验字段存在性。

### I11. hasMany `addX` 对已存在对象用 save 会主键冲突，has_one setX 无替换语义
- **位置**：`relation_gen.cj:156-158,187-189`
- **问题**：`addPost` 无条件 `tx.save(child)`：子对象已有 id 时 INSERT 重复主键报错；`removePost` 却检查 `entity.id != 0` 才删，语义不对称。`setProfile` 只 save 不清理旧 profile，唯一约束下必冲突。
- **修法**：add/set 按子对象 id 区分 save/update，has_one set 先解除旧关联。

### I12. `aggregateWithCollections` 破坏结果顺序
- **位置**：`query.cj:604-608`
- **问题**：`for ((_, entity) in map.toArray())` 依 HashMap 迭代序返回，ORDER BY/LIMIT/OFFSET 语义失效。
- **修法**：维护插入序（LinkedHashMap 或序号键）。

### I13. `exists()` 全表 count
- **位置**：`query.cj:469-471`
- **问题**：`exists() = count() > 0` 对超大表全量 COUNT。
- **修法**：改 `SELECT 1 ... LIMIT 1`。

### I14. Hook 系统双注册表混乱
- **位置**：`hook.cj:80`（全局）vs `refine.cj:12`（实例级）
- **问题**：全局 registry 与实例 registry 并存；宏生成代码两套调用（Tx 走实例级、静态方法走全局）；`BeforeSave/AfterSave` 标注"保留"但无实现；AfterFind hook 的错误返回值被忽略（`query.cj:376,427,574`）。
- **修法**：统一为实例级；AfterFind 的 error 至少记录。

### I15. SQLite 特性检测过于保守
- **位置**：`dialect_sqlite.cj:160,178,180`
- **问题**：`hasUpsertSupport/hasReturningSupport/hasJSONSupport` 全 false。SQLite ≥3.24 支持 ON CONFLICT、≥3.35 支持 RETURNING。用户 `tx.upsert()` 直接抛"not supported"。
- **修法**：按 SQLite 版本启用能力。

### I16. Between/In 操作符无法表达合法 SQL
- **位置**：`dialect_sqlite.cj:143`（renderOp）
- **问题**：`Expr.Binary` 只有两个操作数，`Binary(a, Between, b)` 渲染 `a BETWEEN b` 缺 AND high；`In` 同理表达不了 `IN (1,2,3)`。潜伏的坏功能。
- **修法**：新增 Range/ValueList 变体，或明确禁止这两个操作符。

### I17. DatabaseConfig 连接池配置全是死参数
- **位置**：`config.cj:12-17,29-30`
- **问题**：`maxPoolSize/maxIdleSize/connectionTimeout` 等在 `toDB()` 中从未生效，用户设置了却静默无效。
- **修法**：接线到数据源或移除。

### I18. upsertSQL 与宏强耦合
- **位置**：`tx_gen.cj:170-174` vs `dialect_mysql.cj:163-182`
- **问题**：upsertSQL 只返回 SQL 不告知额外参数个数，macro 层按方言名字符串特判给 mysql 补 auditUpdate 参数——脆弱。
- **修法**：返回 (sql, extraParamCount) 或统一协议。

### I19. 宏层写路径标识符未加引号 → PG 驼峰实体可读不可写
- **位置**：`src/macros/sql_gen.cj:37,221,300,312,319,323`（buildInsertSQLString/buildUpdateSQLString/buildDeleteSQLString/buildSoftDeleteSQLString/buildBatchInsertSQLFunc/buildBatchUpdateSQLFunc）
- **问题**：写路径 SQL 的表名/列名未引号包裹，PG 未加引号标识符折叠小写，与 I2 修复后保留大小写的建表/读路径不一致 → tx.save/update/delete 无法命中驼峰表/列。
- **修法**：宏写路径改为方言感知的引号包裹（与读路径 quoteIdentifier、upsert 一致）。
- **备注**：由 I2 修复暴露（2026-08-02），列为下一项排期任务。

### I20. save 的 RETURNING 自增主键列未引号化 → PG 驼峰主键列 save 失败
- **位置**：`src/macros/tx_gen.cj:66`（`" RETURNING " + $(returningColsLit)`）+ `buildAutoPkReturningCols`（`src/macros/sql_gen.cj:347-351`）
- **问题**：I19 后写路径表名/列名均已引号化，但 save 的自增主键回填（PG `hasReturningSupport` 分支）仍在 INSERT 后追加 `RETURNING <pk.name>`，`buildAutoPkReturningCols` 返回裸主键列名。PG 下驼峰自增主键列（如 `PostId`）折叠小写 → RETURNING 找不到列，save 直接失败。
- **修法**：RETURNING 列同样经 `dialect.quoteIdentifier` 引号化（与写路径一致）。
- **备注**：由 I19 修复暴露（2026-08-02），I19 范围外遗留，列为下一项排期任务。

### I21. ref_many 中间表标识符未引号化 → PG 驼峰 via/junction 列读写失败
- **位置**：`src/macros/relation_gen.cj:46,77,80,83,86`（load 的 JOIN / append 的 INSERT / delete / clear / count SQL）
- **问题**：ref_many 相关 SQL 仍把裸 via 表名与 junction 列名（`<via>`、`lowerTableName(target)_id`、`<source>_id`）烘焙进编译期字符串。I19 只覆盖主实体写路径，驼峰 via 表（自定义 `via:` 名）或驼峰 junction 列在 PG 上折叠小写 → append/replace/delete/clear/load/count 无法命中中间表。
- **修法**：junction 相关 SQL 改为运行时 `dialect.quoteIdentifier`（与 I19 写路径一致）。
- **备注**：由 I19 修复暴露（2026-08-02），I19 范围外遗留，列为下一项排期任务。

---

## 四、Minor（Nice to Have）

- **M1** `Refine.open` 未调用 `dialect.initialize(db)`（`refine.cj:25-36`；接口空实现 `dialect.cj:18`）。
- **M2** `visitedContains/visitedKeyContains` 是 public 顶层函数，泄漏内部实现（`refine.cj:165-177`）。
- **M3** `idgen.cj:40-45` Sonyflake machineId 随机化 → 多进程共库时 ID 冲突风险。
- **M4** `col.cj:24,32` 空数组返回 `Raw("1 = 0")` 硬编码字符串。
- **M5** `db.cj:207-210` `setIsolation` 错误信息硬编码 "SQLite does not support"。
- **M6** `log.cj:79-87` `formatAny` 对 DateTime/Array 输出 `<unknown>`。
- **M7** `page.cj:16-19` `totalPages()` 在 `size=0` 时除零。
- **M8** `query.cj:495` 聚合列名 `Raw(fn + "(" + colName + ")")` 拼字符串；`min/max` 缺 String 版本。
- **M9** `dialect_sqlite.cj:174` Timestamp→TEXT，软删除过滤硬编码 `deleted_at = 0`（`refine_macro.cj:99`），若 deleted_at 声明为 DateTime 会永远查不到。
- **M10** `error.cj:45-65` `OptimisticLockException` 两个 pk 重载（Int64/String）易混淆。
- **M11** `dispatchSet1`（`db.cj:296-299`）从未被调用。
- **M12** `runQuery`（`query.cj:184-198`）是死代码。
- **M13** `migrator_sqlite.cj:61` alterColumn 抛裸 `Exception`，应抛 RefineException。
- **M14** MySQL/PG upsert 把主键列写进 DO UPDATE SET（噪音）。
- **M15** MySQL `getExistingIndexNames` 复合索引名重复出现，且混入 PRIMARY。
- **M16** `DatabaseRegistry` 静态全局状态与"多实例隔离"相悖，无并发保护。
- **M17** `dummyMapper/dummySetter`（`relation.cj:147-148`）是测试泄漏到生产。
- **M18** 三方言约 150 行逐字节重复代码（render 主循环、renderExpr 系列），应抽取共享基类。
- **M19** `Tx` 无"已提交/已回滚"状态，commit 后仍可 execute（无防护）。
- **M20** `Query<T>` 过度膨胀（构建/执行/聚合/DML/分页/include 全在一个类），`db/ref/queryDialect/columnOffset/keyExtractor` 混存多种绑定态。
- **M21** `Refine.migrator()` 内 `DB(datasource)` 与 `DB(datasource, paramOffset)` 双分支笨拙（`refine.cj:131-139`）。
- **M22** `meta.cj:228-238` `typeNameToStorageType` 把未知 struct 一律映射为 Text 而非 design 的 Json——自定义类型适配未真正接线到宏。
- **M23** `db.cj:296-299` dispatchSet1 死代码（与 M11 重复，保留一个）。
- **M24** junction schema 无联合主键（post_tags 的 (src_id,tgt_id) 应为主键）。

---

## 五、遗留 Follow-up（此前 todo 未完成项）

> 以下三项来自第三批级联保存的 follow-up 清单，确认均未完成，一并纳入。

### F1. String-pk ref_many 的 junction schema 硬编码 `StorageType.Integer`
- **位置**：`schema_gen.cj:76-77`
- **问题**：`buildJunctionSchema` 硬编码 `StorageType.Integer`。当 ref_many 目标主键为 String 时，DDL 类型不匹配（VARCHAR 列建表成 INTEGER）。
- **修法**：需宏层获取目标主键类型（跨类内省），或退化为运行时约束 + 文档说明。

### F2. cascadeDelete 无 pk 死代码分支 + 复合 pk 键测试 + visited O(n) 优化
- **位置**：`relation_gen.cj:214`（`if (pkFields.size == 0)` 分支）
- **问题**：(a) `buildCascadeKeyTokens` 的 `pkFields.size == 0` 死代码分支——无 pk 的实体能否级联删除未验证；(b) 复合 pk 的 `cascadeDelete` 键（`<Class>:<pk1>:<pk2>`）无专门测试（现有 `testTxUpdateVersionedOrderTagConflictCompositePk` 是乐观锁复合 pk，非级联删除）；(c) `visitedContains/visitedKeyContains` 是 O(n) 线性扫描，深链/大集合时退化为 O(n²)。
- **修法**：补复合 pk 级联删除测试；评估 visited 改 HashSet。

### F3. 非事务级联原子性 + 物理删父软删子孤儿 + Task6 minor 加固
- **位置**：`docs/plans/2026-08-01-cascade-save-design.md`
- **问题**：(a) 非事务场景下级联保存/删除不具备原子性（中途失败部分落库），文档未说明；(b) 物理删除父实体时，若子实体是软删模型，`cascadeDelete` 走 `tx.deleteCascade`（软删）而父走 `physicalDelete`，导致孤儿——策略继承未文档化/验证；(c) Task6 部分边界测试断言偏弱（如 `@Expect(true, true)` 空占位）。
- **修法**：文档明确"级联操作应在事务中使用"；物理删父对软删子的策略补说明与测试；加固 Task6 断言。

---

## 六、修复优先级建议

```
第一优先级（数据完整性）：
  C1  all() 吞异常
  C2  include 装配丢行/漏字段
  C3  静态 save 不落库
  C8  autoMigrate 违约 + 反向映射有损

第二优先级（跨库正确性）：
  C4  page + include 重复/计数错
  C5  PG 子查询 $n 冲突
  C6  MySQLMigrator 1-based
  C7  DB 方言硬编码
  C9  标识符注入

第三优先级（功能/一致性）：
  C 系列完成后 → I1~I19 按影响排序
  → F1~F3 follow-up
  → M1~M24 minor
```

**测试要求**（AGENTS.md 约定）：每个 Critical 修复必须沉淀回归测试；C5/C6 建议补带参子查询与真实 MySQL 驱动测试。

---

## 七、接口设计专项评估（摘要）

| 公开接口 | 评估 | 说明 |
|---|---|---|
| `Refine` | ⚠️ 合理但有残留 | 统一入口方向正确；all/one 直接改写 Query 状态；migrator() 双分支笨拙 |
| `DB` | ❌ 设计残留 | 与 Refine 重复、方言硬编码错误、应移除或废弃 |
| `Session`/`Tx` | ✅ 基本合理 | 职责清晰；Tx 无已提交状态防护 |
| `Dialect` | ⚠️ 方法过宽 | render 承载全渲染、三方言 90% 重复；initialize/upsertSQL/defaultValueOf 空转 |
| `Migrator` | ⚠️ 抽象对，实现违约 | PG/MySQL autoMigrate 违约改列 |
| `Query<T>` | ⚠️ 过度膨胀 | 一个类承载构建/执行/聚合/DML/分页/include |
| `Page<T>` | ✅ 合理 | 不可变 struct |
| `IRelation` 族 | ⚠️ 抽象好，实现绕 | 四子类逐字重复、与宏耦合过深 |
| `Expr`/`Col<T>` | ✅ 优秀 | 核心亮点 |
| `StorageType`/`TypeAdapter` | ✅ 合理 | 宏层自定义类型未真正接线 |
| Hook 系统 | ❌ 双注册表混乱 | 全局 + 实例并存、静态方法走全局 |
| 宏生成 API | ❌ 命名欺骗 | 静态 save/update/delete 不落库 |
