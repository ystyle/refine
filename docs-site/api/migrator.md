# Migrator

## 接口

```cangjie
interface Migrator {
    func autoMigrate(schemas: Array<TableSchema>)
    func createTable(schema: TableSchema)
    func dropTable(schema: TableSchema)
    func hasTable(name: String): Bool
    func addColumn(table: String, col: ColumnDef)
    func addIndex(table: String, idx: IndexDef)
    func dropColumn(table: String, colName: String)
    func alterColumn(table: String, old: ColumnDef, new: ColumnDef)
}
```

## 数据结构

```cangjie
struct ColumnDef {
    var name: String
    var storageType: StorageType
    var primaryKey: Bool
    var autoIncrement: Bool
    var nullable: Bool
}

struct IndexDef {
    var name: String
    var columns: Array<String>
}

interface TableSchema {
    func tableName(): String
    func columns(): Array<ColumnDef>
    func indexes(): Array<IndexDef>
}
```

## 实现

### SQLiteMigrator

```cangjie
class SQLiteMigrator <: Migrator
```

静态 SQL 生成方法：

```cangjie
SQLiteMigrator.columnDefSQL(col)          // '"name" TEXT NOT NULL'
SQLiteMigrator.createTableSQL(schema)     // 'CREATE TABLE IF NOT EXISTS ...'
SQLiteMigrator.addColumnSQL(table, col)
SQLiteMigrator.addIndexSQL(table, idx)
SQLiteMigrator.hasTableSQL()
SQLiteMigrator.dropTableSQL(schema)
SQLiteMigrator.dropColumnSQL(table, colName)
```

### MySQLMigrator

```cangjie
class MySQLMigrator <: Migrator
```

静态 SQL 生成方法（需传入 `MySQLDialect` 实例）：

```cangjie
MySQLMigrator.columnDefSQL(col, dialect)     // '`col_name` VARCHAR(255) NOT NULL'
MySQLMigrator.createTableSQL(schema, dialect)
```

## 实现自定义迁移器

```cangjie
class MyMigrator <: Migrator {
    // 实现所有方法
}
```
