# 第二批 CRUD 增强设计：乐观锁 + 审计字段 + 事务隔离级别

日期：2026-08-01
分支：feature/batch2

## 背景

第一批 CRUD 增强（聚合/分页/条件批量更新删除/悲观锁）已完成并合并。本批为第二批复核：乐观锁 `@Version`、审计字段 `created_at`/`updated_at`、事务隔离级别。

## 1. 审计字段（自动识别）

### 识别规则

实体声明 `created_at: DateTime` / `updated_at: DateTime` 字段即自动启用，与软删除 `deleted_at` 的字段名约定一致，零配置。

### 时间注入

- 时间值由 ORM 在客户端生成（`DateTime.now()`），跨方言一致、钩子可观测
- **save**：`created_at` 与 `updated_at` 均注入 `DateTime.now()`（仅首次）
- **update**：只刷新 `updated_at`，`created_at` 保持不变
- **batchSave**：每个实体独立注入
- **batchUpdate**：每个实体刷新 `updated_at`
- **upsert**：插入时填 created_at/updated_at；冲突更新时刷新 updated_at

### 钩子顺序

注入发生在 `TxBeforeCreate` / `TxBeforeUpdate` 钩子**之前**，钩子中可见已填好的值。

### 不处理场景

`updateWhere` / `deleteWhere` 无实体映射层，不自动填充，文档标注由用户自行处理。

## 2. 乐观锁 @Version

### 注解

新增 `@Version` 属性宏，显式标记实体的 `version: Int64` 字段。不采用字段名约定，显式标注更安全（避免与普通业务 `version` 字段混淆）。

### 语义

- **tx.update**：SQL 的 WHERE 追加 `AND version = ?`，参数为实体当前 `version`；执行后 `rowCount == 0` 抛 `OptimisticLockException`；成功则实体 `version` 自动 +1
- **tx.batchUpdate**：逐行 CASE WHEN 的 WHERE 追加 `AND version = ?`，行级校验，失败行抛异常
- **tx.save / tx.upsert**：首次插入时若 `version == 0` 自动置为 1
- **tx.delete**：不参与 version 校验（物理/软删除走主键）
- **不处理**：`updateWhere` / `deleteWhere`

### 异常

新增 `OptimisticLockException`，继承 `RefineException`（含实体类型名、主键、期望版本、实际版本上下文信息）。

## 3. 事务隔离级别

### API

```cangjie
rf.transaction(IsolationLevel.Serializable) { tx: Tx =>
    ...
}
```

`IsolationLevel` 新枚举：`ReadUncommitted` / `ReadCommitted` / `RepeatableRead` / `Serializable`。

- 默认 `transaction { }` 不带隔离级别，行为不变（保持数据库默认）
- 带级别时在 begin 前执行 `SET TRANSACTION ISOLATION LEVEL <X>`
- SQLite 不支持隔离级别设置，调用时抛异常

### 方言

Dialect 接口新增 `isolationSQL(level): String`。MySQL / PostgreSQL 使用标准 `SET TRANSACTION ISOLATION LEVEL` 语法。

## 4. 宏改造点

- `FieldInfo` 增加 `isVersion` 标记；增加审计字段识别（created_at/updated_at 类型为 DateTime）
- `extractFields` / `applyIdAnnotations` 之后新增 `applyAuditVersion` 检测步骤
- `buildUpdateSQLString` 在有 version 字段时追加 `AND version = ?`
- `buildTxUpdateExtend`：注入 updated_at、追加 version 条件与 rowCount 校验、version+1、抛 `OptimisticLockException`
- `buildTxSaveExtend` / `buildTxUpsertExtend` / `buildTxBatchSaveExtend` / `buildTxBatchUpdateExtend`：注入审计字段、version 初始化/递增
- `error.cj`：新增 `OptimisticLockException`
- `db.cj`：新增 `IsolationLevel` 枚举、`transaction(level)` 重载
- `dialect*.cj`：新增 `isolationSQL` 实现

## 5. 测试策略

### 单元测试（src/ 下）

- 宏展开：`@Version` 字段被识别、SQL 追加 `AND version = ?`
- 方言渲染：isolationSQL 各方言输出
- 异常层次：`OptimisticLockException` 继承关系与上下文

### 双库集成测试（example/）

- 审计字段：save 后 created_at/updated_at 非空、update 后 updated_at 变化 created_at 不变
- 乐观锁：正常 update 后 version+1；并发模拟冲突（直接改 DB 版本号）抛 `OptimisticLockException`
- 隔离级别：transaction 带级别执行不报错，SQL 日志包含 SET 语句（PG 级别可查 current_setting 验证）
- batchSave/batchUpdate 的审计与 version 行为

## 6. 边界与约定

- 审计字段为必填约定：声明 created_at/updated_at 后不允许手动覆盖为 NULL（插入时 ORM 强制注入）
- `@Version` 字段仅支持 Int64；其他类型宏报错
- version 自动递增从 1 开始；支持用户预置任意初值（如从 100 开始），save 时仅当 0 才置 1
- 软删除与乐观锁可共存：软删除表的 update SQL 不包含 deleted_at 过滤（由 query() 的自动过滤覆盖读侧）
