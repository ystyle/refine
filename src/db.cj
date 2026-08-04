package refine

import std.database.sql.{Datasource, Connection, Transaction, QueryResult, UpdateResult, Driver, DriverManager, PooledDatasource, TransactionIsoLevel}
import std.database.sql.Statement as SqlStatement
import std.collection.{ArrayList, HashMap}
import std.time.DateTime

// M19: Tx 生命周期状态机。初始 Unbegun；begin → Active；commit → Committed；
// rollback → RolledBack。非 Active 状态下的 execute/query/savepoint/commit/rollback
// 一律抛 RefineException，杜绝「已提交/已回滚事务继续执行 SQL」的静默坏数据路径。
// 注意：setIsolation 在 begin 之前被 Refine.transaction(level:) 调用，故不加状态守卫。
internal enum TxState {
    | Unbegun
    | Active
    | Committed
    | RolledBack
}

public class DB {
    private var datasource: Datasource
    private var paramOffset: Int64 = 0

    public init(datasource: Datasource) {
        this.datasource = datasource
    }

    public init(datasource: Datasource, paramOffset: Int64) {
        this.datasource = datasource
        this.paramOffset = paramOffset
    }

    public static func open(url: String): DB {
        open(url, [])
    }

    public static func open(url: String, opts: Array<(String, String)>): DB {
        let driverName = extractDriver(url)
        let drv = DriverManager.getDriver(driverName).getOrThrow()
        let ds = drv.open(url, opts)
        DB(PooledDatasource(ds), detectParamOffset(driverName))
    }

    public func session(): Session {
        Session(datasource.connect(), paramOffset)
    }

    public func getParamOffset(): Int64 { paramOffset }

    // 裸连接通道（包内/Refine 层用）；生命周期由调用方负责。
    internal func getRawConn(): Connection {
        datasource.connect()
    }

    // R-M12: 事务包装核心。ref 注入 Refine 实例后，action 内创建的 Tx 经
    // getDialect() 返回 ORM 方言并触发 hooks；裸事务（ref=None）仅做连接层事务
    // 语义（M19 状态守卫 + R-M12 isActive 判断 + best-effort 回滚），不触碰 ORM。
    // level 仅由 Refine.transaction(level:) 传入（内部路径），在 begin 之前
    // setIsolation，与历史 Refine 行为一致。
    public func transaction<T>(action: (Tx) -> T): T {
        runTransaction(None, None, action)
    }

    internal func transaction<T>(action: (Tx) -> T, ref: Option<Refine>): T {
        runTransaction(ref, None, action)
    }

    internal func transaction<T>(action: (Tx) -> T, ref: Option<Refine>, level: IsolationLevel): T {
        runTransaction(ref, Some(level), action)
    }

    private func runTransaction<T>(ref: Option<Refine>, level: Option<IsolationLevel>, action: (Tx) -> T): T {
        let conn = datasource.connect()
        try {
            let tx = match (ref) {
                case Some(rf) => Tx(conn, rf, paramOffset)
                case None => Tx(conn, paramOffset)
            }
            match (level) {
                case Some(l) => tx.setIsolation(l)
                case None => ()
            }
            tx.begin()
            try {
                let result = action(tx)
                // R-M12: 仅 Active 时自动 commit——action 内手动 commit 后外层跳过，
                // 避免 M19 守卫抛 "transaction is not active" 把成功路径转成异常。
                if (tx.isActive()) { tx.commit() }
                return result
            } catch (e: Exception) {
                // Fix 1 (M19 评审): best-effort 回滚——action 内手动 commit 后回滚会抛
                // "transaction is not active"，吞掉它，始终向上传播原始异常。
                try { tx.rollback() } catch (_: Exception) { () }
                throw e
            }
        } finally {
            conn.close()
        }
    }

    public func close(): Unit {
        datasource.close()
    }

    private static func extractDriver(url: String): String {
        match (url.indexOf(":")) {
            case Some(pos) => url[0..pos]
            case None => "sqlite"
        }
    }
}

public class Session {
    private var connection: Connection
    private var closed: Bool = false
    var paramOffset: Int64 = 0
    public var ref: Option<Refine> = None

    public init(connection: Connection) {
        this.connection = connection
    }

    public init(connection: Connection, paramOffset: Int64) {
        this.connection = connection
        this.paramOffset = paramOffset
    }

    public init(connection: Connection, ref: Refine, paramOffset: Int64) {
        this.connection = connection
        this.ref = Some(ref)
        this.paramOffset = paramOffset
    }

    public func prepareStatement(sql: String): SqlStatement {
        connection.prepareStatement(sql)
    }

