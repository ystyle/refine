# Batch Include（分步查询预加载）实现计划 — 激进版

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

> **✅ 状态：已全部完成（2026-08-02 → 08-03）。** Task 1-10 全部落地，测试全绿（781 用例，含真实 MySQL/PG 集成）。
> 最终实现详见提交历史 `e4dfacb..1083106`（Task 1-9）+ 本 commit（Task 10 文档）。

**Goal:** 将 include 预加载从单查询 LEFT JOIN 方案彻底重构为分步查询（batch include），移除 JOIN 模式，新增嵌套 include 与字符串路径 DSL。

**Architecture:** batch include 成为唯一实现。`all()/one()/page()` 先查主实体，再按目标表批量执行 N+1 次查询（ref_to 按外键 IN、has_many 按主键 IN、ref_many 走 junction JOIN），按 id 建 HashMap 查找表装配关联。删除全部 LEFT JOIN 生成/装配代码（`processIncluded` 的 JOIN 分支、`wrapMapper`、`aggregateWithCollections`、`stripPrefix`、`qualifyExpr` 等）。嵌套 include 通过 `withInclude()` 链式 + 字符串点号路径（`includeAll(["author.profile"])`）双 API 支持，运行时递归装配。

**Tech Stack:** 仓颉语言、refine ORM（Expr/Statement/Dialect 渲染、宏生成 RowMapper/Rel 描述符）

---

## 背景

- 概念设计：`docs/plans/2026-06-05-batch-include-design.md`
- 当前实现：LEFT JOIN 单查询 + `aggregateWithCollections` 内存去重（query.cj）
- **激进决策（用户确认）**：项目 <3 个月、无用户 → 直接移除 JOIN 模式，batch include 唯一实现，不做开关/降级。

## 关键设计决策

### D1: 移除 JOIN 模式
删除 query.cj 中所有 LEFT JOIN 生成与装配代码：
- `processIncluded`（JOIN 分支 + 别名 SELECT + qualifyExprs）
- `wrapMapper` / `wrapNonCollection`（ref_to/has_one 单行 JOIN 装配）
- `aggregateWithCollections` / `hasCollectionInclude` / `stripPrefix` / `isNullId` / `qualifyExpr` / `qualifyExprs`
- `countWith` 的 `COUNT(DISTINCT)` 分支（batch 模式主查询无 JOIN，COUNT(*) 天然正确）
- `rejectJoin` + updateWhere/deleteWhere 的 JOIN 拒绝（不再有 JOIN 来源，但保留作为防御——见 Task 4）

### D2: IRelation 扩展（嵌套 + 查找）
```cangjie
public interface IRelation {
    // 新增（默认实现）：嵌套 include
    func withInclude(rel: IRelation): IRelation { ... }   // 默认返回 this 或抛错？
    // 新增：批量查询支持标记（默认 true）
    func isBatchSupported(): Bool { true }
}
```
- `withInclude` 的默认实现：无嵌套能力的关系返回 this（no-op）。具体子类（Relation<TTarget>）持有一个 `nested: ArrayList<IRelation>`。
- 宏层在 Relation 类上生成嵌套能力（4 个子类共享 Relation 基类即可）。

### D3: 字符串路径 DSL（宏生成 forName）
- 宏为每个实体生成 `XxxRel.forName(name: String): Option<IRelation>`，解析单字段名（不含点号，只解析第一段）。
- `Query.includeAll(paths: Array<String>)`：对每个路径，按点号分段，逐级 `forName` + `withInclude` 组装嵌套，最终加入 included。
- parser 错误：路径字段不存在 → 编译期无法拦截（字符串），运行时抛 QueryException 带清晰信息。

### D4: 分步查询协议
1. **查主实体**：渲染不含 include 的主查询（FROM/WHERE/GROUP/HAVING/ORDER/LIMIT/OFFSET），主 mapper 映射。
2. **按目标表分组**：遍历 included，按 `resolve().targetTable` 分 4 类（ref_to/has_one/has_many/ref_many）。
3. **批量 ref_to**：收集主实体每 rel 的外键（非 NULL）去重 → `SELECT 目标表 WHERE id IN (...)` → HashMap 装配。
4. **批量 has_one/has_many**：收集主实体 id → `SELECT 目标表 WHERE fk IN (...)` → 分组装配。
5. **批量 ref_many**：收集主实体 id → junction JOIN + 目标表 IN → 按 source_id 装配。
6. **嵌套递归**：批量查出的目标实体若有 `withInclude` 嵌套声明，递归对其执行分步装配（复用同一套批量逻辑，作用于目标实体数组）。

### D5: 空集合跳过
外键/主键集合为空跳过该批量查询（避免 `IN ()`）。

### D6: 主键类型与复合主键
- 批量查询的 IN 主键用现有 `keyExtractor` 思路；首版支持单列 id + 复合主键的 has_many 外键 IN（用现有 ColumnDef 信息）。
- 嵌套的批量装配对复合主键目标：用连接键字符串。

## Task 结构

### Task 1: IRelation 嵌套能力 + Query 基础
**Files:** Modify `src/relation.cj`, `src/query.cj`, `src/query_test.cj`

