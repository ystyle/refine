# 配置

所有配置类都在 `refine` 包中：

```cangjie
import refine.*
```

## 连接字符串格式

```
sqlite::memory:                         // SQLite 内存数据库
sqlite:/path/to/db.sqlite              // SQLite 文件数据库
mariadb://host:port                     // MariaDB/MySQL
postgresql://host:port/database         // PostgreSQL
```

## DatabaseConfig

```cangjie
let config = DatabaseConfig()
config.driver = "mariadb"
config.dsn = "mariadb://127.0.0.1:3306"
config.user = "root"
config.passwd = "secret"
config.database = Some("myapp")
config.maxPoolSize = 50
config.connectionTimeout = 30
config.idleTimeout = 600
config.maxLifeTime = 1800
let db = config.toDB()
```

## DatabaseRegistry

```cangjie
let cfg = DatabaseConfig()
cfg.driver = "mariadb"
cfg.dsn = "mariadb://127.0.0.1:3306"
cfg.user = "root"
cfg.passwd = "secret"
cfg.database = Some("myapp")

DatabaseRegistry.register("default", cfg)
DatabaseRegistry.initAll()

// 按名获取
let db = DatabaseRegistry.get("default")

// 关闭所有
DatabaseRegistry.closeAll()
```

## DB 连接池

```cangjie
let db = DB.open("sqlite::memory:")
db.maxPoolSize = 20
db.connectionTimeout = 5000  // 毫秒
db.idleTimeout = 60000       // 毫秒
db.maxLifeTime = 3600000     // 毫秒
```