    public func execute(sql: String, params: Array<Any>): UpdateResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.update()
    }

    public func query(sql: String, params: Array<Any>): QueryResult {
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.query()
    }

    public func getDialect(): Dialect {
        match (this.ref) {
            case Some(rf) => rf.getDialect()
            case None => throw RefineException(
                "bare DB session has no dialect, use Refine for ORM queries")
        }
    }

    // I9: close() 幂等。Query 执行路径（closeExecutor）与 Refine.all/one 的
    // finally 都可能关闭同一个 Session，幂等保证底层连接只被真正关闭一次。
    // 假设每个 Session 只被单个线程使用（check-then-set 非原子，并发 close 仍可能双关）。
    public func close(): Unit {
        if (!closed) {
            closed = true
            connection.close()
        }
    }
}

public class Tx {
    private var connection: Connection
    private var transaction: Transaction
    private var paramOffset: Int64 = 0
    private var state: TxState = TxState.Unbegun
    public var ref: Option<Refine> = None

    public init(connection: Connection) {
        this.connection = connection
        this.transaction = connection.createTransaction()
    }

    public init(connection: Connection, paramOffset: Int64) {
        this.connection = connection
        this.transaction = connection.createTransaction()
        this.paramOffset = paramOffset
    }

    public init(connection: Connection, ref: Refine, paramOffset: Int64) {
        this.connection = connection
        this.transaction = connection.createTransaction()
        this.ref = Some(ref)
        this.paramOffset = paramOffset
    }

    // M19: 状态守卫。execute/query/savepoint/commit/rollback 仅在 Active 状态合法。
    // commit/rollback 失败（底层驱动抛异常）时状态保持 Active，事务包装器仍可回滚。
    // 用 match 而非 !=/==：仓颉枚举默认不实现 Equatable（见 StorageType 手写模式）。
    private func assertActive(): Unit {
        match (state) {
            case TxState.Active => ()
            case _ => throw RefineException("transaction is not active")
        }
    }

    public func begin(): Unit {
        match (state) {
            case TxState.Unbegun => ()
            case _ => throw RefineException("transaction already begun")
        }
        transaction.begin()
        state = TxState.Active
    }

    public func commit(): Unit {
        assertActive()
        transaction.commit()
        state = TxState.Committed
    }

    public func rollback(): Unit {
        assertActive()
        transaction.rollback()
        state = TxState.RolledBack
    }

    // R-M12: 事务当前是否处于 Active 状态。事务包装器（Refine/DB.transaction）在
    // action 返回后据此决定是否自动 commit——action 内手动 commit 后状态为 Committed，
    // 外层跳过 auto-commit，避免 M19 守卫抛 "transaction is not active" 把成功路径
    // 变成异常。用 match 而非 ==（仓颉枚举默认不实现 Equatable）。
    public func isActive(): Bool {
        match (state) {
            case TxState.Active => true
            case _ => false
        }
    }

    public func save(name: String): Unit {
        assertActive()
        transaction.save(name)
    }

    public func rollbackTo(name: String): Unit {
        assertActive()
        transaction.rollback(name)
    }

    public func prepareStatement(sql: String): SqlStatement {
        // Fix 2 (M19 评审): 与 execute/query 一致加 Active 守卫——否则
        // `tx.prepareStatement(sql).update()` 可在事务结束后绕过状态机发 SQL。
        assertActive()
        connection.prepareStatement(sql)
    }

    public func execute(sql: String, params: Array<Any>): UpdateResult {
        assertActive()
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.update()
    }

    public func query(sql: String, params: Array<Any>): QueryResult {
        assertActive()
        let stmt = connection.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(stmt, i + paramOffset, params[i])
        }
        stmt.query()
    }

    public func getDialect(): Dialect {
        match (this.ref) {
            case Some(rf) => rf.getDialect()
            case None => throw RefineException(
                "bare DB session has no dialect, use Refine for ORM queries")
        }
    }

    public func getParamOffset(): Int64 { paramOffset }

    public func setIsolation(level: IsolationLevel): Unit {
        // R-M7: 不加 post-commit 状态守卫——M19 有意为之，setIsolation 由
        // Refine.transaction(level:) 在 begin() 之前调用（见类头注释），对未开始的
        // 事务设置 isoLevel；若在已提交/已回滚的事务上调用，仅设置无效果（驱动层
        // 不执行任何 SQL），不构成静默坏数据路径，故保持无守卫。
        // M5: 错误信息方言感知（dialect.name()），避免非 SQLite 方言报错信息张冠李戴
        if (!this.getDialect().hasIsolationSupport()) {
            throw RefineException(this.getDialect().name() + " does not support transaction isolation levels")
        }
        let mapped = match (level) {
            case ReadUncommitted => TransactionIsoLevel.ReadUncommitted
            case ReadCommitted => TransactionIsoLevel.ReadCommitted
            case RepeatableRead => TransactionIsoLevel.RepeatableRead
            case Serializable => TransactionIsoLevel.Serializable
        }
        transaction.isoLevel = mapped
    }
}

