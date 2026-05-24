package refine

public interface Dialect {
    func name(): String
    func render(stmt: Statement): (String, Array<Any>)
    func quoteIdentifier(name: String): String
    func hasUpsertSupport(): Bool
    func upsertSQL(table: String, columns: Array<String>, conflictColumns: Array<String>): String
}
