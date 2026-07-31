package refine

import std.collection.ArrayList

public class PostgreSQLMigrator <: Migrator {
    private var db: DB
    private var dialect: PostgreSQLDialect

    public init(db: DB) {
        this.db = db
        this.dialect = PostgreSQLDialect()
    }

    public static func columnDefSQL(col: ColumnDef, d: PostgreSQLDialect): String {
        var parts = ArrayList<String>()
        parts.add("\"" + col.name.toAsciiLower() + "\"")
        if (col.primaryKey && col.autoIncrement) {
            parts.add("BIGSERIAL PRIMARY KEY")
        } else {
            parts.add(d.dataTypeOf(col.storageType))
            if (col.primaryKey) { parts.add("PRIMARY KEY") }
            if (!col.nullable && !col.primaryKey) { parts.add("NOT NULL") }
        }
        String.join(parts.toArray(), delimiter: " ")
    }

    public static func createTableSQL(schema: TableSchema, d: PostgreSQLDialect): String {
        var colDefs = ArrayList<String>()
        for (col in schema.columns()) { colDefs.add(columnDefSQL(col, d)) }
        "CREATE TABLE IF NOT EXISTS \"" + schema.tableName().toAsciiLower() + "\" (" + String.join(colDefs.toArray(), delimiter: ", ") + ")"
    }

    public func createTable(schema: TableSchema): Unit { let s = db.session(); s.execute(createTableSQL(schema, dialect), []); s.close() }
    public func dropTable(schema: TableSchema): Unit { let s = db.session(); s.execute("DROP TABLE IF EXISTS \"" + schema.tableName().toAsciiLower() + "\"", []); s.close() }

    public func hasTable(name: String): Bool {
        let s = db.session()
        let r = s.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = ?", [name.toAsciiLower()])
        let exists = r.next() && r.get<Int64>(0) > 0
        s.close()
        exists
    }

    public func addColumn(table: String, col: ColumnDef): Unit {
        let s = db.session()
        s.execute("ALTER TABLE \"" + table.toAsciiLower() + "\" ADD COLUMN " + columnDefSQL(col, dialect), [])
        s.close()
    }

    public func addIndex(table: String, idx: IndexDef): Unit {
        var colParts = ArrayList<String>()
        for (c in idx.columns) { colParts.add("\"" + c.toAsciiLower() + "\"") }
        let s = db.session()
        s.execute("CREATE INDEX IF NOT EXISTS \"" + idx.name + "\" ON \"" + table + "\" (" + String.join(colParts.toArray(), delimiter: ", ") + ")", [])
        s.close()
    }

    public func dropColumn(table: String, colName: String): Unit {
        let s = db.session()
        s.execute("ALTER TABLE \"" + table.toAsciiLower() + "\" DROP COLUMN IF EXISTS \"" + colName.toAsciiLower() + "\"", [])
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
                if (!existingCols.contains(col.name)) { addColumn(tableName, col) }
            }
            let existingIdxs = getExistingIndexNames(tableName)
            for (idx in schema.indexes()) {
                if (!existingIdxs.contains(idx.name)) { addIndex(tableName, idx) }
            }
        }
    }

    private func getExistingColumnNames(tableName: String): ArrayList<String> {
        let s = db.session()
        let r = s.query("SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ?", [tableName.toAsciiLower()])
        var names = ArrayList<String>()
        while (r.next()) { names.add(r.get<String>(0)) }
        s.close()
        names
    }

    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let s = db.session()
        let r = s.query("SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename = ?", [tableName.toAsciiLower()])
        var names = ArrayList<String>()
        while (r.next()) { names.add(r.get<String>(0)) }
        s.close()
        names
    }

}
