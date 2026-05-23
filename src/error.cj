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
