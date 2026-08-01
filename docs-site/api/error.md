# Error

## 异常层次

```
Exception
 └── RefineException
      ├── ConnectionException    // 数据库连接/驱动错误
      ├── QueryException         // 查询构建/执行错误
      ├── MappingException       // 结果映射错误
      ├── MigrationException     // 迁移操作错误
      ├── ConfigException        // 配置错误
      ├── HookException          // 钩子执行错误
      └── OptimisticLockException // 乐观锁版本冲突
```

## 捕获

```cangjie
import refine.*

try {
    let users = User.query().using(rf).all()
} catch (e: QueryException) {
    // 查询相关错误
} catch (e: ConnectionException) {
    // 连接相关错误
} catch (e: RefineException) {
    // 其他 Refine 错误
}
```

## 常见异常

| 异常 | 触发条件 |
|---|---|
| `QueryException` | Query 未设置 mapper、未设置 executor、SQL 执行失败 |
| `ConnectionException` | 驱动未找到、连接失败 |
| `MigrationException` | 迁移操作错误（如 SQLite 上调用 alterColumn） |
| `HookException` | 钩子函数内部异常 |
| `ConfigException` | 数据库配置未找到 |
| `OptimisticLockException` | 乐观锁版本冲突（`@Version` 实体的 update/batchUpdate 版本不匹配） |

## OptimisticLockException

`@Version` 实体的 `Tx.update` / `Tx.batchUpdate` 版本校验失败时抛出，携带冲突细节：

| 字段 | 类型 | 说明 |
|---|---|---|
| `entityType` | `String` | 实体类型名 |
| `pk` | `String` | 主键值（复合主键以 `:` 拼接） |
| `expected` | `Int64` | 期望的版本号（实体携带） |
| `actual` | `Int64` | 数据库中的实际版本号（行不存在时为 -1） |

> `batchUpdate` 匹配行数不足时也会抛出，此时 `pk` 为 `"batch"`、`expected` 为 0、`actual` 为 -1。
