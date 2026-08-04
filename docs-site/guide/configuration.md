# 配置

所有配置类都在 `refine` 包中：

```cangjie
import refine.*
```

## 连接字符串格式

```
mariadb://host:port                     // MariaDB/MySQL
// SQLite: 方言渲染已实现，真实驱动暂缺，暂不可用
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

`DatabaseConfig` 提供连接池参数配置。ORM 场景用 `toRefine()` 获取完整的 `Refine` 实例（自动探测方言与参数偏移）；纯连接层场景用 `toDB()` 获取 `DB`（无方言，仅 datasource + 参数偏移 + 连接池）。

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

// ORM 场景：返回 Refine（持有方言、连接池、hook 注册表）
let rf = config.toRefine()
```

> **注意**：`DatabaseRegistry` 已在 0.6.0 移除——它是设计文档未定义的全局状态且无生产使用。多数据库实例请直接创建多个 `Refine` / `DatabaseConfig` 实例，实例间天然隔离。

## DB 连接池

`DB` 是纯连接层（datasource + 参数偏移 + 连接池），不含方言与 ORM 能力。ORM 查询请用 `Refine`；`DB` 仅用于手写 SQL。

```cangjie
let db = DB.open("mariadb://127.0.0.1:3306")
db.maxPoolSize = 20
db.connectionTimeout = 5000  // 毫秒
db.idleTimeout = 60000       // 毫秒
db.maxLifeTime = 3600000     // 毫秒
```
