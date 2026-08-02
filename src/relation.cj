package refine

import std.collection.ArrayList
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
    // Task 3: ref_to 批量装配的外键值读取器。ref_to 的 fk 字段在「主实体」上
    // （`@Ref[User, user_id]` 的 user_id 是 Post 的普通字段），宏层生成
    // `{ entity: Any => (entity as Post).getOrThrow().user_id }` 闭包读取。
    // 仅 ref_to 需要主侧 fk 提取；has_one/has_many 的 fk 在目标侧（Task 4 处理），
    // ref_many 走中间表（Task 5 处理），故默认抛错强制只读路径明确。
    func getForeignKeyExtractor(): (Any) -> Any {
        throw RefineException("relation does not expose fk extractor")
    }
    // Task 5: ref_many 的中间表目标列名（lowerTableName(目标类) + "_id"）。
    // 中间表目标列由目标「类名」决定而非目标「表名」（buildJunctionSchema 与
    // INSERT/LOAD 路径一致，见 schema_gen.cj / relation_gen.cj）——@Table 覆盖目标
    // 表名时二者不同，宏层必须显式把类名派生的列名传进 RefMany。非 ref_many 无此列。
    func getJunctionTargetCol(): String { "" }
    // 新增：嵌套 include（默认 no-op）
    func withInclude(rel: IRelation): IRelation { this }
    // 新增：该关系支持的嵌套列表
    func getNested(): Array<IRelation> { [] }
    // 新增：批量查询支持标记（默认 true，预留）
    func isBatchSupported(): Bool { true }
}

public open class Relation<TTarget> <: IRelation {
    var name: String
    var targetTable: String
    var kind: RelationKind
    var foreignKey: String
    var via: Option<String>
    var fields: Array<Col<Any>>
    var condition: Option<Expr>
    var targetMapper: (QueryResult, HashMap<String, Int64>) -> Any
    var fieldSetter: (Any, Any) -> Unit
    // Task 3: ref_to 的外键读取器闭包（宏层为 ref_to 生成，其余关系保持 None）
    var fkExtractor: Option<(Any) -> Any> = None
    // Task 5: ref_many 的中间表目标列名（见 IRelation.getJunctionTargetCol 注释），
    // 仅 RefMany 构造时由宏层设置，其余关系保持 ""
    var junctionTargetCol: String = ""
    private var nested = ArrayList<IRelation>()

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

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any {
        this.targetMapper
    }

    public func getFieldSetter(): (Any, Any) -> Unit {
        this.fieldSetter
    }

    public func getForeignKeyExtractor(): (Any) -> Any {
        match (this.fkExtractor) {
            case Some(e) => e
            case None => throw RefineException(
                "relation '" + name + "' does not expose a foreign-key extractor; cannot batch assemble ref_to"
            )
        }
    }

    public func getJunctionTargetCol(): String {
        this.junctionTargetCol
    }

    public func withInclude(rel: IRelation): IRelation {
        if (hasNested(rel)) {
            return this
        }
        let clone = this.clone()
        clone.nested.add(rel)
        clone
    }

    // 拷贝当前全部字段（含 nested 现有内容），供 withInclude 克隆-on-write。
    // 返回 Relation<TTarget> 基类类型：所有接口方法都在基类上，具体类型由 kind 字段表达。
    public func clone(): Relation<TTarget> {
        let c = Relation<TTarget>(name, targetTable, kind, foreignKey, via, fields, targetMapper, fieldSetter)
        c.fkExtractor = this.fkExtractor
        c.condition = this.condition
        c.junctionTargetCol = this.junctionTargetCol
        for (n in nested) {
            c.nested.add(n)
        }
        c
    }

    public func getNested(): Array<IRelation> {
        this.nested.toArray()
    }

    public func isBatchSupported(): Bool {
        true
    }

    private func hasNested(rel: IRelation): Bool {
        let (rk, rn, rt, rf, rv, _) = rel.resolve()
        for (n in nested) {
            let (nk, nn, nt, nf, nv, _) = n.resolve()
            if (rk == nk && rn == nn && rt == nt && rf == nf && rv == nv) {
                return true
            }
        }
        false
    }
}

public class RefTo<TTarget> <: Relation<TTarget> {
    public init(name: String, fk: Col<Any>, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit,
                fkExtractor: (Any) -> Any) {
        super(name, targetTable, RelationKind.RefToRel, fk.name, None, fields, mapper, setter)
        this.fkExtractor = Some(fkExtractor)
    }
}

public class RefMany<TTarget> <: Relation<TTarget> {
    public init(name: String, via: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit,
                junctionTargetCol: String) {
        super(name, targetTable, RelationKind.RefManyRel, "", Some(via), fields, mapper, setter)
        this.junctionTargetCol = junctionTargetCol
    }
}

public class HasOne<TTarget> <: Relation<TTarget> {
    public init(name: String, fk: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit) {
        super(name, targetTable, RelationKind.HasOneRel, fk, None, fields, mapper, setter)
    }
}

public class HasMany<TTarget> <: Relation<TTarget> {
    public init(name: String, fk: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit) {
        super(name, targetTable, RelationKind.HasManyRel, fk, None, fields, mapper, setter)
    }
}

public func dummyMapper(result: QueryResult, cm: HashMap<String, Int64>): Any { 0 }
public func dummySetter(entity: Any, target: Any): Unit {}
public func dummyFkExtractor(entity: Any): Any { 0 }
