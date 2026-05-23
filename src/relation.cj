package refine

public enum RelationKind {
    | RefTo | RefMany | HasOne | HasMany
}

extend RelationKind <: Equatable<RelationKind> {
    public operator func ==(other: RelationKind): Bool {
        match (this) {
            case RefTo => match (other) { case RefTo => true; case _ => false }
            case RefMany => match (other) { case RefMany => true; case _ => false }
            case HasOne => match (other) { case HasOne => true; case _ => false }
            case HasMany => match (other) { case HasMany => true; case _ => false }
        }
    }
}

public interface IRelation {
    func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>)
}

public open class Relation<TTarget> {
    var name: String
    var targetTable: String
    var kind: RelationKind
    var foreignKey: String
    var via: Option<String>
    var fields: Array<Col<Any>>
    var condition: Option<Expr>

    public init(name: String, targetTable: String, kind: RelationKind,
                foreignKey: String, via: Option<String>, fields: Array<Col<Any>>) {
        this.name = name
        this.targetTable = targetTable
        this.kind = kind
        this.foreignKey = foreignKey
        this.via = via
        this.fields = fields
        this.condition = None
    }

    public func setFields(fs: Array<Col<Any>>): Relation<TTarget> {
        this.fields = fs
        this
    }
}

public class RefTo<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, fk: Col<Any>, fields: Array<Col<Any>>) {
        super(name, "", RelationKind.RefTo, fk.name, None, fields)
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }
}

public class RefMany<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, via: String, fields: Array<Col<Any>>) {
        super(name, "", RelationKind.RefMany, "", Some(via), fields)
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }
}
