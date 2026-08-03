package refine

import std.database.sql.{Datasource, Connection, Driver, DriverManager, PooledDatasource}
import std.collection.HashMap
import std.collection.ArrayList
import std.collection.HashSet
import std.convert.*

public class Refine {
    private var datasource: Datasource
    private var dialect: Dialect
    private var paramOffset: Int64 = 0
    private var hookRegistry = HashMap<String, ArrayList<Any>>()
    private var idGenerator: IdGenerator = SonyflakeIdGenerator()

    internal init(datasource: Datasource, dialect: Dialect, paramOffset: Int64) {
        this.datasource = datasource
        this.dialect = dialect
        this.paramOffset = paramOffset
    }

    public func getIdGenerator(): IdGenerator { idGenerator }

    public func setIdGenerator(gen: IdGenerator): Unit { idGenerator = gen }

    public static func open(url: String): Refine {
        open(url, [])
    }

    public static func open(url: String, opts: Array<(String, String)>): Refine {
        let driverName = extractDriver(url)
        let drv = DriverManager.getDriver(driverName).getOrThrow()
        let ds = drv.open(url, opts)
        let d = detectDialect(driverName)
        let offset = detectParamOffset(driverName)
        let pooled = PooledDatasource(ds)
        // M1: 接通 Dialect.initialize(db) 钩子。所有方言当前为空实现（SQLite/MySQL/PG），
        // 此调用为未来方言初始化（建表前环境准备、连接级配置等）提供挂载点；DB 包装
        // 只承载 datasource/dialect，不额外占用连接。
        d.initialize(DB(pooled, offset, d))
        Refine(pooled, d, offset)
    }

    public func session(): Session {
        Session(datasource.connect(), this, paramOffset)
    }

    public func transaction<T>(action: (Tx) -> T): T {
        let conn = datasource.connect()
        try {
            let tx = Tx(conn, this, paramOffset)
            tx.begin()
            try {
                let result = action(tx)
                // R-M12: action 内手动 commit 后状态为 Committed，isActive() = false，
                // 外层跳过 auto-commit——否则 M19 守卫抛 "transaction is not active"，
                // 把「成功返回」误转成异常。仅 Active 时才自动 commit。
                if (tx.isActive()) { tx.commit() }
                return result
            } catch (e: Exception) {
                // Fix 1 (M19 评审): 回滚为 best-effort——action 内手动 commit 后再抛
                // 异常时，tx.rollback() 会因状态已非 Active 抛 "transaction is not active"，
                // 若直接向上传播会把原始异常遮蔽掉。吞掉回滚错误，始终抛原始异常。
                // （真实回滚失败也选择记录而非覆盖原始异常，属标准模式。）
                try { tx.rollback() } catch (_: Exception) { () }
                throw e
            }
        } finally {
            conn.close()
        }
    }

    public func transaction<T>(level: IsolationLevel, action: (Tx) -> T): T {
        let conn = datasource.connect()
        try {
            let tx = Tx(conn, this, paramOffset)
            tx.setIsolation(level)
            tx.begin()
            try {
                let result = action(tx)
                // R-M12: 同上——仅 Active 时自动 commit，尊重 action 内的手动 commit。
                if (tx.isActive()) { tx.commit() }
                return result
            } catch (e: Exception) {
                try { tx.rollback() } catch (_: Exception) { () }
                throw e
            }
        } finally {
            conn.close()
        }
    }

    public func getDialect(): Dialect { dialect }

    public func getParamOffset(): Int64 { paramOffset }

    public func getRawConn(): Connection {
        datasource.connect()
    }

    public func hook<T>(typeName: String, kind: HookKind, hook: HookFn<T>): Unit {
        let key = typeName + ":" + kind.toString()
        match (hookRegistry.get(key)) {
            case Some(list) => list.add(hook)
            case None =>
                let list = ArrayList<Any>()
                list.add(hook)
                hookRegistry.add(key, list)
        }
    }

    public func executeHooks<T>(typeName: String, kind: HookKind, scope: Scope<T>): ?Exception {
        let key = typeName + ":" + kind.toString()
        match (hookRegistry.get(key)) {
            case Some(hooks) =>
                for (h in hooks) {
                    if (scope.aborted) { return scope.error }
                    let fn = (h as HookFn<T>).getOrThrow()
                    fn(scope)
                }
                if (scope.aborted) { return scope.error }
            case None => ()
        }
        None
    }

    public func clearHooks(): Unit {
        hookRegistry.clear()
    }

