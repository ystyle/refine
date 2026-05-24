package refine

import std.collection.HashMap
import std.database.sql.QueryResult

public enum RelationKind {
    | RefToRel | RefManyRel | HasOneRel | HasManyRel
}

extend RelationKind <: Equatable<RelationKind> & ToString {
    public operator func ==(other: RelationKind): Bool {
        match (this) {
            case RefToRel => match (other) { case RefToRel => true; case _ => false }
            case RefManyRel => match (other) { case RefManyRel => true; case _ => false }
            case HasOneRel => match (other) { case HasOneRel => true; case _ => false }
            case HasManyRel => match (other) { case HasManyRel => true; case _ => false }
        }
    }
    public func toString(): String {
        match (this) {
            case RefToRel => "RefToRel"
            case RefManyRel => "RefManyRel"
            case HasOneRel => "HasOneRel"
            case HasManyRel => "HasManyRel"
        }
    }
}

public interface IRelation {
    func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>)
    func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any
    func getFieldSetter(): (Any, Any) -> Unit
}

public open class Relation<TTarget> {
    var name: String
    var targetTable: String
    var kind: RelationKind
    var foreignKey: String
    var via: Option<String>
    var fields: Array<Col<Any>>
    var condition: Option<Expr>
    var targetMapper: (QueryResult, HashMap<String, Int64>) -> Any
    var fieldSetter: (Any, Any) -> Unit

    public init(name: String, targetTable: String, kind: RelationKind,
                foreignKey: String, via: Option<String>, fields: Array<Col<Any>>,
                targetMapper: (QueryResult, HashMap<String, Int64>) -> Any,
                fieldSetter: (Any, Any) -> Unit) {
        this.name = name
        this.targetTable = targetTable
        this.kind = kind
        this.foreignKey = foreignKey
        this.via = via
        this.fields = fields
        this.condition = None
        this.targetMapper = targetMapper
        this.fieldSetter = fieldSetter
    }

    public func setFields(fs: Array<Col<Any>>): Relation<TTarget> {
        this.fields = fs
        this
    }
}

public class RefTo<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, fk: Col<Any>, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit) {
        super(name, targetTable, RelationKind.RefToRel, fk.name, None, fields, mapper, setter)
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any {
        this.targetMapper
    }

    public func getFieldSetter(): (Any, Any) -> Unit {
        this.fieldSetter
    }
}

public class RefMany<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, via: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit) {
        super(name, targetTable, RelationKind.RefManyRel, "", Some(via), fields, mapper, setter)
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any {
        this.targetMapper
    }

    public func getFieldSetter(): (Any, Any) -> Unit {
        this.fieldSetter
    }
}

public class HasOne<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, fk: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit) {
        super(name, targetTable, RelationKind.HasOneRel, fk, None, fields, mapper, setter)
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any {
        this.targetMapper
    }

    public func getFieldSetter(): (Any, Any) -> Unit {
        this.fieldSetter
    }
}

public class HasMany<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, fk: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit) {
        super(name, targetTable, RelationKind.HasManyRel, fk, None, fields, mapper, setter)
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any {
        this.targetMapper
    }

    public func getFieldSetter(): (Any, Any) -> Unit {
        this.fieldSetter
    }
}

public func dummyMapper(result: QueryResult, cm: HashMap<String, Int64>): Any { 0 }
public func dummySetter(entity: Any, target: Any): Unit {}
