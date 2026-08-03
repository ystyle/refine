package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.QueryResult

// M20: Query<T> 核心类——字段 + 构造/拷贝 + 构建器 DSL + setter + 共享基础设施。
// 执行（query_exec.cj）、DML（query_dml.cj）、include DSL（query_include.cj）、
// 批量装配（query_batch.cj）通过 extend 按职责拆分。
//
// 可见性约定（M20）：仓颉 extend 不能访问被扩展类型的 private 成员，且不能新增
// 成员变量；扩展内 private 成员仅在同一 extend 块内可见，跨 extend 文件调用需
// 包级可见。因此本类中供各 extend 块跨文件调用的成员（requireExecutor/
// closeExecutor/runAfterFindHooks/getSourceTable/MaxNestedDepth 及全部字段）一律为
// 「包级可见」（无修饰符，同 Session.paramOffset / DB.dialect 的既有约定）；真正的
// 私有性由「仅包内使用 + 宏层只调用公开 setter」约束，而非语言 private。各 extend
// 文件内部只在本块内使用的方法恢复 private（见各文件顶部注释）。
public class Query<T> {
    var stmt: Statement
    var included: ArrayList<IRelation>
    var alias: String
    var executor: Option<ExecutionContext> = None
    var queryDialect: Option<Dialect> = None
    var mapper: Option<(QueryResult, HashMap<String, Int64>) -> T> = None
    var db: Option<DB> = None
    var columnOffset: Int64 = 0
    public var typeName: String = ""
    var ref: Option<Refine> = None
    var keyExtractor: Option<(QueryResult, HashMap<String, Int64>) -> String> = None
    // Task 4: has_many/has_one 批量装配需要主实体主键的「原始值」（Int64/String 上转 Any），
    // 由宏层生成（XxxRawIdFromResult）在 setKeyExtractor 处一并挂载。keyExtractor 输出
    // String（复合主键 ":" 拼接），无法直接作为批量 IN 的 SQL 参数原值，故单独存 rawId。
    // 复合主键主实体不挂载（None），集合 include 装配入口会抛带说明的 QueryException。
    var rawIdExtractor: Option<(QueryResult, HashMap<String, Int64>) -> Any> = None
    // Task 7: includeAll 字符串路径 DSL 的顶层关系解析器。宏层随 query() 挂载为
    // `<实体>Rel.forName`（静态方法引用，类型 (String) -> Option<IRelation>）。
    // 未走宏 query() 的手工 Query 保持 None，includeAll 会抛带说明的 QueryException。
    var relResolver: Option<(String) -> Option<IRelation>> = None

    // Task 6: 嵌套 include 递归深度上限。正常 include 链（withInclude 链式构建）受
    // clone-on-write 约束天然无环且深度有限，但深度守卫是防御性保障：用户自定义 IRelation
    // 实现（getNested 自引用形成环）或未来 API 演化可能产生无限递归，深度超过该值即抛
    // QueryException 终止（避免栈溢出 / 死循环）。16 层足够覆盖任何实际嵌套场景。
    // 包级可见（无修饰符）：assembleRecursive（query_batch.cj extend）需要读取；
    // extend 不能新增成员变量，故该字段保留在本类。
    let MaxNestedDepth: Int64 = 16

    public init() {
        this.stmt = Statement()
        this.included = ArrayList<IRelation>()
        this.alias = ""
    }

    // I9: 拷贝当前 Query 的全部状态，供 Refine.all/one 在副本上执行 using()，
    // 保证调用方持有的 Query 不被执行上下文（queryDialect/columnOffset/executor）污染。
    // clauses/included 逐项拷贝：Statement 的 clauses 是可变 ArrayList，
    // Task 2 后 processIncluded 已是 no-op，但深拷贝隔离仍必要——批量装配（Task 3+）
    // 与执行路径可能在副本上追加/改写 clause，调用方持有的原 Query 必须不受影响；
    // clause 内部（Expr 数组）在现有代码中不会被原地修改，直接共享即可。
    // 注意：新增 Query 字段时必须同步更新此处 copy()，否则 Refine.all/one 副本会丢字段。
    public func copy(): Query<T> {
        let q = Query<T>()
        for (clause in stmt.clauses) {
            q.stmt.addClause(clause)
        }
        for (inc in included) {
            q.included.add(inc)
        }
        q.alias = alias
        q.executor = executor
        q.queryDialect = queryDialect
        q.mapper = mapper
        q.db = db
        q.columnOffset = columnOffset
        q.typeName = typeName
        q.ref = ref
        q.keyExtractor = keyExtractor
        q.rawIdExtractor = rawIdExtractor
        q.relResolver = relResolver
        q
    }

