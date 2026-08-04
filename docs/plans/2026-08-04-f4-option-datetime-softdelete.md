# F4 设计：Option<DateTime> 可空软删字段支持

> 日期：2026-08-04
> 目标：让 `deleted_at: Option<DateTime>` 成为软删字段的可用模型（当前 R-I7 守卫拦截非 Option DateTime，Option 写法被 isRelationField 静默跳过）。

## 背景

审计 F4（docs/audit/2026-08-02-full-audit.md:286）：
- 非 Option `deleted_at: DateTime` 已被 R-I7 守卫拦截（refine_macro.cj:113）——INSERT 写 `DateTime.now()` 后列永非 NULL，`IS NULL` 过滤恒假，静默隐藏所有行
- 正确模型 `Option<DateTime>` 被 `isRelationField`（meta.cj:222 `contains("Option")`）当关系字段**静默跳过**（schema/insert/select/mapper 全不识别），且因 `deletedAtIsDateTime == false`（类型字符串 `"Option < DateTime >"` ≠ `"DateTime"`）R-I7 守卫漏过——生成无意义 `deleted_at = 0` 过滤

## 关键语言验证（探针实测，2026-08-04）

| 场景 | 结果 |
|---|---|
| `match(any: Any) { case v: Option<DateTime> }` 对**类型化变量**装箱值 | ✅ 命中 |
| `match(any) { case None }` | ❌ 编译错（None 不是 Any 的 enum 变体） |
| `Some(dt) as Any` 字面量显式装箱后 match | ❌ 丢失运行时类型（落到 `case _`） |
| `let some: Option<DateTime> = Some(dt); let boxed: Any = some` 变量装箱后 match | ✅ 命中 |
| 宏层生成的 `allParams.add(entity.deleted_at)`（变量装箱） | ✅ 等价于变量场景，可匹配 |

**推论**：
- dispatchSet 需新增 `case v: Option<DateTime> => 内部 match Some→set<DateTime> / None→setNull`
- 宏层写路径直接 `allParams.add(entity.deleted_at)`（变量装箱）即可，**不需要哨兵对象**
- 对任意 `Option<T>`（Int64/String 等）需要通用处理？——Option<DateTime> 是软删场景；普通可空标量字段（Option<Int64> 等）是否一并支持？见下方设计决策。

## 改动点

### 1. meta.cj — 可空标量判定与解包
- 新增 `func isNullableScalarType(typeName: String): Bool`：归一化（去空格）后匹配 `Option<内部>`，内部 ∈ 标量集 {Int8..UInt64, Float32, Float64, Bool, String, DateTime}（排除 `Array<UInt8>` Bytes 场景的 Option 化）
- 新增 `func unwrapOptionType(typeName: String): String`：取 `Option<X>` 的 X
- `isRelationField`（meta.cj:220）：加 `if (isNullableScalarType(typeName)) { return false }`
- `detectRelations`（meta.cj:27）：Option 分支前加 `if (isNullableScalarType(tn)) { continue }`（防御，当前因空格渲染分支是死代码，防未来变化）
- `typeNameToStorageType`（meta.cj:245）：开头 `if (isNullableScalarType) { typeName = unwrapOptionType(...) }` 再走原映射（`Option<DateTime>` → StorageType.Timestamp）
- `shouldSkipInInsert`：不变（依赖 isRelationField，Option 标量不再跳过）

### 2. refine_macro.cj — 软删判定
- `:102` → `let norm = f.typeName.replace(" ", ""); deletedAtIsDateTime = (norm == "DateTime" || norm == "Option<DateTime>")`
- `:113` R-I7 → `if (isSoftDelete && deletedAtIsDateTime && norm != "Option<DateTime>") throw ...`（仅拦非 Option）
- `:125` 过滤分支不变（IS NULL 对 Option 天然正确），更新注释语义

### 3. token_gen.cj — 写路径参数收集
- `buildEntityArrayTokens`（:49）：对 `isNullableScalarType` 字段，生成
  ```cangjie
  // 变量装箱（保留运行时类型）→ dispatchSet 的 Option 分支处理
  allParams.add(entity.deleted_at);
  ```
  即**与普通字段相同**的 `entity.f` 引用——靠 dispatchSet 的 `case v: Option<T>` 分支处理 None/Some。无需生成 match。
- `buildUpdateEntityArrayTokens`（:182）：同上
- `buildSoftDeleteEntityParamsToken`（:158）：`deletedAtIsDateTime` 写裸 `DateTime.now()`（Option 与否无关，参数数组装 DateTime 即可，dispatchSet `case v: DateTime` 命中）

