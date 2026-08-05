# 自定义命名转换 Implementation Plan（@Refine[naming: "snake"]）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 支持 `@Refine[naming: "snake"]` 编译期注解，表名/列名 camelCase→snake_case，优先级 注解 > 全局策略 > 默认。

**Architecture:** `@Refine` 宏加 `attr` 参数解析 `naming`；宏包内置 `camelToSnake` + 表/列策略函数；`FieldInfo` 增加 `columnName` 字段，列名烘焙点统一用 `columnName`、字段访问点保持 `f.name`。表名单源头（refine_macro.cj:49）转换，下游全跟随。运行时层零改动。

**Tech Stack:** 仓颉宏（macro package refine.macros）、std.ast、cjpm。

**设计文档:** `docs/plans/2026-08-04-naming-strategy-design.md`（先完整读）

**环境（每任务必做）:**
```shell
eval $(cjvs env zsh) && eval $(cjvs stdx env zsh)
```
测试过滤：`cjpm test --filter 'XXX'`，输出用 `grep -E "PASSED|FAILED|Expect|Summary"`。

**基线:** 999 全绿（v0.6.1 + F4/F1/R-M19/Decimal）。

---

## 关键概念（必须先理解）

- **列名 vs 字段名分叉**：`FieldInfo.columnName`（列名，SQL/建表用，可转换）≠ `FieldInfo.name`（字段名，实体属性访问用，永不转换）
- **r.by 双身份**：同一字符串既是"被引用实体字段名"（`entity.$(byField)` 字段访问）又是"目标表列名"（SQL quoteIdentifier）。字段访问侧不转，SQL 列名侧转
- **一致性铁律**：rowMapper 查询键（method_gen.cj:204）必须与 SELECT 列（sql_gen.cj:342）用完全相同转换后字符串，否则 columnMap.contains 恒 false 静默丢字段
- **审计/软删字段保持字面名**：`created_at/updated_at/deleted_at` snake 幂等，不变化，相关判定/访问/列名三处无需改

---

### Task 1: @Refine 宏加 attr 参数 + naming 解析

**Files:**
- Modify: `src/macros/refine_macro.cj:42`（Refine 宏签名）
- Test: `src/macro_test.cj`（新增 fixture）

**Step 1: 写失败测试**

在 macro_test.cj 加 fixture（snake 策略实体）：
```cangjie
@Refine[naming: "snake"]
public class SnakeBlogPost {
    var id: Int64 = 0
    var userName: String = ""
}
```
加测试断言 `SnakeBlogPostSchema().tableName() == "snake_blog_post"`。

**Step 2: 跑测试确认失败**

Run: `cjpm test --filter 'SnakeBlogPost'`
Expected: 编译错误（宏无 attr 参数，`@Refine[naming: ...]` 解析失败）

**Step 3: 改宏签名**

`refine_macro.cj:42` 从 `public macro Refine(input: Tokens): Tokens` 改为：
```cangjie
public macro Refine(attr: Tokens, input: Tokens): Tokens {
```
解析 naming（在函数开头）：
```cangjie
var strategy = "none"
for (i in 0..attr.size) {
    if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "naming" && i + 2 < attr.size) {
        strategy = attr[i + 2].value   // "snake" / "none"
    }
}
```
`strategy` 作为局部变量传入后续所有生成函数调用。

**Step 4: 跑测试确认通过**

Run: `cjpm test --filter 'SnakeBlogPost'`
Expected: PASS（此步只验证宏能解析，表名转换在 Task 3）

**Step 5: 回归 + 提交**

Run: `cjpm test`（70+ 裸 @Refine 实体必须全绿——attr 空时 strategy="none"）
Commit: `feat: @Refine[naming] 属性宏参数解析（默认 none）`

---

### Task 2: 宏包命名策略函数 naming.cj

**Files:**
- Create: `src/macros/naming.cj`
- Test: `src/macros/` 单测（宏包内函数无法直接单测——用宏生成实体间接测，或放到运行时包测）

**决策：camelToSnake 放哪可测？** 宏包函数只能被宏调用。策略函数是纯字符串变换，**放运行时包 `src/naming.cj`**（package refine）可单测，宏生成代码调用 `refine` 包函数（用户文件已 import refine）。这符合"宏生成代码不写 import"约束（实体文件必然 import refine）。

**Step 1: 写失败测试**

`src/naming_test.cj`：
```cangjie
@Test
public class NamingTest {
    @TestCase public func testCamelToSnake(): Unit {
        @Expect(camelToSnake("userName"), "user_name")
        @Expect(camelToSnake("userID"), "user_id")
        @Expect(camelToSnake("HTMLParser"), "html_parser")
        @Expect(camelToSnake("user_name"), "user_name")   // 幂等
        @Expect(camelToSnake("id"), "id")
    }
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test --filter 'NamingTest'`
Expected: FAIL（camelToSnake 未定义）

**Step 3: 实现**

