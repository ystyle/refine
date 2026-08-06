# 自定义命名转换设计（@Refine[naming: "snake"]）

> 日期：2026-08-04
> 目标：支持自定义表名/列名命名转换（camelCase→snake_case 等），优先级 注解 > 全局策略 > 默认。编译期注解方案（用户确认：改动最小）。

## 背景与需求

- 当前：表名 = `lowerTableName(className)`（BlogPost→blogpost）；列名 = 字段名（userName 即列名，无转换）
- 需求：`@Refine[naming: "snake"]` 时表名→blog_post、列名→user_name
- 优先级：`@Table["xxx"]` / `@Field` 显式指定 > `@Refine[naming]` 策略 > 默认行为
- 方案：**编译期注解**（用户确认，改动最小）——宏展开时把转换后表名/列名烘焙成字符串，静态方法（query()/schema()）直接用，无运行时开销

## 技术约束（已确认）

- 仓颉宏展开期可调用**常规包**函数（实验验证，早期"宏只能调用宏包代码"的约束已证伪）。策略函数放常规包 `refine.naming`（src/naming/naming.cj）——可被测试直接单测、宏包展开期 import 调用同一实现，零副本漂移。`naming: "snake"` 是策略名（非运行时函数引用）
- 宏定义与调用不能同包；`@Refine` 当前单参数 `input`，需加 `attr` 参数支持 `[naming: "snake"]`，attr 为空时保持默认（现有 70+ 裸 @Refine 回归集）
- 宏生成代码不写 import（实体文件需已 import 所需类型）

## 架构

### 命名策略函数（常规包新文件 src/naming/naming.cj，宏包展开期 import 调用）

```cangjie
// 驼峰 → snake_case（处理连续大写：userID→user_id，HTMLParser→html_parser）
func camelToSnake(name: String): String

// 表名策略：none = lowerTableName(className)（现行为）；snake = camelToSnake(className)
func applyTableNameStrategy(name: String, strategy: String): String

// 列名策略：none = name；snake = camelToSnake(name)。幂等（已有下划线/小写不变化）
func applyColumnNameStrategy(name: String, strategy: String): String
```

### 宏入口（refine_macro.cj）

- `Refine` 宏签名 `(input: Tokens)` → `(attr: Tokens, input: Tokens)`，解析 `naming` 值（`"none"` 默认 / `"snake"`）
- `extractFields` 后为每个 `FieldInfo` 填 `columnName = applyColumnNameStrategy(f.name, strategy)`
- `FieldInfo`（refine_macro.cj:6）加 `var columnName: String`
- 表名：refine_macro.cj:49 一处套 `applyTableNameStrategy`；`@Table` 覆盖不转
- **列名与字段名从此在代码上分叉**：列名烘焙点用 `f.columnName`，字段访问点保持 `f.name`——机械区分，杜绝混用

### 列名烘焙点（用 columnName 替换 f.name）

| 位置 | 用途 |
|---|---|
| sql_gen.cj:342 | SELECT 列 Expr.Column |
| sql_gen.cj:47,75 | INSERT/BatchInsert 列 |
| sql_gen.cj:126,280 | BatchUpdate/Update SET 列 |
| sql_gen.cj:130,29 | UPDATE/DELETE/软删 WHERE pk 列 |
| sql_gen.cj:283,196-206 | UPDATE version 列 |
| sql_gen.cj:354 | RETURNING 自增主键列 |
| schema_gen.cj:39 | ColumnDef 列名（建表） |
| schema_gen.cj:18 | ColumnNames() 列名数组 |
| method_gen.cj:17 | Col 列名参数（用户 DSL） |
| method_gen.cj:204 | rowMapper columnMap 键 |
| method_gen.cj:290 | rawIdExtractor columnMap 键 |
| tx_gen.cj:119,133,156-169 | upsertSQL 列/冲突列/审计更新列 |
| relation_gen.cj:21-24 等 | 关系 SQL 的目标表 fk 列 |

### 字段访问点（保持 f.name，绝不转换）

- token_gen.cj 全部 `entity.f`（参数收集、pk 访问）
- method_gen.cj:212,219 rowMapper 赋值 LHS
- relation_gen.cj:164,286 等 `entity.$(byField)`（字段访问）
- meta.cj:175,178,187 审计写值 `entity.created_at`

