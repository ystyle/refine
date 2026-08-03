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

// M10: 构造改为工厂方法 createWithInt64Pk/createWithStringPk，消除 Int64/String
// 两个 pk 重载 init 的混淆（int 字面量会被隐式匹配任一重载，调用方意图不明确）。
// init 私有化后仅能经工厂方法构造，pk 语义（数值 vs 字符串）在调用点显式表达。
public class OptimisticLockException <: RefineException {
    public var entityType: String
    public var pk: String
    public var expected: Int64
    public var actual: Int64

    private init(entityType: String, pk: String, expected: Int64, actual: Int64) {
        super("optimistic lock conflict on " + entityType + " pk=" + pk +
            " expected version " + expected.toString() + " got " + actual.toString())
        this.entityType = entityType
        this.pk = pk
        this.expected = expected
        this.actual = actual
    }

    public static func createWithInt64Pk(entityType: String, pk: Int64, expected: Int64, actual: Int64): OptimisticLockException {
        OptimisticLockException(entityType, pk.toString(), expected, actual)
    }

    public static func createWithStringPk(entityType: String, pk: String, expected: Int64, actual: Int64): OptimisticLockException {
        OptimisticLockException(entityType, pk, expected, actual)
    }
}