`src/naming.cj`：
```cangjie
package refine

// 驼峰 → snake_case：除首字母外的每个大写字母前插 "_"，整串小写。
// 连续大写处理：userID → user_id，HTMLParser → html_parser。
public func camelToSnake(name: String): String {
    if (name.size == 0) { return name }
    var out = StringBuilder()
    out.append(name[0].toAsciiLower())
    for (i in 1..name.size) {
        let c = name[i]
        if (c.isAsciiUpper()) {
            // 前一个字符是小写或数字 → 插下划线（userName→user_name）
            // 前一个也是大写且下一个是小写 → 插下划线（HTMLParser→html_parser）
            let prevLower = name[i-1].isAsciiLower() || name[i-1].isAsciiDigit()
            let nextLower = i + 1 < name.size && name[i+1].isAsciiLower()
            if (prevLower || nextLower) { out.append('_') }
            out.append(c.toAsciiLower())
        } else {
            out.append(c)
        }
    }
    out.toString()
}

public func applyTableNameStrategy(name: String, strategy: String): String {
    if (strategy == "snake") { camelToSnake(name) } else { lowerTableName(name) }
}

public func applyColumnNameStrategy(name: String, strategy: String): String {
    if (strategy == "snake") { camelToSnake(name) } else { name }
}
```
（`lowerTableName` 在 meta.cj 是宏包函数——运行时包需副本或移动；**检查**：meta.cj 的 lowerTableName 被宏包和运行时引用情况，必要时在 naming.cj 重实现或共享）

**Step 4: 跑测试确认通过**

Run: `cjpm test --filter 'NamingTest'`
Expected: PASS

**Step 5: 提交**

Commit: `feat: 命名转换策略函数 camelToSnake/apply*Strategy`

---

### Task 3: FieldInfo.columnName + 表名单源头转换

**Files:**
- Modify: `src/macros/refine_macro.cj`（FieldInfo struct + extractFields 后填充 + 表名计算 :49）
- Modify: `src/macros/meta.cj`（若 extractFields 在 meta.cj）

**Step 1: 写失败测试**

沿用 Task 1 的 SnakeBlogPost，补断言：
```cangjie
@Expect(SnakeBlogPostSchema().tableName(), "snake_blog_post")
@Expect(SnakeBlogPostSchema().columns()[1].name, "user_name")
```

**Step 2: 跑测试确认失败**

Run: `cjpm test --filter 'SnakeBlogPost'`
Expected: FAIL（tableName 仍 "snakeblogpost" / 列名仍 "userName"）

**Step 3: 实现**

- `FieldInfo`（refine_macro.cj:6-22）加 `var columnName: String`（init 同步）
- 在 `extractFields` 之后（refine_macro.cj:54 后）为每个字段填：
  ```cangjie
  // 遍历 mergedFields 填 columnName = applyColumnNameStrategy(f.name, strategy)
  ```
  注意 mergedFields 是 FieldInfo 数组，需重建（FieldInfo 是 struct，值拷贝）
- 表名 :49：`var tableName = applyTableNameStrategy(className, strategy)`（`@Table` 覆盖分支 :50-52 不转）

**Step 4: 跑测试确认通过**

Run: `cjpm test --filter 'SnakeBlogPost'`
Expected: PASS

**Step 5: 回归 + 提交**

Run: `cjpm test`（默认 none 全绿）
Commit: `feat: FieldInfo.columnName + 表名/列名策略转换接入`

---

### Task 4: 列名烘焙点统一用 columnName

**Files:**
- Modify: `src/macros/schema_gen.cj:39,18`（ColumnDef 列名、ColumnNames）
- Modify: `src/macros/sql_gen.cj:342,47,75,126,280,130,29,283,196-206,354`（SELECT/INSERT/UPDATE/SET/pk/version/RETURNING 列）
- Modify: `src/macros/method_gen.cj:17,204,290`（Col/rowMapper 键/rawIdExtractor 键）
- Modify: `src/macros/tx_gen.cj:119,133,156-169`（upsert 列/冲突列/审计更新列）
- Test: `src/macro_test.cj`

**关键：这些烘焙点从 `f.name`/`pk.name`/`vd.identifier.value` 换成 `f.columnName`/`pk.columnName`/对应的 columnName。字段访问点（token_gen.cj 的 entity.f、method_gen.cj:212/219 赋值 LHS）不动。**

**Step 1: 写失败测试**

SnakeBlogPost 断言完整四件套一致：
```cangjie
// 建表列名
@Expect(SnakeBlogPostSchema().columns()[1].name, "user_name")
// SELECT 列（query 的 select）
// Col DSL
@Expect(SnakeBlogPostCols().userName.name, "user_name")
// rowMapper 键（间接：roundtrip 或检查 ColumnNames）
@Expect(SnakeBlogPostColumnNames()[1].name, "user_name")
```

**Step 2: 跑测试确认失败**

Run: `cjpm test --filter 'SnakeBlogPost'`
Expected: 部分 FAIL（Col 列名、rowMapper 键未转）

**Step 3: 实现**