public interface ExecutionContext {
    func query(sql: String, params: Array<Any>): QueryResult
    func execute(sql: String, params: Array<Any>): UpdateResult
    func getDialect(): Dialect
    func getParamOffset(): Int64
    // R-I1: 执行上下文是否绑定 Refine 实例（Refine.session()/transaction 创建时携带，
    // 裸 Session/Tx 为 None）。Query.using(exec) 据此把 AfterFind hook 的触发权从
    // 执行上下文传播到 Query 副本，使 rf.transaction { tx => query().using(tx).all() }
    // 等常用路径与 query.using(rf).all() 行为一致。
    func getRef(): Option<Refine>

    // R-M5: queryAll/queryOne 的统一实现。原 Session/Tx 各有一份逐字节相同的 extend 块
    // （db.cj 旧 312-354），收敛为接口默认方法——Session/Tx 经 `<: ExecutionContext`
    // 继承，公共 API 不变，消除重复。
    func queryAll<T>(sql: String, params: Array<Any>,
                     mapper: (QueryResult, HashMap<String, Int64>) -> T): Array<T> {
        let result = this.query(sql, params)
        let offset = this.getParamOffset()
        let cm = buildColumnMap(result.columnInfos, offset)
        var entities = ArrayList<T>()
        while (result.next()) {
            entities.add(mapper(result, cm))
        }
        entities.toArray()
    }

    func queryOne<T>(sql: String, params: Array<Any>,
                     mapper: (QueryResult, HashMap<String, Int64>) -> T): Option<T> {
        let result = this.query(sql, params)
        let offset = this.getParamOffset()
        let cm = buildColumnMap(result.columnInfos, offset)
        if (result.next()) { Some(mapper(result, cm)) } else { None }
    }
}

extend Session <: ExecutionContext {
    public func getParamOffset(): Int64 { paramOffset }
    public func getRef(): Option<Refine> { ref }
}
extend Tx <: ExecutionContext {
    public func getRef(): Option<Refine> { ref }
}

func dispatchSet(stmt: SqlStatement, index: Int, value: Any): Unit {
    match (value) {
        case v: Int64    => stmt.set<Int64>(index, v)
        case v: Int32    => stmt.set<Int32>(index, v)
        // R-C2: 宏层接受 Int8/Int16/UInt8/UInt16/UInt32/UInt64 作实体字段并映射
        // StorageType.Integer（BIGINT 列），Float32 映射 StorageType.Float（DOUBLE 列）。
        // 修复前这些类型落 `case _ => setNull`，可空列静默写 NULL、NOT NULL 列报错——
        // 统一换算为存储表示后绑定：整数列存 Int64、单精度存 Float64。
        // UInt64 值超过 Int64.max 时转换抛运行时异常（BIGINT 有符号列本就存不下）。
        case v: Int8     => stmt.set<Int64>(index, Int64(v))
        case v: Int16    => stmt.set<Int64>(index, Int64(v))
        case v: UInt8    => stmt.set<Int64>(index, Int64(v))
        case v: UInt16   => stmt.set<Int64>(index, Int64(v))
        case v: UInt32   => stmt.set<Int64>(index, Int64(v))
        case v: UInt64   => stmt.set<Int64>(index, Int64(v))
        case v: String   => stmt.set<String>(index, v)
        case v: Bool     => stmt.set<Bool>(index, v)
        case v: Float64  => stmt.set<Float64>(index, v)
        case v: Float32  => stmt.set<Float64>(index, Float64(v))
        case v: DateTime => stmt.set<DateTime>(index, v)
        // F4: Option<DateTime> 可空软删字段写路径（宏层生成 allParams.add(entity.deleted_at)
        // 变量装箱，运行时类型保留，此分支命中）。Some 解包 set<DateTime>（软删打时间戳），
        // None 绑 NULL（未删行）。match 对类型化 Option 值匹配合法（Any 上 match None 才非法）。
        case v: Option<DateTime> =>
            match (v) {
                case Some(dt) => stmt.set<DateTime>(index, dt)
                case None => stmt.setNull(index)
            }
        case v: Array<UInt8> => stmt.set<Array<UInt8>>(index, v)
        // R-C2: 未知类型不再静默 setNull。Option 字段被宏层当关系字段跳过写路径
        // （不进入此函数），故写路径不存在合法 NULL 依赖 setNull——落到这里是
        // 用户传了非标量类型，抛错比静默写 NULL（数据损坏）安全。
        case _           => throw RefineException(
            "unsupported param type for dispatchSet: " + paramTypeName(value) +
            " (supported: Int8/Int16/Int32/Int64/UInt8/UInt16/UInt32/UInt64/" +
            "Float32/Float64/Bool/String/DateTime/Option<DateTime>/Array<UInt8>)")
    }
}

// R-C2: dispatchSet 兜底分支的错误信息辅助——命名未被 dispatchSet 处理的仓颉标量类型，
// 其余未知类型给 <unknown> 占位（类实例等无平台无关的运行时类型名获取方式）。
func paramTypeName(value: Any): String {
    match (value) {
        case _: Rune       => "Rune"
        case _: Float16    => "Float16"
        case _: IntNative  => "IntNative"
        case _: UIntNative => "UIntNative"
        case _             => "<unknown>"
    }
}
