package refine

public enum BinOp {
    | Eq | Ne | Gt | Ge | Lt | Le
    | And | Or
    | Like | In | NotIn | Between
    | Add | Sub | Mul | Div | Mod
}

extend BinOp <: Equatable<BinOp> {
    public operator func ==(other: BinOp): Bool {
        match (this) {
            case Eq => match (other) { case Eq => true; case _ => false }
            case Ne => match (other) { case Ne => true; case _ => false }
            case Gt => match (other) { case Gt => true; case _ => false }
            case Ge => match (other) { case Ge => true; case _ => false }
            case Lt => match (other) { case Lt => true; case _ => false }
            case Le => match (other) { case Le => true; case _ => false }
            case And => match (other) { case And => true; case _ => false }
            case Or => match (other) { case Or => true; case _ => false }
            case Like => match (other) { case Like => true; case _ => false }
            case In => match (other) { case In => true; case _ => false }
            case NotIn => match (other) { case NotIn => true; case _ => false }
            case Between => match (other) { case Between => true; case _ => false }
            case Add => match (other) { case Add => true; case _ => false }
            case Sub => match (other) { case Sub => true; case _ => false }
            case Mul => match (other) { case Mul => true; case _ => false }
            case Div => match (other) { case Div => true; case _ => false }
            case Mod => match (other) { case Mod => true; case _ => false }
        }
    }
}

public enum UnaryOp {
    | Not | IsNull | IsNotNull
}

extend UnaryOp <: Equatable<UnaryOp> {
    public operator func ==(other: UnaryOp): Bool {
        match (this) {
            case Not => match (other) { case Not => true; case _ => false }
            case IsNull => match (other) { case IsNull => true; case _ => false }
            case IsNotNull => match (other) { case IsNotNull => true; case _ => false }
        }
    }
}

public enum Expr {
    | Column(String)
    | Value(Any)
    | Binary(Expr, BinOp, Expr)
    | Unary(UnaryOp, Expr)
    | FuncCall(String, Array<Expr>)
    | Ordered(Expr, String)    // Column with sort direction: "ASC" / "DESC"
    | SubQuery(Statement)
    | Raw(String)
}

extend Expr {
    public func and(other: Expr): Expr { Binary(this, And, other) }
    public func or(other: Expr): Expr  { Binary(this, Or, other) }
    public func not(): Expr            { Unary(Not, this) }
}
