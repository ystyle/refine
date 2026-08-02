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
    // Task 6: 嵌套 include 递归装配的目标实体主键读取器。宏层为每个关系生成
    // `{ target: Any => (target as 目标类).getOrThrow().id }` 闭包（目标实体是
    // 上一级装配结果，Any 化存储；嵌套 has_many/ref_many 需要目标实体的 id 作为
    // 下一层 `WHERE 目标.fk IN (目标实体 id)` 的主键集合）。所有关系种类都需要
    // （任意关系的目标实体都可能再声明嵌套 include），宏层统一生成并传入。
    func getTargetIdExtractor(): (Any) -> Any {
        throw RefineException("relation does not expose target id extractor")
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
    // Task 7: includeAll 字符串路径 DSL 的目标 Rel 类解析器。宏层为每个关系生成
    // `{ n: String => <目标类Rel>.forName(n) }` 闭包（目标 Rel 类的 forName 静态方法在
    // 编译期可解析），供 Query.includeAll 解析点号路径的后缀段（如 "author.profile" 的
    // "profile" 在 author 的目标 Rel 类上解析）。默认返回恒 None 的闭包：自定义 IRelation
    // 未提供解析器时 includeAll 嵌套段解析失败统一抛 QueryException（错误语义一致）。
    func getTargetRelResolver(): (String) -> Option<IRelation> {
        { n: String => None }
    }
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
    // Task 6: 目标实体主键读取器闭包（宏层为所有关系生成，见 IRelation 注释）。
    // 供嵌套 include 递归装配读取上一层装配出的目标实体主键（Array<Any>）。
    var targetIdExtractor: Option<(Any) -> Any> = None
    // Task 5: ref_many 的中间表目标列名（见 IRelation.getJunctionTargetCol 注释），
    // 仅 RefMany 构造时由宏层设置，其余关系保持 ""
    var junctionTargetCol: String = ""
    // Task 7: 目标实体 Rel 类解析器（见 IRelation.getTargetRelResolver 注释）。宏层在
    // buildRelClass 生成静态成员时用 attachTargetRelResolver 注入
    // `{ n: String => <目标类Rel>.forName(n) }`；手工构造的关系保持默认恒 None。
    var targetRelResolver: (String) -> Option<IRelation> = { n: String => None }
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

    public func getTargetIdExtractor(): (Any) -> Any {
        match (this.targetIdExtractor) {
            case Some(e) => e
            case None => throw RefineException(
                "relation '" + name + "' does not expose a target id extractor; cannot batch assemble nested include"
            )
        }
    }

    public func getJunctionTargetCol(): String {
        this.junctionTargetCol
    }

    public func setTargetRelResolver(r: (String) -> Option<IRelation>): Unit {
        this.targetRelResolver = r
    }

    public func getTargetRelResolver(): (String) -> Option<IRelation> {
        this.targetRelResolver
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
        c.targetIdExtractor = this.targetIdExtractor
        c.condition = this.condition
        c.junctionTargetCol = this.junctionTargetCol
        c.targetRelResolver = this.targetRelResolver
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
                fkExtractor: (Any) -> Any,
                targetIdExtractor: (Any) -> Any) {
        super(name, targetTable, RelationKind.RefToRel, fk.name, None, fields, mapper, setter)
        this.fkExtractor = Some(fkExtractor)
        this.targetIdExtractor = Some(targetIdExtractor)
    }
}

public class RefMany<TTarget> <: Relation<TTarget> {
    public init(name: String, via: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit,
                junctionTargetCol: String,
                targetIdExtractor: (Any) -> Any) {
        super(name, targetTable, RelationKind.RefManyRel, "", Some(via), fields, mapper, setter)
        this.junctionTargetCol = junctionTargetCol
        this.targetIdExtractor = Some(targetIdExtractor)
    }
}

public class HasOne<TTarget> <: Relation<TTarget> {
    public init(name: String, fk: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit,
                targetIdExtractor: (Any) -> Any) {
        super(name, targetTable, RelationKind.HasOneRel, fk, None, fields, mapper, setter)
        this.targetIdExtractor = Some(targetIdExtractor)
    }
}

public class HasMany<TTarget> <: Relation<TTarget> {
    public init(name: String, fk: String, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit,
                targetIdExtractor: (Any) -> Any) {
        super(name, targetTable, RelationKind.HasManyRel, fk, None, fields, mapper, setter)
        this.targetIdExtractor = Some(targetIdExtractor)
    }
}

public func dummyMapper(result: QueryResult, cm: HashMap<String, Int64>): Any { 0 }
public func dummySetter(entity: Any, target: Any): Unit {}
public func dummyFkExtractor(entity: Any): Any { 0 }
public func dummyTargetIdExtractor(target: Any): Any { 0 }

// Task 7: 保留具体类型的解析器注入辅助。宏层生成的 `static let author = RefTo<Author>(...)`
// 需要挂载目标 Rel 类解析器（getTargetRelResolver）且不丢失静态成员的具体类型
// （RefTo<Author> 而非 Relation<Author>），故用泛型 R 保留原类型：
// `R <: Relation<T>` 约束下调用基类 setTargetRelResolver 后原样返回 rel。
// 若直接在静态成员构造上调返回 Relation<TTarget> 的方法会丢具体类型，影响成员类型推导。
public func attachTargetRelResolver<R, T>(rel: R, resolver: (String) -> Option<IRelation>): R where R <: Relation<T> {
    rel.setTargetRelResolver(resolver)
    rel
}