    // I9: 在 Query 副本上执行，绝不修改调用方持有的 Query（queryDialect/columnOffset/executor
    // 都被 using() 写进副本）；session 生命周期全部收敛在 try/finally：
    // 成功路径由 Query.closeExecutor 关闭（Session.close 幂等，finally 的 close 是 no-op），
    // 异常路径由 finally 兜底关闭，任何情况下底层连接恰好关闭一次。
    // R-I1: 副本必须绑定本 Refine 实例（copy.ref = Some(this)）。session() 创建的
    // Session 携带 ref = Some(this)，using(exec) 现也会自动传播；此处的显式赋值是
    // 双保险——即便未来 session 不携带 ref，Refine.all/one 仍保证触发本实例的 AfterFind。
    // R-M11: 调用方可能已用 using(rf)/using(db)/using(session) 预绑定 Session；下面的
    // using(s) 会覆盖 copy.executor，若先不关闭旧 Session，其底层连接将永远泄漏。
    // 故在覆盖前按 closeExecutor 语义关闭预绑定的 Session（预绑定 Tx 属外部生命周期，
    // 不在此关闭，执行只会改用本方法新建的 session）。
    public func all<T>(query: Query<T>): Array<T> {
        let s = session()
        try {
            let copy = query.copy()
            copy.ref = Some(this)
            match (copy.executor) {
                case Some(exec) => copy.closeExecutor(exec)
                case None => ()
            }
            return copy.using(s).all()
        } finally {
            s.close()
        }
    }

    public func one<T>(query: Query<T>): Option<T> {
        let s = session()
        try {
            let copy = query.copy()
            copy.ref = Some(this)
            match (copy.executor) {
                case Some(exec) => copy.closeExecutor(exec)
                case None => ()
            }
            return copy.using(s).one()
        } finally {
            s.close()
        }
    }

    public func migrator(): Migrator {
        dialect.migrator(DB(datasource, paramOffset, dialect))
    }

    public func close(): Unit {
        datasource.close()
    }
}

public func extractDriver(url: String): String {
    match (url.indexOf(":")) {
        case Some(pos) => url[0..pos]
        case None => "sqlite"
    }
}

public func parseId64(s: String): Int64 {
    Int64.parse(s)
}

public func detectDialect(name: String): Dialect {
    match (name) {
        case "mysql" | "mariadb" => MySQLDialect()
        case "postgres" | "postgresql" => PostgreSQLDialect()
        case _ => SQLiteDialect()
    }
}

public func detectParamOffset(driver: String): Int64 {
    if (driver == "mariadb") { 1 } else { 0 }
}

// visitedContains：级联 save/update 的对象引用去重，必须按引用相等（refEq）判断——
// 级联中新对象 id 都是 0，若按值相等会把两个不同新对象误判为同一对象而跳过。
// 保留 O(n) 线性扫描的原因：仓颉的 HashSet/HashMap 均按 Equatable 的 == 散列，
// 没有 identity-based 哈希集合（== 是值语义）；实体类默认未实现 Equatable 或
// == 为值比较，无法承载 refEq 语义。将 visited 换成「hash 化引用包装」方案可把
// contains 降为 O(1)，但会改变 visited 结构并波及宏生成的 cascade 签名，代价过高，
// 故保留线性扫描（深链/大集合下为 O(n²)，属已知约束，见 docs/plans/2026-08-01-cascade-save-design.md）。
public func visitedContains(visited: ArrayList<Object>, target: Object): Bool {
    for (v in visited) {
        if (refEq(v, target)) { return true }
    }
    false
}

// visitedKeyContains：级联 delete 的 (type, pk) 键去重。键是 String（值类型，
// 实现 Hashable & Equatable），可直接用 HashSet 提供 O(1) contains——cascadeDelete
// 对 N 个实体递归时，ArrayList 线性扫描会退化为 O(n²)（深链/大集合）。与 visitedContains
// 不同：String 键没有 identity 语义问题，故此处可以安全地哈希化。
// CascadeVisitedKeys 别名：宏生成的 cascadeDelete/deleteCascade 签名用它替代
// std.collection.HashSet<String>（宏展开上下文无法解析 std.collection 全限定路径，
// 见 relation_gen.cj buildCascadeMethods 注释），用户只需 import refine.* 即可使用。
public type CascadeVisitedKeys = HashSet<String>

public func visitedKeyContains(visited: CascadeVisitedKeys, key: String): Bool {
    visited.contains(key)
}