    public func dialect(d: Dialect): Query<T> {
        this.queryDialect = Some(d)
        this
    }

    public func select(fields: Array<Expr>): Query<T> {
        stmt.addClause(Clause.SelectClause(fields))
        this
    }

    public func from(alias: String): Query<T> {
        this.alias = alias
        stmt.addClause(FromClause(alias))
        this
    }

    public func filter(predicates: Array<Expr>): Query<T> {
        stmt.addClause(WhereClause(predicates))
        this
    }

    public func filter(predicate: Expr): Query<T> {
        stmt.addClause(WhereClause([predicate]))
        this
    }

    public func order(fields: Array<Expr>): Query<T> {
        stmt.addClause(OrderByClause(fields))
        this
    }

    public func limit(n: Int64): Query<T> {
        stmt.addClause(LimitClause(n))
        this
    }

    public func offset(n: Int64): Query<T> {
        stmt.addClause(OffsetClause(n))
        this
    }

    public func groupBy(fields: Array<Expr>): Query<T> {
        stmt.addClause(GroupByClause(fields))
        this
    }

    public func having(predicates: Array<Expr>): Query<T> {
        stmt.addClause(HavingClause(predicates))
        this
    }

    public func forUpdate(): Query<T> {
        stmt.addClause(LockClause)
        this
    }

    public func setMapper(m: (QueryResult, HashMap<String, Int64>) -> T): Unit {
        this.mapper = Some(m)
    }

    public func setKeyExtractor(k: (QueryResult, HashMap<String, Int64>) -> String): Unit {
        this.keyExtractor = Some(k)
    }

    // Task 4: 主实体主键原始值提取器（宏层 XxxRawIdFromResult 生成，随 query() 挂载）。
    public func setRawIdExtractor(r: (QueryResult, HashMap<String, Int64>) -> Any): Unit {
        this.rawIdExtractor = Some(r)
    }

    // Task 7: 挂载顶层关系解析器（宏层 query() 生成 `q.setRelResolver(<实体>Rel.forName)`）。
    public func setRelResolver(r: (String) -> Option<IRelation>): Unit {
        this.relResolver = Some(r)
    }

    // 包级可见（无修饰符）：page/all/one/count/exists/aggregate（query_exec.cj）与
    // updateWhere/deleteWhere（query_dml.cj）的 extend 块都会调用。
    func requireExecutor(): ExecutionContext {
        match (this.executor) {
            case Some(e) => e
            case None => throw QueryException(
                "No execution context set. Call using(session) or using(tx) before executing the query."
            )
        }
    }

    public func getDialect(): Dialect {
        match (this.queryDialect) {
            case Some(d) => d
            case None => SQLiteDialect()
        }
    }

    // 包级可见（无修饰符）：requireTable（query_dml.cj）与 assembleIncludes
    // （query_batch.cj）跨 extend 文件都会调用，故置于核心共享基础设施。
    func getSourceTable(): String {
        for (clause in stmt.clauses) {
            match (clause) {
                case Clause.FromClause(t) => return t
                case _ => ()
            }
        }
        ""
    }

    // 包级可见（无修饰符）：各执行方法（query_exec.cj/query_dml.cj）在 finally 中
    // 关闭自建的 Session，事务/外部传入的 executor 不在此关闭。
    func closeExecutor(exec: ExecutionContext): Unit {
        match (exec) {
            case s: Session => s.close()
            case _ => ()
        }
    }

    // 包级可见（无修饰符）：mapMainResult（query_batch.cj）在主映射循环内调用。
    func runAfterFindHooks(entity: T): Unit {
        if (typeName != "") {
            match (this.ref) {
                case Some(rf) =>
                    let s = Scope<T>(entity)
                    let err = rf.executeHooks(typeName, HookKind.AfterFind, s)
                    match (err) {
                        case Some(e) => throw e
                        case None => ()
                    }
                case None => ()   // 裸 Query 无 Refine 绑定，不触发 AfterFind
            }
        }
    }
}
