# Refine

ORM 核心入口。管理数据库连接、事务、会话、钩子。

## 创建实例

```cangjie
// 最简单的形式（SQLite 内存数据库，需 SQLite 驱动，暂缺）
// let rf = Refine.open("sqlite::memory:")

// 带连接参数（MariaDB 示例）
let rf = Refine.open("mariadb://127.0.0.1:3306", [
    ("username", "root"),
    ("password", "secret"),
    ("database", "myapp")
])

// PostgreSQL（需引入 pgsql 驱动，详见配置指南）
let rf = Refine.open("postgres://127.0.0.1:5432", [
    ("username", "postgres"),
    ("password", "secret"),
    ("database", "myapp"),
    ("sslmode", "disable")
])

// 直接构造（用于测试）
let rf = Refine(datasource, dialect, paramOffset)
```

支持的连接形式见 [配置指南 - 连接字符串格式](../guide/configuration.md#连接字符串格式) 与 [PostgreSQL](../guide/configuration.md#postgresql)。

## 方法

### session()

获取一个数据库会话。每次调用从连接池获取一个新连接。可在会话上执行原生 SQL。

```cangjie
let s = rf.session()
let r = s.query("SELECT COUNT(*) FROM users", [])
if (r.next()) { let total = r.get<Int64>(0) }
// 或用自动映射:
let count = s.queryAll("SELECT * FROM users", [], User.rowMapper())
s.close()
```

### transaction()

编程式事务。闭包内所有的 `tx.save/update/delete` 均在同一个事务中。

```cangjie
let result = rf.transaction { tx: Tx =>
    let user = User()
    user.name = "Alice"
    tx.save(user)
    user  // 返回值
}
```

- 闭包正常返回 → `commit()`
- 抛出异常 → `rollback()` + 继续传播异常
- 连接在事务结束后自动 `close()`

#### transaction(level, action)

带隔离级别的事务重载，语义与 `transaction { }` 相同，仅事务开始前额外设置隔离级别：

```cangjie
let result = rf.transaction(IsolationLevel.Serializable) { tx: Tx =>
    tx.save(something)
    42  // 返回值
}
```

- `IsolationLevel` 枚举：`ReadUncommitted` / `ReadCommitted` / `RepeatableRead` / `Serializable`
- 设置通过驱动原生属性生效，MySQL / PostgreSQL 均支持
- SQLite 不支持设置隔离级别，调用抛异常
- 不带隔离级别的 `transaction { }` 保持数据库默认

### hook()

注册生命周期钩子。

```cangjie
rf.hook<User>("User", HookKind.BeforeCreate) { scope: Scope<User> =>
    if (scope.entity.name == "") {
        scope.abort(Exception("name required"))
    }
}
```

### all() / one()

对 `Query<T>` 执行查询，自动设置方言和参数偏移。

```cangjie
let q = User.query().using(rf)
    .filter(User.col().name == "Alice")

// 等价于 q.all()
let users = rf.all(q)

// 等价于 q.one()
let user = rf.one(q)
```

### migrator()

获取对应方言的迁移器实例。

```cangjie
let m = rf.migrator()
m.autoMigrate([UserSchema()])
```

### getDialect()

```cangjie
let dialect = rf.getDialect()
dialect.name()  // "sqlite" / "mysql" / "postgresql"
```

### getParamOffset()

返回参数索引偏移量（MariaDB 为 1，其他为 0）。

### getIdGenerator() / setIdGenerator()

获取或设置 ID 生成器。默认用 Sonyflake 分布式 ID 生成器，可通过接口替换：

```cangjie
let rf = Refine.open("mariadb://127.0.0.1:3306", [("username", "root"), ("password", "secret"), ("database", "myapp")])
let gen = rf.getIdGenerator()
let id = gen.generate()  // "183729475612348416"

// 切换为随机 UUID v4 生成器
rf.setIdGenerator(RandomIdGenerator())
let id2 = rf.getIdGenerator().generate()  // "4a7b2c81-93d6-4e2f-b50a-1c8d3e9f0a2b"

// 切换为 ULID 生成器（26 字符 Crockford Base32，时间有序）
rf.setIdGenerator(UlidIdGenerator())
let id3 = rf.getIdGenerator().generate()  // "01KYVGFGPFCJEZRKBBHJ2Q59QW"
```

内置实现：

| 类 | 说明 |
|---|---|
| `SonyflakeIdGenerator` | 基于 Sonyflake 算法的分布式 ID，64bit 整数转字符串（默认） |
| `RandomIdGenerator` | 随机 UUID v4 格式 ID |
| `UlidIdGenerator` | ULID（Universally Unique Lexicographically Sortable Identifier），26 字符 Crockford Base32，128bit：48 位毫秒时间戳（大端，保证字典序）+ 80 位随机 |

ID 生成时机：

- `String` 主键实体：`Tx.save` / `Tx.batchSave` 时 id 为空则自动调用生成器，并回写实体
- `Int64` 主键实体（`@Id[auto, false]` 关闭自增）：id 为 0 时自动调用生成器（`generate()` 结果经 `Int64.parse` 转换），并回写实体——适合用 Sonyflake 等趋势递增 ID 替代数据库自增（批量插入无需回写，无连续 id 假设）

实现自定义：

```cangjie
class MyIdGen <: IdGenerator {
    public func generate(): String {
        // 返回唯一 ID 字符串
    }
}
rf.setIdGenerator(MyIdGen())
```

### close()

关闭数据源连接池。

```cangjie
rf.close()
```

## 工具函数

```cangjie
// 从 URL 提取驱动名
extractDriver("mariadb://host:3306/db")  // "mariadb"

// 从驱动名检测方言
detectDialect("mysql").name()  // "mysql"
detectDialect("sqlite").name() // "sqlite"
detectDialect("postgres").name() // "postgresql"
```

## 支持的数据源

| 驱动名（URL 前缀） | 方言 | 驱动来源 |
|---|---|---|
| `sqlite` | SQLite | ⚠️ 方言渲染已实现，真实驱动暂缺（未接入） |
| `mariadb` / `mysql` | MySQL | `mariadb` 驱动（git 依赖） |
| `postgres` / `postgresql` | PostgreSQL | `pgsql` 驱动（git 依赖） |

PostgreSQL 连接示例见 [配置指南 - PostgreSQL](../guide/configuration.md#postgresql)。