逐一替换烘焙点。**每个替换前 grep 确认该位置确实烘焙列名（非字段访问）**：
```shell
rg -n "f.name" src/macros/schema_gen.cj src/macros/sql_gen.cj
```
只有"用作 SQL/建表列名字符串"的位置才换 columnName。

**Step 4: 跑测试确认通过 + 回归**

Run: `cjpm test --filter 'SnakeBlogPost' && cjpm test`
Expected: 全 PASS（默认 none 下 columnName == name，零行为变化）

**Step 5: 提交**

Commit: `feat: 列名烘焙点统一使用 columnName（列名/字段名分叉）`

---

### Task 5: r.by 双身份 + junction 派生列 + via

**Files:**
- Modify: `src/macros/relation_gen.cj`（SQL 列名侧 r.by、junction 目标列、默认 via）
- Modify: `src/macros/method_gen.cj:114,134,139,148`（Col fk、junctionTargetCol）
- Modify: `src/macros/schema_gen.cj:81`（junction 目标列）
- Test: `src/macro_test.cj`

**Step 1: 写失败测试**

snake 策略实体带关系：
```cangjie
@Refine[naming: "snake"]
public class SnakeAuthor {
    var id: Int64 = 0
    var displayName: String = ""
}
@Refine[naming: "snake"]
public class SnakePost {
    var id: Int64 = 0
    @Ref[SnakeAuthor, by: "authorId"]
    var author: Option<SnakeAuthor> = None
}
```
断言：
- relation.foreignKey == "author_id"（by: "authorId" → snake 列名）
- 字段访问仍用 authorId（编译通过即证明）
- junction 目标列 snake（如有 ref_many）

**Step 2: 跑测试确认失败**

Run: `cjpm test --filter 'Snake'`
Expected: FAIL（fk 列名未转 / junction 列名未转）

**Step 3: 实现**

- method_gen.cj:114,134,139（Col fk / has_many fk）：`fkLit = STRING_LITERAL(applyColumnNameStrategy(r.by, strategy))`
- relation_gen.cj:21-24 等 SQL 侧 r.by：同样套 applyColumnNameStrategy
- **字段访问侧不动**（relation_gen.cj:164 entity.$(byField)、method_gen.cj:116 FkExtractor）
- junction 目标列三处（schema_gen.cj:81 / method_gen.cj:148 / relation_gen.cj:47）统一 `applyColumnNameStrategy(lowerTableName(target), strategy) + "_id"`
- 默认 via（meta.cj:44,56）：`applyTableNameStrategy(关系字段名, strategy)`；显式 via 不转

**Step 4: 跑测试确认通过 + 回归**

Run: `cjpm test --filter 'Snake' && cjpm test`
Expected: 全 PASS

**Step 5: 提交**

Commit: `feat: r.by 双身份分离 + junction 派生列 + via 默认转换`

---

### Task 6: 完整 snake 宏测试 + 优先级 + 真实 DB roundtrip

**Files:**
- Modify: `src/macro_test.cj`（优先级测试、include 路径测试）
- Modify: `src/pgsql_integration_test.cj` / `src/mysql_integration_test.cj` / `src/mariadb_integration_test.cj`
- Modify: `docs-site/guide/entities.md`（命名约定文档）

**Step 1: 写失败测试**

1. **优先级**：
   - `@Table["custom_table"]` + snake → 表名 custom_table（注解优先）
   - `@Field` 覆盖列名（如需 @Field 支持列名参数——**本迭代不做**，@Field 只覆盖 storageType；列名显式指定记档）→ 优先级测试聚焦 @Table vs snake
2. **include 路径**：snake 实体 include 关系，装配一致（列名/表名不丢）
3. **真实 DB**（PG/MySQL/MariaDB）：snake 实体 autoMigrate + save + query + include roundtrip

**Step 2: 跑测试确认失败**

Run: `cjpm test --filter 'Snake'`
Expected: FAIL（新测试未通过）

**Step 3: 实现**

补优先级/include/集成测试断言；修暴露的转换遗漏（如有）。

**Step 4: 跑测试确认通过 + 全量回归**

Run: `cjpm test`
Expected: 全绿（原 999 + snake 新测试）

**Step 5: 文档 + 提交**

docs-site/guide/entities.md 加命名转换说明（@Refine[naming]、优先级、幂等）。
Commit: `feat: snake 命名策略完整测试 + 真实 DB roundtrip + 文档`

---

## 完成定义（全部满足才结束）

- [ ] `@Refine[naming: "snake"]` 宏解析（attr 空默认 none）
- [ ] naming.cj 策略函数可单测（camelToSnake 边界：userID/HTMLParser/幂等）
- [ ] FieldInfo.columnName 全列名烘焙点接入（schema/SELECT/INSERT/UPDATE/Col/rowMapper/upsert）
- [ ] r.by 双身份分离正确（字段访问不转、SQL 列名转）
- [ ] junction 源/目标列、默认 via 转换一致
- [ ] 默认 none 全量回归（999 基线）全绿
- [ ] snake 完整测试（四件套一致 + 优先级 + include）+ 真实 DB roundtrip
- [ ] docs-site 命名文档
