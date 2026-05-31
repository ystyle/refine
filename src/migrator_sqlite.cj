package refine

import std.collection.ArrayList

public class SQLiteMigrator <: Migrator {
    private var db: DB

    public init(db: DB) {
        this.db = db
    }

    public static func dataTypeOf(st: StorageType): String {
        SQLiteDialect().dataTypeOf(st)
    }

    public static func columnDefSQL(col: ColumnDef): String {
        var parts = ArrayList<String>()
        parts.add("\"" + col.name + "\"")
        parts.add(dataTypeOf(col.storageType))
        if (col.primaryKey) { parts.add("PRIMARY KEY") }
        if (col.autoIncrement) { parts.add("AUTOINCREMENT") }
        if (col.nullable) { parts.add("NULL") }
        else { parts.add("NOT NULL") }
        String.join(parts.toArray(), delimiter: " ")
    }

    public static func createTableSQL(schema: TableSchema): String {
        var colDefs = ArrayList<String>()
        for (col in schema.columns()) { colDefs.add(columnDefSQL(col)) }
        var parts = ArrayList<String>()
        parts.add("CREATE TABLE IF NOT EXISTS \"" + schema.tableName() + "\" (")
        parts.add(String.join(colDefs.toArray(), delimiter: ", "))
        parts.add(")")
        String.join(parts.toArray(), delimiter: "")
    }

    public static func addColumnSQL(table: String, col: ColumnDef): String {
        "ALTER TABLE \"" + table + "\" ADD COLUMN " + columnDefSQL(col)
    }

    public static func addIndexSQL(table: String, idx: IndexDef): String {
        var colParts = ArrayList<String>()
        for (c in idx.columns) { colParts.add("\"" + c + "\"") }
        "CREATE INDEX IF NOT EXISTS \"" + idx.name + "\" ON \"" + table + "\" (" + String.join(colParts.toArray(), delimiter: ", ") + ")"
    }

    public static func hasTableSQL(): String { "SELECT name FROM sqlite_master WHERE type='table' AND name=?" }

    public static func dropTableSQL(schema: TableSchema): String { "DROP TABLE IF EXISTS \"" + schema.tableName() + "\"" }

    public static func dropColumnSQL(table: String, colName: String): String { "ALTER TABLE \"" + table + "\" DROP COLUMN \"" + colName + "\"" }

    public func createTable(schema: TableSchema): Unit { let s = db.session(); s.execute(createTableSQL(schema), []); s.close() }
    public func dropTable(schema: TableSchema): Unit { let s = db.session(); s.execute(dropTableSQL(schema), []); s.close() }
    public func hasTable(name: String): Bool { let s = db.session(); let r = s.query(hasTableSQL(), [name]); let e = r.next(); s.close(); e }
    public func addColumn(table: String, col: ColumnDef): Unit { let s = db.session(); s.execute(addColumnSQL(table, col), []); s.close() }
    public func addIndex(table: String, idx: IndexDef): Unit { let s = db.session(); s.execute(addIndexSQL(table, idx), []); s.close() }
    public func dropColumn(table: String, colName: String): Unit { let s = db.session(); s.execute(dropColumnSQL(table, colName), []); s.close() }

    public func alterColumn(_table: String, _old: ColumnDef, _new: ColumnDef): Unit {
        throw Exception("SQLite does not support ALTER COLUMN")
    }

    public func autoMigrate(schemas: Array<TableSchema>): Unit {
        for (schema in schemas) {
            let tableName = schema.tableName()
            if (!hasTable(tableName)) { createTable(schema); continue }
            let existingCols = getExistingColumnNames(tableName)
            for (col in schema.columns()) {
                if (!containsString(existingCols, col.name)) { addColumn(tableName, col) }
            }
            let existingIdxs = getExistingIndexNames(tableName)
            for (idx in schema.indexes()) {
                if (!containsString(existingIdxs, idx.name)) { addIndex(tableName, idx) }
            }
        }
    }

    private func getExistingColumnNames(tableName: String): ArrayList<String> {
        let s = db.session()
        let r = s.query("PRAGMA table_info(\"" + tableName + "\")", [])
        var names = ArrayList<String>()
        while (r.next()) { names.add(r.get<String>(1)) }
        s.close()
        names
    }

    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let s = db.session()
        let r = s.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?", [tableName])
        var names = ArrayList<String>()
        while (r.next()) { names.add(r.get<String>(0)) }
        s.close()
        names
    }

    private static func containsString(list: ArrayList<String>, target: String): Bool {
        for (s in list) { if (s == target) { return true } }
        false
    }
}
