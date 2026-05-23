package refine

public struct Col<T> {
    var name: String

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

    public func asc(): Expr  { FuncCall("ASC", [Column(name)]) }
    public func desc(): Expr { FuncCall("DESC", [Column(name)]) }

    public func `in`(values: Array<T>): Expr {
        Binary(Column(name), In, Value(values))
    }
    public func notIn(values: Array<T>): Expr {
        Binary(Column(name), NotIn, Value(values))
    }
}

extend Col<String> {
    public func like(pattern: String): Expr {
        FuncCall("LIKE", [Column(name), Value(pattern)])
    }
}

extend Col<Bool> {
    public func isTrue(): Expr  { Unary(IsNotNull, Column(name)) }
    public func isFalse(): Expr { Binary(Column(name), Eq, Value(false)) }
}
