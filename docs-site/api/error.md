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
      └── HookException          // 钩子执行错误
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
| `MigrationException` | ALTER COLUMN 在不支持该操作的方言上调用 |
| `HookException` | 钩子函数内部异常 |
| `ConfigException` | 数据库配置未找到 |
