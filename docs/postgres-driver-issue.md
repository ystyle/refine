# OpenGauss Driver 与标准 PostgreSQL 兼容性问题

## 问题 1：NOTICE 消息导致 DataModelException

**描述**：执行 DDL 语句（`CREATE TABLE`、`DROP TABLE`）时，PostgreSQL 返回 NOTICE 消息，驱动在解析时抛出 `DataModelException: This data is not String.`

**堆栈**：
```
DataModelException: This data is not String.
  at NoticeResponse::serialize()
  at NoticeResponse::toString()
  at ResultReader::readUntilRowDescription()
  at PgConn::execExtendedSuffix()
  at PgConn::execPrepared()
  at Stmt::update()
```

**复现步骤**：
```cangjie
let stmt = conn.prepareStatement("DROP TABLE IF EXISTS test")
stmt.update()  // 抛出 DataModelException
```

**根因**：`NoticeResponse` 的 `serialize()` 或 `toString()` 方法在解析 PostgreSQL NOTICE 字段时，遇到了非 String 类型的数据（可能是 HashMap 或其他类型），导致序列化失败。

**影响**：所有 DDL 操作无法通过 stmt.update() 执行。只有 SELECT 查询和带 RETURNING 的 INSERT 可正常工作。

## 问题 2：认证协议兼容性

**描述**：使用 `DriverManager.getDriver("opengauss")` 连接标准 PostgreSQL 时，驱动使用 OpenGauss 专用认证协议（RFC5802），标准 PostgreSQL 17 使用 SCRAM-SHA-256，导致认证失败。

**临时方案**：改用 `DriverManager.getDriver("postgres")` 连接，此时驱动使用标准 PostgreSQL 认证协议。

## 环境信息

- PostgreSQL: 17.0 (Alpine)
- OpenGauss Driver: gitcode.com/Cangjie-TPC/opengauss-driver.git
- Cangjie: 1.1.0
