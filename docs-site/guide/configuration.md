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
postgres://host:port                    // PostgreSQL（驱动名 postgres / postgresql）
```

## MySQL / MariaDB

MySQL 支持需要引入驱动依赖（实现 `std.database.sql` 接口）：

```toml
[dependencies]
mariadb = { git = "https://gitcode.com/Cangjie-SIG/mariadb-driver.git", branch = "master" }
```

连接示例：

```cangjie
let rf = Refine.open("mariadb://127.0.0.1:3306", [
    ("username", "root"),
    ("password", "secret"),
    ("database", "myapp")
])
```

支持的连接选项：

| 选项 | 说明 |
|---|---|
| `username` / `password` | 认证 |
| `database` | 数据库名 |

> **注意**：MySQL 驱动参数/列索引为 1 起始，Refine 已自动适配（`paramOffset = 1`），无需额外配置。表名大小写行为取决于 MySQL 服务器的 `lower_case_table_names` 设置，建议使用小写表名。

## PostgreSQL

PostgreSQL 支持需要引入驱动依赖（纯仓颉实现，实现 `std.database.sql` 接口）：

```toml
[dependencies]
pgsql = { git = "https://atomgit.com/aibrary/pgsql-driver.git", branch = "main" }
```

连接示例：

```cangjie
let rf = Refine.open("postgres://127.0.0.1:5432", [
    ("username", "postgres"),
    ("password", "secret"),
    ("database", "myapp"),
    ("sslmode", "disable")   // 驱动当前不支持 SSL，需显式禁用
])
```

支持的连接选项：

| 选项 | 说明 |
|---|---|
| `username` / `password` | 认证（支持 SCRAM-SHA-256 / MD5 / 明文） |
| `database` | 数据库名 |
| `sslmode` | `disable`（默认不强制；`required`/`verify_ca`/`verify_full` 当前不支持） |

> **注意**：PostgreSQL 将未加引号的标识符折叠为小写。Refine 在 PostgreSQL 下统一按小写标识符处理（查询、建表、CRUD 一致），实体类名/字段名中的大写字母会映射为小写表名/列名。若表名是 PostgreSQL 保留字（如 `user`、`order`），需用 `@Table` 指定其他表名，参见 [实体定义 - 自定义表名](../guide/entities.md)。

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