### r.by 双身份处理（最大设计陷阱）

`r.by` 在关系里同时是"被引用实体字段名"和"目标表列名"：
- **字段访问侧**（relation_gen.cj:164 `entity.$(byField)`、method_gen.cj:116 FkExtractor）：保持 `r.by`（字段名）
- **SQL 列名侧**（method_gen.cj:114,134,139 Col、relation_gen.cj:21-24 quoteIdentifier）：套 `applyColumnNameStrategy(r.by, strategy)`

### 派生列名

- junction 源列 = `sourceTable + "_id"`：随表名转换自动正确（sourceTable 已是转换后值）
- junction 目标列 = `applyTableNameStrategy(target, strategy) + "_id"`（none → `lowerTableName(target) + "_id"`；snake → `camelToSnake(target) + "_id"`）：三处（schema_gen.cj:81 / method_gen.cj:148 / relation_gen.cj:47）**必须同步**，否则 load/insert 报列不存在。以目标类名直接套表名策略（不再二次 `applyColumnNameStrategy(lowerTableName(...))`，二者对前导 ≥2 连续大写类名不等价）

### 审计/软删/version 字段

**本迭代保持字段字面名 `created_at/updated_at/deleted_at`**（snake 幂等，不变化）：
- meta.cj:158-159 findAuditFields 判定、refine_macro.cj:99 软删检测、sql_gen.cj:210/329、tx_gen.cj:148 全部无需改
- 未来支持 `createdAt` 字段名时单独立项（判定/字段访问/列名三处一起动）

### via 中间表名

- 显式 `via`（@Ref/@Rel 注解）优先，不转
- 默认 via = 关系字段名：**跟随策略转换**（relatedPosts→related_posts，与建表一致；用户已确认）

### 审计/软删/version 字段（用户已确认：保持字面名）

**本迭代保持实体字段字面名 `created_at/updated_at/deleted_at`**（snake 幂等，不变化）：
- meta.cj:158-159 findAuditFields 判定、refine_macro.cj:99 软删检测、sql_gen.cj:210/329、tx_gen.cj:148 全部无需改
- 未来支持 `createdAt` 字段名时单独立项（判定/字段访问/列名三处一起动）

### 一致性铁律

rowMapper 查询键（method_gen.cj:204）必须与 SELECT 列（sql_gen.cj:342）使用**完全相同的转换后字符串**。漏转一侧 → columnMap.contains() 恒 false → 字段静默留默认值（最高危失败模式）。

## 影响面

- 运行时层（query_batch/relation/dialect/migrator）**零改动**——它们只搬运宏烘焙好的字符串
- 默认策略 none 全链路回归（70+ 裸 @Refine 实体测试不受影响）
- snake 策略新测试

## 测试计划（TDD）

1. **naming.cj 单测**：camelToSnake（userName→user_name、userID→user_id、HTMLParser→html_parser、已 snake 幂等）、applyTableNameStrategy/applyColumnNameStrategy
2. **宏测试**（snake 策略 fixture）：
   - 表名 blog_post、列名 id/user_name/created_at（建表 ColumnDef + SELECT + Col + rowMapper 四件套一致）
   - rowMapper 键 = SELECT 列 = ColumnDef 列 = Col 列（防静默丢失）
   - 优先级：@Table["xxx"] 覆盖 > snake > 默认；@Field 覆盖 > snake
   - 关系：r.by 字段名 vs 列名分离正确；junction 源/目标列 snake
   - include 路径（目标表/列名一致）
3. **回归**：默认 none 全量测试不变（现有 SQL 断言基线）
4. **真实 DB**（PG/MySQL/MariaDB）：snake 表/列 roundtrip

## 完成定义
- [ ] @Refine[naming] 属性宏解析（attr 空默认 none）
- [ ] camelToSnake + 表/列策略函数（常规包 refine.naming）
- [ ] FieldInfo.columnName 全烘焙点接入（列名 vs 字段名分离）
- [ ] r.by 双身份、junction 派生列、via 默认转换
- [ ] 默认 none 全量回归 + snake 新测试
- [ ] 真实 DB snake roundtrip
- [ ] 文档（docs-site entities.md 命名约定）
