package refine

public interface Dialect {
    func name(): String
    func render(stmt: Statement): (String, Array<Any>)
    func quoteIdentifier(name: String): String
    func hasUpsertSupport(): Bool
    func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>): String
    func dataTypeOf(st: StorageType): String
    func hasReturningSupport(): Bool
    func hasJSONSupport(): Bool
    func migrator(db: DB): Migrator
    func initialize(db: DB): Unit
    func defaultValueOf(st: StorageType): String
}

public interface SavepointDialect {
    func savepoint(tx: Tx, name: String): Unit
    func rollbackTo(tx: Tx, name: String): Unit
}
