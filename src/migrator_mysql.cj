package refine

import std.collection.{ArrayList, HashMap}

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
        let exists = r.next() && r.get<Int64>(0 + s.getParamOffset()) > 0
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

    public func alterColumn(table: String, _old: ColumnDef, new: ColumnDef): Unit {
        let s = db.session()
        s.execute("ALTER TABLE `" + table + "` MODIFY COLUMN " + columnDefSQL(new, dialect), [])
        s.close()
    }

    public func autoMigrate(schemas: Array<TableSchema>): Unit {
        for (schema in schemas) {
            let tableName = schema.tableName()
            if (!hasTable(tableName)) { createTable(schema); continue }
            let existingCols = getExistingColumns(tableName)
            for (col in schema.columns()) {
                match (existingCols.get(col.name)) {
                    case Some(_) => ()
                    case None => addColumn(tableName, col)
                }
            }
            let existingIdxs = getExistingIndexNames(tableName)
            for (idx in schema.indexes()) {
                if (!existingIdxs.contains(idx.name)) { addIndex(tableName, idx) }
            }
        }
    }

    private func getExistingColumns(tableName: String): HashMap<String, ColumnDef> {
        let s = db.session()
        let r = s.query("SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, EXTRA, COLUMN_TYPE FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = ?", [tableName])
        let off = s.getParamOffset()
        var map = HashMap<String, ColumnDef>()
        while (r.next()) {
            let name = r.get<String>(0 + off)
            let storage = mysqlDataTypeToStorage(r.get<String>(1 + off), r.get<String>(4 + off))
            let nullable = r.get<String>(2 + off) == "YES"
            let autoInc = r.get<String>(3 + off).contains("auto_increment")
            map.add(name, ColumnDef(name, storage, false, autoInc, nullable))
        }
        s.close()
        map
    }

    public static func mysqlDataTypeToStorage(dataType: String, columnType: String): StorageType {
        match (dataType) {
            case "bigint" | "int" | "smallint" | "mediumint" => StorageType.Integer
            case "tinyint" => if (columnType.toAsciiLower().contains("tinyint(1)")) { StorageType.`Bool` } else { StorageType.Integer }
            case "decimal" => StorageType.Decimal
            case "varchar" | "char" => StorageType.String
            case "text" | "mediumtext" | "longtext" => StorageType.Text
            case "json" => StorageType.Json
            case "blob" | "longblob" | "mediumblob" => StorageType.Bytes
            case "datetime" | "timestamp" => StorageType.Timestamp
            case "double" | "float" => StorageType.Float
            case _ => StorageType.Text
        }
    }

    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let s = db.session()
        let r = s.query("SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE table_schema = DATABASE() AND table_name = ?", [tableName])
        var names = ArrayList<String>()
        while (r.next()) { names.add(r.get<String>(0 + s.getParamOffset())) }
        s.close()
        names
    }

}
