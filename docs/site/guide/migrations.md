# 数据迁移

## 自动迁移

`Migrator.autoMigrate()` 检查表是否存在，不存在则创建，存在但缺少列则添加列：

```cangjie
rf.migrator().autoMigrate([
    UserSchema(),
    PostSchema(),
    CommentSchema(),
    TagSchema()
])
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
| 标识符引用 | `"name"` | `` `name` `` | `"name"` |
| 自增 | `AUTOINCREMENT` | `AUTO_INCREMENT` | — |
| upsert | 不支持 | `ON DUPLICATE KEY UPDATE` | `ON CONFLICT DO UPDATE SET` |
| JSON | 不支持 | `JSON` | `JSONB` |
| RETURNING | 不支持 | 不支持 | 支持 |