- `IRelation` 加 `withInclude(rel): IRelation { this }` 默认 + `isBatchSupported(): Bool { true }` 默认
- `Relation<TTarget>` 加 `private var nested = ArrayList<IRelation>()` + `override withInclude` 追加 + `getNested(): Array<IRelation>`
- 编译验证 + 提交

### Task 2: 主查询分离（删除 processIncluded JOIN 分支）
**Files:** Modify `src/query.cj`, `src/query_test.cj`

- `processIncluded` 改为 no-op（或删除，调用点直接删）
- 删除 qualifyExprs/qualifyExpr/stripPrefix/别名 SELECT 逻辑
- 主查询渲染不再含 include JOIN
- 测试：开启 include 后主查询 SQL 无 JOIN；ref_to 主实体暂不装配（后续 Task 补）

### Task 3: 批量 ref_to 装配
**Files:** Modify `src/query.cj`, `src/query_test.cj`

- 主查询后，遍历 included 的 ref_to，按目标表分组批量 IN 查询 + HashMap 装配
- 删除 wrapMapper/wrapNonCollection
- 测试：2 实体各 ref_to，mock 二次查询装配正确；同表多 ref 合并一次查询

### Task 4: 批量 has_many + has_one
**Files:** Modify `src/query.cj`, `src/query_test.cj`

- 按 fk IN 主键集合批量查询 + 分组装配（has_many 整组 / has_one 取一）
- 删除 aggregateWithCollections/hasCollectionInclude/isNullId
- 删除 countWith 的 DISTINCT 分支
- 测试：has_many 装配、has_one 装配、空关联、page 组合

### Task 5: 批量 ref_many（junction）
**Files:** Modify `src/query.cj`, `src/query_test.cj`

- junction JOIN 批量查询 + 按 source_id 装配
- 测试：ref_many 装配、空 junction

### Task 6: 嵌套 include 递归
**Files:** Modify `src/query.cj`, `src/query_test.cj`

- 批量装配目标实体后，若有嵌套声明，对目标实体数组递归执行分步装配
- 递归的批量装配是泛型复用（对 Array<Any> 目标 + 其嵌套关系）
- 测试：author.profile 两级、tags 嵌套、混合

### Task 7: 字符串 DSL（宏生成 forName + Query.includeAll）
**Files:** Modify `src/macros/method_gen.cj`, `src/macros/refine_macro.cj`, `src/query.cj`, `src/macro_test.cj`

- 宏为每个实体 Rel 类生成 `static func forName(name: String): Option<IRelation>`（match 全部关系字段名）
- `Query.includeAll(paths: Array<String>)`：点号分段 + forName + withInclude 组装
- 测试：includeAll 单层/嵌套/路径不存在抛错/与 withInclude 等价

### Task 8: 清理 updateWhere/deleteWhere JOIN 防御
**Files:** Modify `src/query.cj`, `src/query_test.cj`

- rejectJoin 保留（防御：用户仍可能手动加 JoinClause 到 stmt？检查 Statement 是否暴露 addJoinClause 给用户）
- 若 JOIN 已无来源，删除 rejectJoin + 相关测试；否则保留并更新注释
- 更新 updateWhere/deleteWhere 的 JOIN 拷贝分支

### Task 9: 集成测试（真实 MySQL/PG + mock）
**Files:** Test `src/macro_test.cj`, `example/src/service_test.cj`

- 多 has_many + ref_to 混合 include 无笛卡尔积（结果行数 = 主实体数）
- 同表多 ref 合并 1 次批量查询（断言查询次数）
- page + include、空关联、嵌套、includeAll
- 真实 MySQL/PG 端到端

### Task 10: 文档
**Files:** Modify `docs/design.md`, `docs-site/`

- include 文档全面重写：batch 唯一模式、withInclude 嵌套、includeAll 字符串 DSL、能力对比（查询次数、无笛卡尔积、嵌套支持）
- 更新设计文档 2026-06-05（标注已被本计划取代）

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| N+1 查询次数增多 | 按目标表合并；批量 IN |
| 大 IN 列表 | 分块 IN（后续优化，首版单次） |
| 嵌套递归循环（A include B，B include A） | 递归深度限制 + 已访问类型集合 |
| 字符串 DSL 拼错字段 | 运行时 QueryException 带清晰信息；文档标注 |
| 删除 JOIN 模式破坏大量测试 | 每 Task 逐步删 + 更新受影响测试，全程保持全绿 |
| 复合主键批量装配 | 连接键字符串化 |

## 测试基线
- 当前 master：705 测试全绿（含真实 MySQL/PG 集成）
- 每 Task 保持全绿 + 新测试；删除 JOIN 相关测试随代码删除

## 完成定义
- [x] LEFT JOIN 生成/装配代码全部删除
- [x] ref_to / has_one / has_many / ref_many 批量装配正确
- [x] 同表多 ref 合并一次查询
- [x] 嵌套 include（withInclude 链式）正确
- [x] 字符串 includeAll 点号路径正确
- [x] 混合 include 无笛卡尔积
- [x] page + include 正确
- [x] 全部既有测试迁移/删除后全绿
