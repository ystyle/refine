package refine

import std.collection.{ArrayList, HashMap}

public class MySQLMigrator <: Migrator {
    private var db: DB
    private var dialect: MySQLDialect

    public init(db: DB) {
        this.db = db
        this.dialect = MySQLDialect()
    }

    // R-M13: 标识符统一经方言 quoteIdentifier 引号化（MySQL 反引号 + 内嵌反引号转义，
    // 对齐 C9 封闭标识符逃逸注入通道；静态构建器用传入的 d，实例方法用 this.dialect）。
    public static func columnDefSQL(col: ColumnDef, d: MySQLDialect): String {
        var parts = ArrayList<String>()
        parts.add(d.quoteIdentifier(col.name))
        parts.add(d.dataTypeOf(col.storageType))
        if (col.primaryKey && col.autoIncrement) { parts.add("AUTO_INCREMENT PRIMARY KEY") }
        else if (col.primaryKey) { parts.add("PRIMARY KEY") }
        if (!col.nullable && !col.primaryKey) { parts.add("NOT NULL") }
        String.join(parts.toArray(), delimiter: " ")
    }

    public static func createTableSQL(schema: TableSchema, d: MySQLDialect): String {
        let cols = schema.columns()
        // R-M17: 空 schema（columns() 为空）生成的零列 CREATE TABLE 是 MySQL 非法 DDL，
        // fail-fast 抛带表名的明确错误（三迁移器一致）。
        if (cols.size == 0) {
            throw MigrationException("cannot create table '" + schema.tableName() +
                "': TableSchema.columns() is empty (a table needs at least one column)")
        }
        var pkNames = ArrayList<String>()
        for (col in cols) { if (col.primaryKey) { pkNames.add(col.name) } }
        // M24: ≥2 主键列（junction 复合主键）时列级不追加 PRIMARY KEY，改表级约束
        let composite = pkNames.size > 1
        var colDefs = ArrayList<String>()
        for (col in cols) {
            if (composite && col.primaryKey) { colDefs.add(compositePkColumnDefSQL(col, d)) }
            else { colDefs.add(columnDefSQL(col, d)) }
        }
        var parts = ArrayList<String>()
        parts.add("CREATE TABLE IF NOT EXISTS " + d.quoteIdentifier(schema.tableName()) + " (")
        let colDefsSQL = String.join(colDefs.toArray(), delimiter: ", ")
        if (composite) {
            var pkParts = ArrayList<String>()
            for (name in pkNames) { pkParts.add(d.quoteIdentifier(name)) }
            parts.add(colDefsSQL + ", PRIMARY KEY (" + String.join(pkParts.toArray(), delimiter: ", ") + ")")
        } else {
            parts.add(colDefsSQL)
        }
        parts.add(")")
        String.join(parts.toArray(), delimiter: "")
    }

    // M24 复合主键列定义：列级不追加 PRIMARY KEY；autoIncrement 列保留（MySQL 复合主键
    // 允许自增列作前缀列），可空性按列声明输出（junction 列 nullable=false → NOT NULL）。
    private static func compositePkColumnDefSQL(col: ColumnDef, d: MySQLDialect): String {
        var parts = ArrayList<String>()
        parts.add(d.quoteIdentifier(col.name))
        parts.add(d.dataTypeOf(col.storageType))
        if (col.autoIncrement) { parts.add("AUTO_INCREMENT") }
        if (!col.nullable) { parts.add("NOT NULL") }
        String.join(parts.toArray(), delimiter: " ")
    }

    // I6: session 一律 try/finally 关闭，query/execute 抛异常时不得泄漏池化连接
    public func createTable(schema: TableSchema): Unit {
        let s = db.session()
        try {
            s.execute(createTableSQL(schema, dialect), [])
        } finally {
            s.close()
        }
    }

    public func dropTable(schema: TableSchema): Unit {
        let s = db.session()
        try {
            s.execute("DROP TABLE IF EXISTS " + dialect.quoteIdentifier(schema.tableName()), [])
        } finally {
            s.close()
        }
    }

    public func hasTable(name: String): Bool {
        let s = db.session()
        try {
            let r = s.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?", [name])
            let off = s.getParamOffset()
            r.next() && r.get<Int64>(0 + off) > 0
        } finally {
            s.close()
        }
    }

    public func addColumn(table: String, col: ColumnDef): Unit {
        let s = db.session()
        try {
            s.execute("ALTER TABLE " + dialect.quoteIdentifier(table) + " ADD COLUMN " + columnDefSQL(col, dialect), [])
        } finally {
            s.close()
        }
    }

    public func addIndex(table: String, idx: IndexDef): Unit {
        var colParts = ArrayList<String>()
        for (c in idx.columns) { colParts.add(dialect.quoteIdentifier(c)) }
        let s = db.session()
        try {
            s.execute("CREATE INDEX " + dialect.quoteIdentifier(idx.name) + " ON " + dialect.quoteIdentifier(table) + " (" + String.join(colParts.toArray(), delimiter: ", ") + ")", [])
        } finally {
            s.close()
        }
    }

    public func dropColumn(table: String, colName: String): Unit {
        let s = db.session()
        try {
            s.execute("ALTER TABLE " + dialect.quoteIdentifier(table) + " DROP COLUMN " + dialect.quoteIdentifier(colName), [])
        } finally {
            s.close()
        }
    }

    public func alterColumn(table: String, _old: ColumnDef, new: ColumnDef): Unit {
        let s = db.session()
        try {
            s.execute("ALTER TABLE " + dialect.quoteIdentifier(table) + " MODIFY COLUMN " + columnDefSQL(new, dialect), [])
        } finally {
            s.close()
        }
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
        try {
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
            map
        } finally {
            s.close()
        }
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

    // M15: 复合索引在 STATISTICS 中每列占一行（同名重复出现），须 DISTINCT 去重；
    // 主键索引行名恒为 'PRIMARY'，不得混入普通索引集合（否则 PRIMARY 会被当作可重复创建的索引名）
    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let s = db.session()
        try {
            let r = s.query("SELECT DISTINCT INDEX_NAME FROM information_schema.STATISTICS WHERE table_schema = DATABASE() AND table_name = ? AND INDEX_NAME != 'PRIMARY'", [tableName])
            let off = s.getParamOffset()
            var names = ArrayList<String>()
            while (r.next()) { names.add(r.get<String>(0 + off)) }
            names
        } finally {
            s.close()
        }
    }

}
