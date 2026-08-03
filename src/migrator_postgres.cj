package refine

import std.collection.{ArrayList, HashMap}

public class PostgreSQLMigrator <: Migrator {
    private var db: DB
    private var dialect: PostgreSQLDialect

    public init(db: DB) {
        this.db = db
        this.dialect = PostgreSQLDialect()
    }

    public static func columnDefSQL(col: ColumnDef, d: PostgreSQLDialect): String {
        var parts = ArrayList<String>()
        parts.add("\"" + col.name + "\"")
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
        let cols = schema.columns()
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
        parts.add("CREATE TABLE IF NOT EXISTS \"" + schema.tableName() + "\" (")
        let colDefsSQL = String.join(colDefs.toArray(), delimiter: ", ")
        if (composite) {
            var pkParts = ArrayList<String>()
            for (name in pkNames) { pkParts.add("\"" + name + "\"") }
            parts.add(colDefsSQL + ", PRIMARY KEY (" + String.join(pkParts.toArray(), delimiter: ", ") + ")")
        } else {
            parts.add(colDefsSQL)
        }
        parts.add(")")
        String.join(parts.toArray(), delimiter: "")
    }

    // M24 复合主键列定义：列级不追加 PRIMARY KEY；autoIncrement 列用 BIGSERIAL
    //（自带 NOT NULL，序列即主键来源），其余列按类型 + 可空性输出（junction 列
    // nullable=false → NOT NULL）。
    private static func compositePkColumnDefSQL(col: ColumnDef, d: PostgreSQLDialect): String {
        var parts = ArrayList<String>()
        parts.add("\"" + col.name + "\"")
        if (col.autoIncrement) {
            parts.add("BIGSERIAL")
        } else {
            parts.add(d.dataTypeOf(col.storageType))
            if (!col.nullable) { parts.add("NOT NULL") }
        }
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
            s.execute("DROP TABLE IF EXISTS \"" + schema.tableName() + "\"", [])
        } finally {
            s.close()
        }
    }

    public func hasTable(name: String): Bool {
        let s = db.session()
        try {
            let r = s.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = ?", [name])
            r.next() && r.get<Int64>(0) > 0
        } finally {
            s.close()
        }
    }

    public func addColumn(table: String, col: ColumnDef): Unit {
        let s = db.session()
        try {
            s.execute("ALTER TABLE \"" + table + "\" ADD COLUMN " + columnDefSQL(col, dialect), [])
        } finally {
            s.close()
        }
    }

    public func addIndex(table: String, idx: IndexDef): Unit {
        var colParts = ArrayList<String>()
        for (c in idx.columns) { colParts.add("\"" + c + "\"") }
        let s = db.session()
        try {
            s.execute("CREATE INDEX IF NOT EXISTS \"" + idx.name + "\" ON \"" + table + "\" (" + String.join(colParts.toArray(), delimiter: ", ") + ")", [])
        } finally {
            s.close()
        }
    }

    public func dropColumn(table: String, colName: String): Unit {
        let s = db.session()
        try {
            s.execute("ALTER TABLE \"" + table + "\" DROP COLUMN IF EXISTS \"" + colName + "\"", [])
        } finally {
            s.close()
        }
    }

    public func alterColumn(table: String, _old: ColumnDef, new: ColumnDef): Unit {
        let s = db.session()
        try {
            s.execute("ALTER TABLE \"" + table + "\" ALTER COLUMN \"" + new.name + "\" TYPE " + dialect.dataTypeOf(new.storageType), [])
            if (new.primaryKey) {
                // 主键列保持 NOT NULL，不调整
            } else if (!new.nullable) {
                s.execute("ALTER TABLE \"" + table + "\" ALTER COLUMN \"" + new.name + "\" SET NOT NULL", [])
            } else {
                s.execute("ALTER TABLE \"" + table + "\" ALTER COLUMN \"" + new.name + "\" DROP NOT NULL", [])
            }
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
            let r = s.query("SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ?", [tableName])
            var map = HashMap<String, ColumnDef>()
            while (r.next()) {
                let name = r.get<String>(0)
                let storage = pgDataTypeToStorage(r.get<String>(1))
                let nullable = r.get<String>(2) == "YES"
                map.add(name, ColumnDef(name, storage, false, false, nullable))
            }
            map
        } finally {
            s.close()
        }
    }

    public static func pgDataTypeToStorage(t: String): StorageType {
        match (t) {
            case "bigint" | "integer" | "smallint" => StorageType.Integer
            case "character varying" | "character" => StorageType.String
            case "text" => StorageType.Text
            case "jsonb" | "json" => StorageType.Json
            case "bytea" => StorageType.Bytes
            case "timestamp without time zone" | "timestamp with time zone" => StorageType.Timestamp
            case "numeric" => StorageType.Decimal
            case "double precision" | "real" => StorageType.Float
            case "boolean" => StorageType.`Bool`
            case _ => StorageType.Text
        }
    }

    private func getExistingIndexNames(tableName: String): ArrayList<String> {
        let s = db.session()
        try {
            let r = s.query("SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename = ?", [tableName])
            var names = ArrayList<String>()
            while (r.next()) { names.add(r.get<String>(0)) }
            names
        } finally {
            s.close()
        }
    }

}
