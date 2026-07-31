package refine

public struct Col<T> {
    public var name: String

    public init(name: String) {
        this.name = name
    }

    public operator func ==(rhs: T): Expr  { Binary(Column(name), Eq, Value(rhs)) }
    public operator func !=(rhs: T): Expr  { Binary(Column(name), Ne, Value(rhs)) }
    public operator func >(rhs: T): Expr   { Binary(Column(name), Gt, Value(rhs)) }
    public operator func <(rhs: T): Expr   { Binary(Column(name), Lt, Value(rhs)) }
    public operator func >=(rhs: T): Expr  { Binary(Column(name), Ge, Value(rhs)) }
    public operator func <=(rhs: T): Expr  { Binary(Column(name), Le, Value(rhs)) }

    public operator func ==(rhs: Col<T>): Expr { Binary(Column(name), Eq, Column(rhs.name)) }
    public operator func !=(rhs: Col<T>): Expr { Binary(Column(name), Ne, Column(rhs.name)) }

    public func asc(): Expr  { Ordered(Column(name), "ASC") }
    public func desc(): Expr { Ordered(Column(name), "DESC") }

    public func anyOf(values: Array<T>): Expr {
        if (values.size == 0) { return Raw("1 = 0") }
        var result = Binary(Column(name), Eq, Value(values[0]))
        for (i in 1..values.size) {
            result = Binary(result, Or, Binary(Column(name), Eq, Value(values[i])))
        }
        result
    }
    public func notAnyOf(values: Array<T>): Expr {
        if (values.size == 0) { return Raw("1 = 1") }
        var result = Binary(Column(name), Ne, Value(values[0]))
        for (i in 1..values.size) {
            result = Binary(result, And, Binary(Column(name), Ne, Value(values[i])))
        }
        result
    }
}

extend Col<String> {
    public func like(pattern: String): Expr {
        Binary(Column(name), Like, Value(pattern))
    }
}

extend Col<Bool> {
    public func isTrue(): Expr  { Unary(IsNotNull, Column(name)) }
    public func isFalse(): Expr { Binary(Column(name), Eq, Value(false)) }
}
