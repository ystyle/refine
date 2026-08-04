# DB 收敛重构质检报告（0.6.0 候选）

> 审查日期：2026-08-04
> 审查范围：`master (3144dc3)..HEAD` — DB 收敛为纯连接层 + DatabaseRegistry 移除（3 提交 + 交叉审查）
> 审查方式：code-reviewer 独立交叉审查（读方案 + 全 diff + 跑 `cjpm test`），再按审查发现修复
> 状态：**Ready to merge** — 2 个 Important + 3 个 Minor 已修复，930 全绿

---

## 一、总体评估

- **架构收敛彻底**：DB 不再持有 dialect/migrator/getDialect/dialectOpt，生产代码无残留引用；`using(DB)` 缺陷 API 移除干净。
- **事务语义逐行等价**：新 `runTransaction` 单核（`src/db.cj:68-104`）与旧 `Refine.transaction` 逐行对比一致——M19 状态守卫、R-M12 isActive 判断、best-effort 回滚、finally 关连接、setIsolation 在 begin 前调用。
- **Registry 移除有据**：design.md/refine-architecture.md 从未定义 DatabaseRegistry，生产/example/docs 零使用，8 个删除测试恰为 Registry 自测。
- **迁移器与宏不受影响**：迁移器自带 dialect 仅用 db.session() 跑 DDL；宏生成代码只收 Dialect 参数。
- **测试数量精确**：937 → 929（删 8 Registry 测试）→ 930（补 toDB 成功路径测试）。

## 二、Critical

无。

## 三、Important（Should Fix，已修复）

1. **docs-site/api/query.md 残留 `using(DB)` 文档**
   - 问题：API 参考页仍写"支持 Refine/Session/Tx/DB"并展示 `q.using(db)`，用户照写编译失败；guide/query.md 与 configuration.md 已同步，唯独此页漏掉。
   - 修复：删除 DB 行 + 加 0.6.0 移除说明（与 guide 一致）。

2. **`DatabaseConfig.toRefine()` 跳过 M1 `dialect.initialize(db)` 钩子**
   - 问题：`Refine.open` 构造前调 `d.initialize(db)`，`toRefine()` 直接 `Refine(toDB(), d)` 不调。当前三方言 initialize 为空实现，无功能影响；但 `toRefine()` 已被提为文档钦定的 ORM 入口，方言初始化实现后会与 `Refine.open` 静默行为分叉。
   - 修复：`toRefine()` 改 `let d = detectDialect(driver); let db = toDB(); d.initialize(db); Refine(db, d)`。

## 四、Minor（Nice to Have，已修复）

1. **DB 连接池 props 是死字段**（db.cj 旧 23-30）：`maxPoolSize/connectionTimeout/idleTimeout/maxLifeTime` 从未应用到 `DB.open` 创建的 PooledDatasource，而 docs 把它们当功能宣传（`db.maxPoolSize = 20` 实际不生效）。修复：**移除 4 个死 props**——纯连接层不负责池配置，统一走 DatabaseConfig.applyPoolConfig；同步修正 configuration.md DB 连接池段。
2. **DB.getRawConn() 注释与可见性不符**：标注"内部用"却是 public。修复：改 `internal`（裸连接通道包内/Refine 层用），Refine.getRawConn() 保留 public。
3. **toDB() 成功路径无直测**：`testDatabaseConfigToDB` 只测 driver 不存在的错误路径。修复：新增 `testConfigToDBSuccessReturnsPureDB`（mariadb→paramOffset=1、裸 session.getDialect() 抛 RefineException、连接正常关闭）。

## 五、Recommendation（记档，未实施）

- **`Refine.over(db: DB, dialect: Dialect)` 类入口**：当前 `Refine.init(db, dialect)` 是 internal，用户拿到 `DB.open(url)` 无法升级为 ORM 实例（只能重新 `Refine.open` 或走 DatabaseConfig，都新建独立池）。补此入口可让"DB 连接层 + Refine ORM 层"拼接完整，也让 `Refine.open` 拿到池参数配置。待后续版本评估。
- **文档提示 toDB()/toRefine() 各自打开独立池**，避免误以为共享底层连接。

## 六、测试基线

`cjpm test`：**TOTAL: 930, PASSED: 930, FAILED: 0**（独立复核）。
