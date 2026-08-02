# Batch Include（分步查询预加载）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 include 预加载从单查询 LEFT JOIN 方案改为分步查询（batch include），消除笛卡尔积爆炸并支持按目标表合并查询。

**Architecture:** 保留现有 JOIN 模式为默认降级路径，新增 `useBatchInclude` 开关。开启后 `all()/one()/page()` 先查主实体，再按目标表批量执行 N+1 次查询（ref_to 按外键 IN、has_many 按主键 IN、ref_many 走 junction JOIN），按 id 建立 HashMap 查找表装配关联。嵌套 include（关联的关联）留作独立后续任务。

**Tech Stack:** 仓颉语言、refine ORM（Expr/Statement/Dialect 渲染、宏生成 RowMapper）

---

## 背景与设计依据

- 设计文档：`docs/plans/2026-06-05-batch-include-design.md`（概念设计，非实现计划）
- 当前实现：LEFT JOIN 单查询 + `aggregateWithCollections` 内存去重（query.cj）
- 已完成的关联工作：C2（include 字段子集装配）、C4（page 集合去重 + COUNT DISTINCT）、I12（集合保序）
- **当前 JOIN 方案的三个问题**（设计文档）：
  1. 多 has_many 笛卡尔积爆炸（乘法叠加）
  2. 同表多 ref 重复 JOIN（5 个 `@Ref[User]` → 5 次 JOIN users）
  3. 无法嵌套 include

## 关键设计决策

### D1: 默认模式
- 保留 JOIN 模式为默认（`useBatchInclude = false`），batch include 通过 `.enableBatchInclude(true)` 显式开启。
- 理由：batch include 是全新路径，需充分测试后才能作为默认；JOIN 模式已有 C2/C4 完整测试保障。
- **注意**：设计文档写"默认启用分步查"，但为了稳妥（新路径未充分验证），本计划采用**默认 JOIN、显式开启 batch**。若后续 batch 验证充分可翻转默认。

### D2: IRelation 扩展
新增可选方法（带默认实现，不破坏现有实现）：
```cangjie
public interface IRelation {
    // 新增：标记该关联是否支持分步查询（默认 true）
    func isBatchSupported(): Bool { true }
}
```
- 目标表去重通过现有 `resolve()` 的第三个元素（targetTable）即可，无需新增方法。
- 现有 4 个 Relation 子类（RefTo/RefMany/HasOne/HasMany）自动继承默认实现。

### D3: 分步查询的 mapper 复用
- 批量查询复用现有 `getTargetMapper()`（已支持字段子集宽容，见 C2）。
- 装配用现有 `getFieldSetter()`（ref_to 覆盖赋值 / has_many add）。
- 主实体查询复用现有 mapper（含 wrapMapper 包装的 ref_to/has_one 单行装配）。

### D4: 嵌套 include 范围
- **本计划不含嵌套 include**（关联的关联递归分步查）。设计文档提到但标注为后续。
- `isBatchSupported()` 接口先落地，嵌套后续扩展。

## 分步查询协议（batch include 执行流）

对 `Query<T>` 开启 batch 后，`all()/one()/page()` 改为：

1. **查主实体**：渲染并执行不含 include JOIN 的主查询（仅主表 FROM/WHERE/GROUP/HAVING/ORDER/LIMIT/OFFSET），用主 mapper 映射。
   - ref_to/has_one 主实体已由 wrapMapper 单行装配（JOIN 模式逻辑），但 batch 模式下**不 JOIN**，ref_to 由后续批量查询填充。
2. **按目标表分组**：遍历 `included`，按 `resolve().targetTable` 分组为 4 类：
   - `ref_to_targets: Map<表名, [IRelation]>`
   - `has_one_targets: Map<表名, [IRelation]>`
   - `has_many_targets: Map<表名, [IRelation]>`
   - `ref_many_targets: Map<表名, [IRelation]>`
3. **批量 ref_to**：对每个 (目标表, rels)：
   - 收集主实体中每个 rel 的 `foreignKey` 列值（非 NULL），去重
   - `SELECT * FROM 目标表 WHERE id IN (去重外键)`
   - 按 id 建 `HashMap<PK, TargetEntity>`
   - 遍历主实体，按外键取值，`setter(entity, target)`
4. **批量 has_one/has_many**：对每个 (目标表, rels)：
   - 收集主实体 id
   - `SELECT * FROM 目标表 WHERE fk IN (主键集合)`
   - 按 fk 分组建 `HashMap<FK, Array<TargetEntity>>`
   - has_many：整组赋值 / has_one：取第一个
5. **批量 ref_many**：对每个 (目标表, rels)：
   - 收集主实体 id
   - `SELECT t.* FROM viaTable j JOIN 目标表 t ON j.target_id = t.id WHERE j.source_id IN (主键集合)`
   - 按 source_id 分组装配

### 空集合处理
- 外键/主键集合为空时跳过该批量查询（避免 `IN ()` 非法 SQL）。
- 复用现有 `buildKeyExtractor` 生成主键（复合主键支持）。

