package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.QueryResult

// M20: Query<T> include DSL 方法组 + FieldOverrideRelation（字段子集包装器）。
// 通过 extend 从 query.cj 核心类中按职责拆出。extend 不能访问被扩展类型
// 的 private 成员，故所调用的类内成员（relResolver 等字段）均已按约定为
// 包级可见（无修饰符），见 query.cj 顶部注释。
class FieldOverrideRelation <: IRelation {
    private var inner: IRelation
    private var overrides: Array<Col<Any>>

    public init(inner: IRelation, fields: Array<Col<Any>>) {
        this.inner = inner
        this.overrides = fields
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        let (kind, name, table, fk, via, _) = inner.resolve()
        (kind, name, table, fk, via, overrides)
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any {
        inner.getTargetMapper()
    }

    public func getFieldSetter(): (Any, Any) -> Unit {
        inner.getFieldSetter()
    }

    public func getForeignKeyExtractor(): (Any) -> Any {
        inner.getForeignKeyExtractor()
    }

    public func getTargetIdExtractor(): (Any) -> Any {
        inner.getTargetIdExtractor()
    }

    public func withInclude(rel: IRelation): IRelation {
        FieldOverrideRelation(inner.withInclude(rel), overrides)
    }

    public func getNested(): Array<IRelation> {
        inner.getNested()
    }

    public func isBatchSupported(): Bool {
        inner.isBatchSupported()
    }

    public func getJunctionTargetCol(): String {
        inner.getJunctionTargetCol()
    }

    public func getTargetRelResolver(): (String) -> Option<IRelation> {
        inner.getTargetRelResolver()
    }
}

extend<T> Query<T> {

    public func include(rel: IRelation): Query<T> {
        included.add(rel)
        this
    }

    public func include(rel: IRelation, fields: Array<Col<Any>>): Query<T> {
        let override = FieldOverrideRelation(rel, fields)
        included.add(override)
        this
    }

    // Task 7: includeAll 字符串点号路径批量 include（admin/后端传路径数组场景）：
    //   query.includeAll(["author.profile", "tags"])
    // 路径第一段在「本实体」Rel 类上解析（relResolver，宏层随 query() 挂载为
    // `<实体>Rel.forName`）；后续段在上一层关系的「目标实体」Rel 类上解析
    // （IRelation.getTargetRelResolver，宏层为每个关系生成目标 Rel 类的 forName 闭包）。
    // 解析出的关系按 withInclude 链式嵌套，与手写
    //   include(PostRel.author.withInclude(UserRel.profile))
    // 完全等价（同一批装配路径、同一 SQL，见测试 testIncludeAllEqualsWithIncludeChain）。
    // 限制（计划决策 A）：字符串路径只支持纯点号关系名，不支持字段子集语法；
    // 需要字段子集请用 include(rel, fields) / withInclude 链手写。
    public func includeAll(paths: Array<String>): Query<T> {
        for (path in paths) {
            let segments = path.split(".")
            if (segments.size == 0) {
                throw QueryException("includeAll: empty include path")
            }
            for (seg in segments) {
                if (seg == "") {
                    throw QueryException("includeAll: empty path segment in '" + path + "'")
                }
            }
            let resolver = match (this.relResolver) {
                case Some(r) => r
                case None => throw QueryException(
                    "includeAll: no relation resolver wired for entity '" + typeName + "'; " +
                    "use the macro-generated query() builder or call setRelResolver()")
            }
            // 逐段解析：每一段在「上一层关系」的目标 Rel 类上解析（首段在本实体 Rel 类上）。
            // 注意解析目标随链加深而切换：解析 "skills" 用的是 profile（第二层关系）的
            // getTargetRelResolver，而非作者关系的（否则会错误地在 NestedUserRel 上找 skills）。
            var chain = ArrayList<IRelation>()
            match (resolver(segments[0])) {
                case Some(r) => chain.add(r)
                case None => throw QueryException(
                    "includeAll: unknown relation '" + segments[0] + "' on entity '" + typeName + "'")
            }
            var current = chain[0]
            var prefix = segments[0]
            for (i in 1..segments.size) {
                match (current.getTargetRelResolver()(segments[i])) {
                    case Some(sub) =>
                        chain.add(sub)
                        current = sub
                        prefix = prefix + "." + segments[i]
                    case None => throw QueryException(
                        "includeAll: unknown nested relation '" + segments[i] + "' under '" + prefix + "'")
                }
            }
            // 从最深一层向上逐级 withInclude 嵌套（而非扁平兄弟嵌套）：
            // "author.profile.skills" → author.withInclude(profile.withInclude(skills))。
            var assembled = chain[chain.size - 1]
            var ci = chain.size - 2
            while (ci >= 0) {
                assembled = chain[ci].withInclude(assembled)
                ci--
            }
            this.include(assembled)
        }
        this
    }

    // R-I1: using(exec) 传播执行上下文携带的 Refine 绑定（Refine.session()/transaction
    // 创建的 Session/Tx ref = Some(rf)，裸 Session/Tx ref = None）。修复前只设
    // executor/queryDialect/columnOffset，rf.transaction { tx => query().using(tx).all() }
    // 等常用路径下 runAfterFindHooks 见 ref=None 静默跳过 AfterFind。
    public func using(exec: ExecutionContext): Query<T> {
        this.executor = exec
        this.queryDialect = Some(exec.getDialect())
        this.columnOffset = exec.getParamOffset()
        match (exec.getRef()) {
            case Some(rf) => this.ref = Some(rf)
            case None => ()
        }
        this
    }

    public func using(database: DB): Query<T> {
        this.db = Some(database)
        this.executor = Some(database.session())
        this
    }

    public func using(rf: Refine): Query<T> {
        this.executor = Some(rf.session())
        this.queryDialect = Some(rf.getDialect())
        this.columnOffset = rf.getParamOffset()
        this.ref = Some(rf)
        this
    }

    // Task 2: 主查询分离——include 不再生成 LEFT JOIN/别名 SELECT/限定（qualify）。
    // 主查询只渲染源表自身（无 JOIN），include 预加载改由批量分步查询协议完成：
    // ref_to（Task 3）、has_one/has_many（Task 4）、ref_many（Task 5）均已接入
    // all()/one()/page()，经 assembleIncludes 按各自协议批量装配。此方法保留为 no-op 挂接入口。
    public func processIncluded(dialect: Dialect): Unit {
        ()
    }
}
