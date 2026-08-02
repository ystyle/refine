package refine

public enum IsolationLevel {
    | ReadUncommitted | ReadCommitted | RepeatableRead | Serializable
}

public interface Dialect {
    func name(): String
    func render(stmt: Statement): (String, Array<Any>)
    func quoteIdentifier(name: String): String
    func hasUpsertSupport(): Bool
    // 返回 (sql, extraParamCount)：extraParamCount 是调用方在实体字段值之外，
    // 还必须按 columns 顺序追加的额外参数个数（如 MySQL 审计更新列生成的 `col = ?`）。
    // 契约：auditCreateCols 与 auditUpdateCols 需不相交；重叠时 auditCreate 优先
    // （方言按 continue 跳过 auditCreate 列，不生成更新子句与参数）。
    func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>, auditCreateCols: Array<String>, auditUpdateCols: Array<String>, versionCol: String): (String, Int64)
    func dataTypeOf(st: StorageType): String
    func hasReturningSupport(): Bool
    func hasJSONSupport(): Bool
    func hasIsolationSupport(): Bool
    func migrator(db: DB): Migrator
    func initialize(db: DB): Unit
    func defaultValueOf(st: StorageType): String
}

public interface SavepointDialect {
    func savepoint(tx: Tx, name: String): Unit
    func rollbackTo(tx: Tx, name: String): Unit
}
