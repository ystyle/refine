package refine

public struct ColumnDef {
    var name: String
    var storageType: StorageType
    var primaryKey: Bool
    var autoIncrement: Bool
    var nullable: Bool

    public init(name: String, storageType: StorageType, primaryKey: Bool, autoIncrement: Bool, nullable: Bool) {
        this.name = name
        this.storageType = storageType
        this.primaryKey = primaryKey
        this.autoIncrement = autoIncrement
        this.nullable = nullable
    }
}

public struct IndexDef {
    var name: String
    var columns: Array<String>

    public init(name: String, columns: Array<String>) {
        this.name = name
        this.columns = columns
    }
}

public interface TableSchema {
    func tableName(): String
    func columns(): Array<ColumnDef>
    func indexes(): Array<IndexDef>
}

public interface Migrator {
    func autoMigrate(schemas: Array<TableSchema>): Unit
    func createTable(schema: TableSchema): Unit
    func dropTable(schema: TableSchema): Unit
    func hasTable(name: String): Bool
    func addColumn(table: String, col: ColumnDef): Unit
    func addIndex(table: String, idx: IndexDef): Unit
    func dropColumn(table: String, colName: String): Unit
    func alterColumn(table: String, old: ColumnDef, new: ColumnDef): Unit
}
