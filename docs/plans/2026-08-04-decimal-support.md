# Decimal 字段支持设计（StorageType.Decimal 端到端）

> 日期：2026-08-04
> 目标：让实体声明 `Decimal` 字段（含可空 `Option<Decimal>`）端到端可用。当前 schema 层已就绪（C8 已修三方言 dataTypeOf + 反向映射），但读写路径未接线——dispatchSet 无 Decimal 分支、宏层 typeNameToStorageType 无 Decimal 映射（落 Json 兜底发 warning）、rowMapper 读 `get<Decimal>` 未处理。

## 背景

- `StorageType.Decimal` 枚举已存在（storage.cj）
- schema 层已完整（C8）：
  - SQLite `dataTypeOf(Decimal)` → "NUMERIC"（dialect_sqlite.cj）
  - MySQL → "DECIMAL(65,30)"（dialect_mysql.cj）
  - PG → "DECIMAL"（dialect_postgres.cj）
  - 反向映射 `"numeric"→Decimal` / `"decimal"→Decimal`（migrator_pg/mysql）
  - `defaultValueOf(Decimal)` → "0"
- **未接线**（本次目标）：
  - 宏层 `typeNameToStorageType("Decimal")` 落 Json 兜底 → schema 建 JSON 列（错误！应 Decimal）
  - dispatchSet 无 `case v: Decimal` → 写路径抛 RefineException
  - rowMapper `get<Decimal>` 未特殊处理（普通 `result.get<T>` 实际可用？需验证）
  - M22 warning 会误报 "maps to StorageType.Json"（Decimal 不是未知 struct）

## 关键事实（已实测/文档确认）

1. **std `Decimal` 类型**：`std.math.numeric` 包，`Decimal.parse("...")` 构造，toString/运算/比较齐全
2. **pgsql 驱动完整支持 Decimal**：
   - set 绑定：`case v: Decimal => v.toString()`（value.cj:215）
   - 读：OID_NUMERIC → "Decimal" 类型名，decode 支持（value.cj:138）
3. **mariadb 驱动完整支持 Decimal**：
   - set 绑定：`case v: ?Decimal => unwrap(v)`（prepare_statement_client.cj:91）
   - 读：`case v: ?Decimal => result.getDecimal(index)`（query_result.cj:86）
4. **Decimal 是 class（引用类型）**，非值类型

## 改动点

### 1. src/macros/meta.cj — typeNameToStorageType
```cangjie
} else if (tn == "Decimal") { "StorageType.Decimal" }
```
（在 DateTime 分支旁加。避免落 Json 兜底 + M22 warning 误报）

### 2. src/db.cj — dispatchSet
```cangjie
case v: Decimal => stmt.set<Decimal>(index, v)
```
（`import std.math.numeric.Decimal`）

### 3. src/macros/sql_gen.cj — pgCastTypeOf
```cangjie
case "Decimal" => "NUMERIC"
```
（PG 批量 UPDATE 的 CASE 值类型标注，Decimal 参数 toString 绑字符串，需 ::NUMERIC cast 保类型正确——**需验证**：pgsql set<Decimal> 已 toString，col 是 NUMERIC 类型，CASE 表达式可能无需 cast 或需显式；参照其它类型做法）

### 4. rowMapper — 读路径
- 普通 `result.get<Decimal>` 是否可用？pgsql `get<T>` 的 T 推断（probeDecimal: Decimal(0) 已作类型探针，value.cj:234）→ **可用**（驱动已有 Decimal 探针）
- mariadb `get<Decimal>` → getDecimal 路径已支持
- 确认宏生成 `result.get<Decimal>` 无需特殊处理（与 Int64/String 同路径）

### 5. 边界情况
- **`@Field[Text]` 覆盖**：Decimal 字段显式存 Text（字符串）——用户知情，跳过 Decimal 语义，正常 Text 存储
- **Decimal 可空（`Option<Decimal>`）**：本轮**一并支持**（用户决策）——扩展 F4 的 `isNullableScalarType` 判定覆盖 `Option<Decimal>`（归一化匹配 `Option<Decimal>`），dispatchSet 加 `case v: Option<Decimal>`（Some→set<Decimal> / None→setNull），schema nullable 列，rowMapper `getOrNull<Decimal>` 读取
- **查询条件**：`User.col().price > Decimal.parse("10.5")`——Expr.Value(Decimal) 绑定走 dispatchSet Decimal 分支 ✅（需验证 Expr 值传递）

## 测试计划（TDD）

1. **宏测试**：
   - Decimal 字段 schema → `StorageType.Decimal`（非 Json）
   - 无 M22 Json warning（编译期验证）
   - INSERT/UPDATE 绑定 Decimal 值（mock 断言 capturedSetValues 含 Decimal）
2. **dispatchSet 测试**：`case v: Decimal` 绑定（MockStatement.lastSetType）
3. **真实 DB**（PG/MySQL/MariaDB/SQLite）：
   - Decimal 字段 roundtrip：save（Decimal → 存储）→ query 读回（Decimal 精度保留，如 12345.6789）
   - 查询条件 Decimal 比较
4. **回归**：现有 Float 字段不受影响；无 Decimal 字段实体零开销

## 完成定义
- [ ] typeNameToStorageType 映射 Decimal（非 Json）
- [ ] dispatchSet Decimal + Option<Decimal> 分支
- [ ] isNullableScalarType 扩展覆盖 Option<Decimal>（schema nullable、rowMapper getOrNull）
- [ ] pgCastTypeOf Decimal（如需要）
- [ ] 真实 DB roundtrip（四方言，含 Option<Decimal> None/Some）
- [ ] 全量测试通过
- [ ] C8 审计补充 Decimal 端到端记录
