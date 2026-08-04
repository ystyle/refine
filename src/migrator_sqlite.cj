package refine

import std.collection.ArrayList

public class SQLiteMigrator <: Migrator {
    private var db: DB

    public init(db: DB) {
        this.db = db
    }

    // R-M13: 静态 SQL 构建器无 dialect 实例，统一经 SQLiteDialect().quoteIdentifier 引号化
    // （ANSI 双引号 + 内嵌 `"` → `""` 转义，对齐 C9 封闭标识符逃逸注入通道；SQLite 标识符
    // 大小写不敏感，但转义仍必要——含双引号的表名/列名会破坏 DDL 文本）。
    private static func qi(name: String): String {
        SQLiteDialect().quoteIdentifier(name)
    }

    public static func dataTypeOf(st: StorageType): String {
        SQLiteDialect().dataTypeOf(st)
    }

    public static func columnDefSQL(col: ColumnDef): String {
        var parts = ArrayList<String>()
        parts.add(qi(col.name))
        parts.add(dataTypeOf(col.storageType))
        if (col.primaryKey) { parts.add("PRIMARY KEY") }
        if (col.autoIncrement) { parts.add("AUTOINCREMENT") }
        if (col.nullable) { parts.add("NULL") }
        else { parts.add("NOT NULL") }
        String.join(parts.toArray(), delimiter: " ")
    }

    public static func createTableSQL(schema: TableSchema): String {
        let cols = schema.columns()
        // R-M17: 空 schema（columns() 为空）会生成 `CREATE TABLE IF NOT EXISTS "t" ()`——
        // SQLite 非法 DDL（三方言均无「零列建表」语义），fail-fast 抛带表名的明确错误。
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
            if (composite && col.primaryKey) { colDefs.add(compositePkColumnDefSQL(col)) }
            else { colDefs.add(columnDefSQL(col)) }
        }
        var parts = ArrayList<String>()
        parts.add("CREATE TABLE IF NOT EXISTS " + qi(schema.tableName()) + " (")
        let colDefsSQL = String.join(colDefs.toArray(), delimiter: ", ")
        if (composite) {
            var pkParts = ArrayList<String>()
            for (name in pkNames) { pkParts.add(qi(name)) }
            parts.add(colDefsSQL + ", PRIMARY KEY (" + String.join(pkParts.toArray(), delimiter: ", ") + ")")
        } else {
            parts.add(colDefsSQL)
        }
        parts.add(")")
        String.join(parts.toArray(), delimiter: "")
    }

    // M24 复合主键列定义：列级不追加 PRIMARY KEY/AUTOINCREMENT（SQLite 表级 PRIMARY KEY
    // 是唯一的行身份约束，复合主键不能含 rowid 别名列，AUTOINCREMENT 在此无意义），
    // 可空性按列声明输出（junction 列 nullable=false → NOT NULL）。
    private static func compositePkColumnDefSQL(col: ColumnDef): String {
        var parts = ArrayList<String>()
        parts.add(qi(col.name))
        parts.add(dataTypeOf(col.storageType))
        if (col.nullable) { parts.add("NULL") }
        else { parts.add("NOT NULL") }
        String.join(parts.toArray(), delimiter: " ")
    }

    // I5: SQLite 对非空表 ADD COLUMN NOT NULL 列必须带 DEFAULT，否则 ALTER 失败（设计 §11.3
    // "已有行使用 DEFAULT 或 NULL"）。主键/自增列排除（主键列不允许普通默认值）。
    public static func addColumnSQL(table: String, col: ColumnDef): String {
        var sql = "ALTER TABLE " + qi(table) + " ADD COLUMN " + columnDefSQL(col)
        if (!col.nullable && !col.primaryKey && !col.autoIncrement) {
            sql += " DEFAULT " + SQLiteDialect().defaultValueOf(col.storageType)
        }
        sql
    }

    public static func addIndexSQL(table: String, idx: IndexDef): String {
        var colParts = ArrayList<String>()
        for (c in idx.columns) { colParts.add(qi(c)) }
        "CREATE INDEX IF NOT EXISTS " + qi(idx.name) + " ON " + qi(table) + " (" + String.join(colParts.toArray(), delimiter: ", ") + ")"
    }

    public static func hasTableSQL(): String { "SELECT name FROM sqlite_master WHERE type='table' AND name=?" }

    public static func dropTableSQL(schema: TableSchema): String { "DROP TABLE IF EXISTS " + qi(schema.tableName()) }

    public static func dropColumnSQL(table: String, colName: String): String { "ALTER TABLE " + qi(table) + " DROP COLUMN " + qi(colName) }

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

    // M13: 抛 MigrationException（RefineException 子类）而非裸 Exception，让调用方可按
    // 异常层次精确捕获（testMigratorAlterColumn 断言 message 不受影响）。
    public func alterColumn(_table: String, _old: ColumnDef, _new: ColumnDef): Unit {
        throw MigrationException("SQLite does not support ALTER COLUMN")
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
            let r = s.query("PRAGMA table_info(" + qi(tableName) + ")", [])
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
            while (r.next()) {
                let name = r.get<String>(0)
                // R-M18: SQLite 为 UNIQUE/主键约束自动创建 `sqlite_autoindex_<表>_<n>` 内部索引，
                // 不属于用户声明的 IndexDef，混入会让 autoMigrate 把用户索引误判为已存在而跳过。
                if (name.startsWith("sqlite_autoindex_")) { continue }
                names.add(name)
            }
            names
        } finally {
            s.close()
        }
    }

}