### 4. sql_gen.cj
- `buildBatchInsertSQLFunc.addParams`（:85）：Option 字段 `allParams.add(entities[_i_].f)` 不变（同上）
- `buildBatchUpdateSQLFunc.addParams`（:157）：同上
- `pgCastTypeOf`（:364）：开头解包 Option——`isNullableScalarType` 时取内部类型映射（`Option<DateTime>` → TIMESTAMP 而非 TEXT）
- `buildSelectColumnTokens`（:340）：`isRelationField` 放行后 Option 标量自然进入列选择，无需改

### 5. schema_gen.cj — nullable
- `buildSchemaClass`（:43-54）：第五参 `nullable` 改 `if (isNullableScalarType(f.typeName)) { "true" } else { "false" }`（替换硬编码 false）

### 6. method_gen.cj — 读路径
- `buildRowMapper`（:205-209）：Option 标量字段改生成
  ```cangjie
  if (columnMap.contains("deleted_at")) {
      entity.deleted_at = result.getOrNull<DateTime>(columnMap.get("deleted_at").getOrThrow())
  }
  ```
  （普通字段保持 `result.get<T>`；Option 用 `getOrNull<内部>` 返回 Option<T>）

### 7. db.cj — dispatchSet
- 在 `case v: DateTime` 后新增：
  ```cangjie
  case v: Option<DateTime> =>
      match (v) {
          case Some(dt) => stmt.set<DateTime>(index, dt)
          case None => stmt.setNull(index)
      }
  ```
- 是否支持其它 `Option<T>`（Int64/String/Bool 等）？见设计决策 D1。

## 设计决策

### D1. Option<T> 泛型可空标量支持范围
**方案 A（推荐）：仅 Option<DateTime>（软删场景）**
- dispatchSet 只加 `case v: Option<DateTime>`，宏层 isNullableScalarType 只认 DateTime 可空
- 理由：F4 范围是软删；其它可空标量是**新功能**（历史上所有 Option 都被当关系，无先例），扩大会引入批量新语义（INSERT/UPDATE/schema/mapper 全链路 + 全部测试），超出 F4
- 普通 `Option<Int64>` 等字段当前仍被当关系跳过——保持现状，记档为后续功能

**方案 B：全标量 Option<T> 支持**
- dispatchSet 需要处理任意泛型 Option<T>——仓颉 `match(any) { case v: Option<Int64> }` 需逐一写，且 `getOrNull<T>` 读路径要按 T 生成，复杂度高
- 风险：Option<标量> 与 ref_to 关系（Option<Entity>）的区分已在宏层做，但运行时 dispatchSet 无法泛型穷举

**结论：选方案 A**（F4 聚焦软删，Option<DateTime> 是唯一需要可空标量的场景）。

### D2. 软删 Option<DateTime> 的 INSERT 语义
- 未删行 `deleted_at = None` → INSERT 绑 NULL（`setNull`）→ 列保持 NULL → `IS NULL` 过滤命中（可见）
- 软删写 `SET deleted_at = ?` 参数 `DateTime.now()`（Some 语义），行被过滤
- 与 Int64 软删（`= 0` / `= 1`）语义平行，行为一致

### D3. 反向迁移兼容
- 已有 Int64 deleted_at 表迁移到 Option<DateTime>：列类型 TIMESTAMP 从 INTEGER 变更属破坏性——需用户手动迁移（migrator 只加不改，F 系列约束）。记档。

## 测试计划（按 AGENTS.md 沉淀）

1. **macro_test.cj 新 fixture**：`deleted_at: Option<DateTime>` 软删实体 + @HardDelete 变体
2. **新测试类 `OptionDateTimeSoftDeleteTest`**：
   - schema：`deleted_at` 列 nullable=true、storageType=Timestamp
   - query()：过滤为 `Expr.Unary(IsNull, Column("deleted_at"))`
   - INSERT：None → 断言 `setNull` 被调用；Some(dt) → 断言 `capturedSetValues` 含 DateTime
   - 软删：`tx.delete` → SQL `UPDATE ... SET "deleted_at" = ?` 参数为 DateTime
   - rowMapper：NULL 列 → `deleted_at.isNone()`；DateTime 列 → `isSome()`
   - batchSave/batchUpdate/upsert 的 Option 绑定
3. **db_test.cj**：`testDispatchSetOptionDateTimeSome/None`（MockStatement.lastSetType 断言）
4. **migrator_test**：可空列 DDL 断言
5. **集成**（真实 PG/MySQL）：roundtrip save 未删行读回 None、delete 后 query() 过滤掉

## 完成定义
- [ ] `deleted_at: Option<DateTime>` 实体可建表（nullable 列）、insert/query/delete 端到端正确
- [ ] R-I7 守卫仅拦非 Option DateTime
- [ ] dispatchSet Option<DateTime> 分支 + 测试
- [ ] 全量测试通过，无回归（现有 Option 关系字段行为不变）
- [ ] 审计文档 F4 标记已解决