### 与 C4 的交互
- batch 模式下 `aggregateWithCollections` 不再需要（无 JOIN 展开，主查询本身就是去重的）。
- `countWith`/`exists()` 在 batch 模式下无需 COUNT DISTINCT（主查询无 JOIN）。
- page() 的 total 直接用主查询 COUNT（batch 模式下天然正确）。

## Task 结构

### Task 1: IRelation 接口扩展 + Query 开关
**Files:**
- Modify: `src/relation.cj`
- Modify: `src/query.cj`
- Test: `src/query_test.cj`

**Step 1: 写失败测试**
- IRelation 新增 `isBatchSupported(): Bool { true }` 默认实现（默认方法无需测试失败，编译通过即可）。
- Query 新增 `public var useBatchInclude: Bool = false` + `public func enableBatchInclude(v: Bool): Query<T> { useBatchInclude = v; this }`。

**Step 2: 编译验证**
Run: `eval $(cjvs env zsh) && eval $(cjvs stdx env zsh) && cjpm build`
Expected: 编译通过（默认实现 + 新字段不破坏现有代码）

**Step 3: 提交**
```bash
git add src/relation.cj src/query.cj
git commit -m "feat: batch include 开关与 IRelation.isBatchSupported 默认实现"
```

### Task 2: batch include 核心——主查询分离
**Files:**
- Modify: `src/query.cj`
- Test: `src/query_test.cj`

**Step 1: 写失败测试**
```cangjie
// 开启 batch 后，all() 渲染的主查询 SQL 不含 include 的 JOIN
let q = Post.query().using(rf).enableBatchInclude(true).include(PostRel.author)
let sql = q.getLastSQL()  // 需要测试可观测的 SQL（或捕获 capturedSqlHistory）
@Expect(sql.contains("LEFT JOIN"), false)
```

**Step 2: 实现**
- `processIncluded` 增加分支：`if (useBatchInclude) { return }`（不生成 JOIN、不改 SELECT、不 qualify）。
- 新增 `private func loadBatchIncludes(result...)` 或在 all/one/page 中调用批量装配。

**Step 3: 测试通过**
**Step 4: 提交**

### Task 3: 批量 ref_to
**Files:**
- Modify: `src/query.cj`
- Test: `src/query_test.cj`

**Step 1: 写失败测试**
- 主查询 2 条实体，各 ref_to 到不同 User，mock 第二条批量查询返回对应 User。
- 断言：执行了 2 次查询（主 + 批量），实体 ref_to 字段正确装配，setter 被调用。

**Step 2: 实现批量 ref_to**
- 收集外键 → 去重 → IN 查询 → HashMap 装配。

**Step 3-4: 测试 + 提交**

### Task 4: 批量 has_many + has_one
**Files:**
- Modify: `src/query.cj`
- Test: `src/query_test.cj`

同 Task 3 模式：按 fk IN 主键集合批量查询，分组装配。

### Task 5: 批量 ref_many（junction）
**Files:**
- Modify: `src/query.cj`
- Test: `src/query_test.cj`

junction JOIN 批量查询（via 表 + 目标表 IN）。

### Task 6: 集成测试（真实 MySQL/PG/SQLite mock）
**Files:**
- Test: `src/macro_test.cj` / `example/src/service_test.cj`

- 多 has_many + ref_to 混合 include，验证无笛卡尔积（结果行数 = 主实体数，非乘法）
- 同表多 ref（如 2 个 @Ref[User]）合并为 1 次批量查询（断言查询次数）
- page + batch include 组合
- 空关联（主实体无子对象）正常装配

### Task 7: 文档
**Files:**
- Modify: `docs/design.md` / `docs-site/`

更新 include 文档：batch include 用法、默认 JOIN 模式说明、能力差异（嵌套 include 待支持）。

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| N+1 查询次数增多（1+N 次 vs 1 次） | 按目标表合并（同表多 ref 一次查询）；批量 IN 查询 |
| 大 IN 列表（数千主键） | 分块 IN（每批 ~500）——后续优化，首版支持单次 |
| 与 C4 page/count 交互 | batch 模式天然无 JOIN，COUNT 天然正确 |
| 字段子集 include | 复用 C2 的 mapper 宽容（未选字段默认值） |
| 嵌套 include | 明确不在首版范围，isBatchSupported 接口预留 |

## 测试基线
- 当前 master：705 测试全绿（含真实 MySQL/PG 集成）
- 每 Task 需保持全绿 + 新测试

## 完成定义
- [ ] `useBatchInclude` 开关可用，JOIN 模式为默认
- [ ] ref_to / has_one / has_many / ref_many 四类批量装配正确
- [ ] 同表多 ref 合并为一次查询
- [ ] 混合 include 无笛卡尔积
- [ ] page + batch 组合正确
- [ ] 空关联正确
- [ ] 全部既有测试不回归
