package refine

import std.collection.ArrayList

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

public class SQLiteMigrator <: Migrator {
    private var db: DB

    public init(db: DB) {
        this.db = db
    }

    // === SQL generation (testable without DB) ===

    public static func dataTypeOf(st: StorageType): String {
        match (st) {
            case Integer => "INTEGER"
            case Float => "REAL"
            case Decimal => "NUMERIC"
            case `Bool` => "INTEGER"
            case String => "TEXT"
            case Text => "TEXT"
            case Json => "TEXT"
            case Bytes => "BLOB"
            case Timestamp => "TEXT"
        }
    }

    public static func columnDefSQL(col: ColumnDef): String {
        var parts = ArrayList<String>()
        parts.add("\"" + col.name + "\"")
        parts.add(dataTypeOf(col.storageType))
        if (col.primaryKey) {
            parts.add("PRIMARY KEY")
        }
        if (col.autoIncrement) {
            parts.add("AUTOINCREMENT")
        }
        if (col.nullable) {
            parts.add("NULL")
        } else {
            parts.add("NOT NULL")
        }
        joinArrayList(parts, " ")
    }

    public static func createTableSQL(schema: TableSchema): String {
        var colDefs = ArrayList<String>()
        for (col in schema.columns()) {
            colDefs.add(columnDefSQL(col))
        }
        var parts = ArrayList<String>()
        parts.add("CREATE TABLE IF NOT EXISTS \"" + schema.tableName() + "\" (")
        parts.add(joinArrayList(colDefs, ", "))
        parts.add(")")
        joinArrayList(parts, "")
    }

    public static func addColumnSQL(table: String, col: ColumnDef): String {
        "ALTER TABLE \"" + table + "\" ADD COLUMN " + columnDefSQL(col)
    }

    public static func addIndexSQL(table: String, idx: IndexDef): String {
        var colParts = ArrayList<String>()
        for (c in idx.columns) {
            colParts.add("\"" + c + "\"")
        }
        "CREATE INDEX IF NOT EXISTS \"" + idx.name + "\" ON \"" + table + "\" (" + joinArrayList(colParts, ", ") + ")"
    }

    public static func hasTableSQL(): String {
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
    }

    public static func dropTableSQL(schema: TableSchema): String {
        "DROP TABLE IF EXISTS \"" + schema.tableName() + "\""
    }

    public static func dropColumnSQL(table: String, colName: String): String {
        "ALTER TABLE \"" + table + "\" DROP COLUMN \"" + colName + "\""
    }

    // === Migrator interface ===

    public func createTable(schema: TableSchema): Unit {
        let session = db.session()
        session.execute(SQLiteMigrator.createTableSQL(schema), [])
        session.close()
    }

    public func dropTable(schema: TableSchema): Unit {
        let session = db.session()
        session.execute(SQLiteMigrator.dropTableSQL(schema), [])
        session.close()
    }

    public func hasTable(name: String): Bool {
        let session = db.session()
        let result = session.query(SQLiteMigrator.hasTableSQL(), [name])
        let exists = result.next()
        session.close()
        exists
    }

    public func addColumn(table: String, col: ColumnDef): Unit {
        let session = db.session()
        session.execute(SQLiteMigrator.addColumnSQL(table, col), [])
        session.close()
    }

    public func addIndex(table: String, idx: IndexDef): Unit {
        let session = db.session()
        session.execute(SQLiteMigrator.addIndexSQL(table, idx), [])
        session.close()
    }

    public func dropColumn(table: String, colName: String): Unit {
        let session = db.session()
        session.execute(SQLiteMigrator.dropColumnSQL(table, colName), [])
        session.close()
    }

    public func alterColumn(_table: String, _old: ColumnDef, _new: ColumnDef): Unit {
        throw Exception("SQLite does not support ALTER COLUMN. Use recreateTable() or manual migration.")
    }

    public func autoMigrate(schemas: Array<TableSchema>): Unit {
        for (schema in schemas) {
            let tableName = schema.tableName()
            if (!hasTable(tableName)) {
                createTable(schema)
                continue
            }
            let existingCols = getExistingColumnNames(tableName)
            for (col in schema.columns()) {
                if (!containsString(existingCols, col.name)) {
                    addColumn(tableName, col)
                }
            }
            let existingIdxs = getExistingIndexNames(tableName)
            for (idx in schema.indexes()) {
                if (!containsString(existingIdxs, idx.name)) {
                    addIndex(tableName, idx)
                }
            }
        }
    }

    private func getExistingColumnNames(tableName: String): ArrayList<String> {
        let session = db.session()
        let result = session.query("PRAGMA table_info(\"" + tableName + "\")", [])
        var names = ArrayList<String>()
        while (result.next()) {
            let name = result.get<String>(1)
            names.add(name)
        }
        session.close()
        names
    }

    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let session = db.session()
        let result = session.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?", [tableName])
        var names = ArrayList<String>()
        while (result.next()) {
            let name = result.get<String>(0)
            names.add(name)
        }
        session.close()
        names
    }

    private static func containsString(list: ArrayList<String>, target: String): Bool {
        for (s in list) {
            if (s == target) { return true }
        }
        false
    }

    private static func joinArrayList(strings: ArrayList<String>, separator: String): String {
        var result = ""
        var first = true
        for (s in strings) {
            if (first) {
                result = s
                first = false
            } else {
                result = result + separator + s
            }
        }
        result
    }
}
