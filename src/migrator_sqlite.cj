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

    // I5: SQLite 对非空表 ADD COLUMN NOT NULL 列必须带 DEFAULT，否则 ALTER 失败（设计 §11.3
    // "已有行使用 DEFAULT 或 NULL"）。主键/自增列排除（主键列不允许普通默认值）。
    public static func addColumnSQL(table: String, col: ColumnDef): String {
        var sql = "ALTER TABLE \"" + table + "\" ADD COLUMN " + columnDefSQL(col)
        if (!col.nullable && !col.primaryKey && !col.autoIncrement) {
            sql += " DEFAULT " + SQLiteDialect().defaultValueOf(col.storageType)
        }
        sql
    }

    public static func addIndexSQL(table: String, idx: IndexDef): String {
        var colParts = ArrayList<String>()
        for (c in idx.columns) { colParts.add("\"" + c + "\"") }
        "CREATE INDEX IF NOT EXISTS \"" + idx.name + "\" ON \"" + table + "\" (" + String.join(colParts.toArray(), delimiter: ", ") + ")"
    }

    public static func hasTableSQL(): String { "SELECT name FROM sqlite_master WHERE type='table' AND name=?" }

    public static func dropTableSQL(schema: TableSchema): String { "DROP TABLE IF EXISTS \"" + schema.tableName() + "\"" }

    public static func dropColumnSQL(table: String, colName: String): String { "ALTER TABLE \"" + table + "\" DROP COLUMN \"" + colName + "\"" }

    // I6: session 一律 try/finally 关闭，query/execute 抛异常时不得泄漏池化连接
    public func createTable(schema: TableSchema): Unit {
        let s = db.session()
        try {
            s.execute(createTableSQL(schema), [])
        } finally {
            s.close()
        }
    }

    public func dropTable(schema: TableSchema): Unit {
        let s = db.session()
        try {
            s.execute(dropTableSQL(schema), [])
        } finally {
            s.close()
        }
    }

    public func hasTable(name: String): Bool {
        let s = db.session()
        try {
            let r = s.query(hasTableSQL(), [name])
            r.next()
        } finally {
            s.close()
        }
    }

    public func addColumn(table: String, col: ColumnDef): Unit {
        let s = db.session()
        try {
            s.execute(addColumnSQL(table, col), [])
        } finally {
            s.close()
        }
    }

    public func addIndex(table: String, idx: IndexDef): Unit {
        let s = db.session()
        try {
            s.execute(addIndexSQL(table, idx), [])
        } finally {
            s.close()
        }
    }

    public func dropColumn(table: String, colName: String): Unit {
        let s = db.session()
        try {
            s.execute(dropColumnSQL(table, colName), [])
        } finally {
            s.close()
        }
    }

    public func alterColumn(_table: String, _old: ColumnDef, _new: ColumnDef): Unit {
        throw Exception("SQLite does not support ALTER COLUMN")
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
        try {
            let r = s.query("PRAGMA table_info(\"" + tableName + "\")", [])
            var names = ArrayList<String>()
            while (r.next()) { names.add(r.get<String>(1)) }
            names
        } finally {
            s.close()
        }
    }

    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let s = db.session()
        try {
            let r = s.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?", [tableName])
            var names = ArrayList<String>()
            while (r.next()) { names.add(r.get<String>(0)) }
            names
        } finally {
            s.close()
        }
    }

}
