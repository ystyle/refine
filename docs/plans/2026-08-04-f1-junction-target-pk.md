# F1 设计：ref_many junction 目标列类型运行时推断

> 日期：2026-08-04
> 目标：解决 String-pk 目标的 ref_many junction（中间表）目标列类型硬编码 `StorageType.Integer` 的问题——VARCHAR 列建表成 INTEGER。

## 背景

- `buildJunctionSchema`（schema_gen.cj:76-97）硬编码目标列 `StorageType.Integer`（:92）
- 源列已跟随源主键类型（refine_macro.cj 传 sourcePkStorage）
- 宏层**无法跨类内省**目标实体主键类型（仓颉宏只能操作当前展开的 AST，无全局符号表，已从官方文档确认）
- 现状：R-I9 运行时预检（relation_gen.cj:105-113）在 append 时对 String-pk 目标抛 RefineException（"unimplemented"），String-pk 目标的 ref_many **功能不可用**

## 运行时方案（用户提议，已验证可行）

**核心思路**：目标实体必须被 `@Refine` 修饰（ref_many 依赖其 Schema/query 方法），因此 `$(target)Schema` 类必然存在。junction schema 的 `columns()` 方法不再生成字面量，而是**运行时从目标实体 Schema 读取主键列类型**。

### 改动：buildJunctionSchema（schema_gen.cj:76-97）

生成代码从：
```cangjie
public func columns(): Array<ColumnDef> {
    [ColumnDef("post_id", StorageType.Integer, true, false, false),
     ColumnDef("tag_id", StorageType.Integer, true, false, false)]
}
```
改为：
```cangjie
public func columns(): Array<ColumnDef> {
    // F1: 目标列类型运行时从目标实体 Schema 读取（宏层无法跨类内省，
    // 目标实体被 @Refine 修饰保证 $(target)Schema 存在）。取主键列 storageType，
    // 复合主键取第一个 pk 列。找不到主键列时回退 Integer（防御）。
    let targetSchema = $(target)Schema()
    var targetPkType = StorageType.Integer
    let tcols = targetSchema.columns()
    for (c in tcols) {
        if (c.primaryKey) { targetPkType = c.storageType; break }
    }
    [ColumnDef("$(sourceTable)_id", $(sourceStorage), true, false, false),
     ColumnDef("$(targetTable)_id", targetPkType, true, false, false)]
}
```

**关键点**：
- `$(target)` 是 RelInfo.target（如 "UuidTag"）→ 生成 `UuidTagSchema()` 引用，编译期解析（非宏内省，是运行时对象访问）
- 目标实体未 @Refine 修饰时 `UuidTagSchema` 不存在 → **编译期失败**（比运行时预检更早暴露，且语义正确：ref_many 本就依赖目标实体可内省）
- 目标主键 `@Field` storageOverride 自动生效（读的是 ColumnDef.storageType 最终值）

### 连带改动

1. **relation_gen.cj R-I9 预检移除**：junction 目标列类型现在运行时正确（String 目标列生成 String），append 不再需要抛 "unimplemented"。原预检的 `match (anyId) { case _: String => throw }` 删除。但保留目标 id 为空的 precheck（unsavedMsg）。

2. **junction 源列目标列同时受复合主键影响**：目标复合主键取第一个 pk 列（与源侧逻辑一致，refine_macro.cj:186-197 源侧复合主键也取第一个）。文档说明。

### 边界情况

| 场景 | 行为 |
|---|---|
| 目标 Int64-pk | 运行时读到 Integer，与现状一致 |
| 目标 String-pk | 运行时读到 String，junction 目标列 TEXT，ref_many 可用（R-I9 预检移除） |
| 目标 Bool-pk | 运行时读到 `Bool`（StorageType.`Bool`），正确 |
| 目标复合主键 | 取第一个 pk 列（与源侧一致） |
| 目标未 @Refine | 编译期错误（UuidTagSchema 不存在）——比现状的运行时预检更早 |
| 目标主键 @Field[Text] 覆盖 | 运行时读到覆盖后的 storageType，正确 |

### 为什么不采用"用户显式 @Ref targetPk 参数"

运行时方案更优：
- 用户零配置（不写 targetPk）
- 自动适配 Int64/String/Bool/复合/override 全部场景
- 无"忘写 targetPk 导致建表失败"的坑
- 类型安全：目标必须 @Refine 才有 Schema 类

## 测试计划（TDD，先写后实现）

1. **宏测试（macro_test.cj）**：
   - 现有 `testJunctionSourceColStringWhenUuidSourcePkString` 期望目标列 Integer → **改为期望 String**（UuidTag 是 String-pk）
   - 新增：Int64-pk 目标（Tag）→ 目标列仍 Integer
   - 新增：Bool-pk 目标 → 目标列 `StorageType.`Bool``
   - 新增：String-pk ref_many **真实可用**（append/load 不再抛 "unimplemented"）——原 R-I9 抛错测试改为断言正常 append
2. **schema DDL 测试**：junction 表 CREATE TABLE 目标列类型正确（String→TEXT）
3. **真实 DB 集成（PG/MySQL）**：String-pk 源 + String-pk 目标 ref_many 端到端 roundtrip（save → include/load → 删除）——F1 审计备注要求"修复后补真实 DB 验证"
4. **db/relation 测试**：移除 R-I9 预检后，原抛 RefineException 的测试改为断言成功路径

## 完成定义
- [ ] junction 目标列类型运行时从目标实体 Schema 读取
- [ ] String-pk 目标 ref_many 端到端可用（append/load/clear/count）
- [ ] R-I9 预检移除（保留目标 id 空 precheck）
- [ ] 现有 Int64 场景无回归，全量测试通过
- [ ] 审计 F1 标记已解决 + 真实 DB 验证记录
