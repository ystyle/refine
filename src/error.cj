package refine

public open class RefineException <: Exception {
    public init(message: String) {
        super(message)
    }
}

public class ConnectionException <: RefineException {
    public init(message: String) {
        super(message)
    }
}

public class QueryException <: RefineException {
    public init(message: String) {
        super(message)
    }
}

public class MappingException <: RefineException {
    public init(message: String) {
        super(message)
    }
}

public class MigrationException <: RefineException {
    public init(message: String) {
        super(message)
    }
}

public class ConfigException <: RefineException {
    public init(message: String) {
        super(message)
    }
}

public class HookException <: RefineException {
    public init(message: String) {
        super(message)
    }
}

public class OptimisticLockException <: RefineException {
    public var entityType: String
    public var pk: String
    public var expected: Int64
    public var actual: Int64
    public init(entityType: String, pk: Int64, expected: Int64, actual: Int64) {
        super("optimistic lock conflict on " + entityType + " pk=" + pk.toString() +
            " expected version " + expected.toString() + " got " + actual.toString())
        this.entityType = entityType
        this.pk = pk.toString()
        this.expected = expected
        this.actual = actual
    }
    public init(entityType: String, pk: String, expected: Int64, actual: Int64) {
        super("optimistic lock conflict on " + entityType + " pk=" + pk +
            " expected version " + expected.toString() + " got " + actual.toString())
        this.entityType = entityType
        this.pk = pk
        this.expected = expected
        this.actual = actual
    }
}
