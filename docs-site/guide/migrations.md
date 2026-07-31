# 数据迁移

## 自动迁移

`Migrator.autoMigrate()` 对比实体 Schema 与数据库现状，自动同步表结构：

- 表不存在 → `CREATE TABLE`
- 表存在但缺列 → `ADD COLUMN`
- 表存在且列类型 / NULL 约束变化 → `ALTER COLUMN`（MySQL `MODIFY COLUMN` / PostgreSQL `ALTER COLUMN TYPE` + `SET/DROP NOT NULL`；SQLite 不支持列变更）

```cangjie
rf.migrator().autoMigrate([
    UserSchema(),
    PostSchema(),
    CommentSchema(),
    TagSchema()
])
```

> **注意**：主键 / 自增 / 索引定义的变化不会自动迁移（避免危险操作），需手动处理。

### 多对多中间表

如果实体有 `@Ref[Target, via: ...]` 关联，宏会自动生成对应的 junction 表 Schema。
使用 `Entity.schemas()` 一次性获取主表 + 所有关联的中间表：

```cangjie
rf.migrator().autoMigrate(Post.schemas())
// 等价于: autoMigrate([PostSchema(), Post_TagsJunctionSchema()])
```

## 手动创建表

```cangjie
let m = rf.migrator()
m.createTable(UserSchema())
```

## 检查表是否存在

```cangjie
m.hasTable("users")  // Bool
```

## 删除表

```cangjie
m.dropTable(UserSchema())
// 生成: DROP TABLE IF EXISTS users
```

## 添加列

```cangjie
m.addColumn("users", ColumnDef("email", StorageType.String, false, false, true))
```

## 添加索引

```cangjie
m.addIndex("users", IndexDef("idx_users_email", ["email"]))
```

## Schema 定义

宏为每个 `@Refine` 类生成 `*Schema` 类，实现 `TableSchema` 接口：

```cangjie
interface TableSchema {
    func tableName(): String
    func columns(): Array<ColumnDef>     // name, storageType, primaryKey, autoIncrement, nullable
    func indexes(): Array<IndexDef>      // name, columns
}
```

也可以手动实现：

```cangjie
class MySchema <: TableSchema {
    public func tableName(): String { "my_table" }
    public func columns(): Array<ColumnDef> {
        [ColumnDef("id", StorageType.Integer, true, true, false)]
    }
    public func indexes(): Array<IndexDef> { [] }
}
```

## 方言差异

| 操作 | SQLite | MySQL | PostgreSQL |
|---|---|---|---|
| 标识符引用 | `"name"` | `` `name` `` | `"name"`（小写化） |
| 自增主键 | `INTEGER PRIMARY KEY AUTOINCREMENT` | `AUTO_INCREMENT` | `BIGSERIAL PRIMARY KEY` |
| 列变更 (alterColumn) | 不支持 | `MODIFY COLUMN` | `ALTER COLUMN TYPE` |
| upsert | 不支持 | `ON DUPLICATE KEY UPDATE` | `ON CONFLICT DO UPDATE SET` |
| JSON | 不支持 | `JSON` | `JSONB` |
| RETURNING | 不支持 | 不支持 | 支持 |

### PostgreSQL 自增主键回写

PostgreSQL 无 `lastInsertId`（驱动恒返回 0），Refine 在 `Tx.save` 时自动检测方言的 `hasReturningSupport()`，改用 `INSERT ... RETURNING id` 回读并写回实体：

```cangjie
rf.transaction { tx: Tx =>
    let u = User()
    u.name = "Alice"
    tx.save(u)
    // PostgreSQL: INSERT INTO users (name, email) VALUES (?, ?) RETURNING id
    // u.id 已填充
}
```

批量插入（`batchSave`）在自增主键下不回写 id（与 MySQL 一致）；String 主键（UUID/ULID）预生成后批量插入并回写。
