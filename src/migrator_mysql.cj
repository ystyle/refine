package refine

import std.collection.ArrayList

public class MySQLMigrator <: Migrator {
    private var db: DB
    private var dialect: MySQLDialect

    public init(db: DB) {
        this.db = db
        this.dialect = MySQLDialect()
    }

    public static func columnDefSQL(col: ColumnDef, d: MySQLDialect): String {
        var parts = ArrayList<String>()
        parts.add("`" + col.name + "`")
        parts.add(d.dataTypeOf(col.storageType))
        if (col.primaryKey && col.autoIncrement) { parts.add("AUTO_INCREMENT PRIMARY KEY") }
        else if (col.primaryKey) { parts.add("PRIMARY KEY") }
        if (!col.nullable && !col.primaryKey) { parts.add("NOT NULL") }
        String.join(parts.toArray(), delimiter: " ")
    }

    public static func createTableSQL(schema: TableSchema, d: MySQLDialect): String {
        var colDefs = ArrayList<String>()
        for (col in schema.columns()) { colDefs.add(columnDefSQL(col, d)) }
        "CREATE TABLE IF NOT EXISTS `" + schema.tableName() + "` (" + String.join(colDefs.toArray(), delimiter: ", ") + ")"
    }

    public func createTable(schema: TableSchema): Unit { let s = db.session(); s.execute(createTableSQL(schema, dialect), []); s.close() }
    public func dropTable(schema: TableSchema): Unit { let s = db.session(); s.execute("DROP TABLE IF EXISTS `" + schema.tableName() + "`", []); s.close() }

    public func hasTable(name: String): Bool {
        let s = db.session()
        let r = s.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?", [name])
        let exists = r.next() && r.get<Int64>(1) > 0
        s.close()
        exists
    }

    public func addColumn(table: String, col: ColumnDef): Unit {
        let s = db.session()
        s.execute("ALTER TABLE `" + table + "` ADD COLUMN " + columnDefSQL(col, dialect), [])
        s.close()
    }

    public func addIndex(table: String, idx: IndexDef): Unit {
        var colParts = ArrayList<String>()
        for (c in idx.columns) { colParts.add("`" + c + "`") }
        let s = db.session()
        s.execute("CREATE INDEX `" + idx.name + "` ON `" + table + "` (" + String.join(colParts.toArray(), delimiter: ", ") + ")", [])
        s.close()
    }

    public func dropColumn(table: String, colName: String): Unit {
        let s = db.session()
        s.execute("ALTER TABLE `" + table + "` DROP COLUMN `" + colName + "`", [])
        s.close()
    }

    public func alterColumn(_table: String, _old: ColumnDef, _new: ColumnDef): Unit {
        throw Exception("ALTER COLUMN not supported. Use manual migration.")
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
        let r = s.query("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ?", [tableName])
        var names = ArrayList<String>()
        while (r.next()) { names.add(r.get<String>(1)) }
        s.close()
        names
    }

    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let s = db.session()
        let r = s.query("SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE table_schema = DATABASE() AND table_name = ?", [tableName])
        var names = ArrayList<String>()
        while (r.next()) { names.add(r.get<String>(1)) }
        s.close()
        names
    }

    private static func containsString(list: ArrayList<String>, target: String): Bool {
        for (s in list) { if (s == target) { return true } }
        false
    }
}
