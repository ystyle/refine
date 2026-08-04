package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.{ArrayList, HashMap}
import std.database.sql.{QueryResult, ColumnInfo as SqlColumnInfo, Connection, Datasource, ConnectionState, Transaction}
import std.database.sql.Statement as SqlStatement

// I14 回归：Query 直接执行路径（using(rf) 创建的 Session）在 AfterFind 钩子抛错时
// 必须 finally 关闭底层连接，否则池化连接泄漏。closedCount 追踪连接关闭次数。
class QueryTrackConnection <: Connection {
    public var stmt: CaptureStatement = CaptureStatement()
    public var closedCount: Int64 = 0
    public func close(): Unit { closedCount++ }
    public func isClosed(): Bool { closedCount > 0 }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }
    public func createTransaction(): Transaction { MockTransaction() }
    public func getMetaData(): HashMap<String, String> { HashMap<String, String>() }
    public func prepareStatement(sql: String): SqlStatement { stmt }
}

class QueryTrackDatasource <: Datasource {
    public var conn: QueryTrackConnection = QueryTrackConnection()
    public func connect(): Connection { conn }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func setOption(_key: String, _value: String): Unit {}
}

private func checkInt(v: Any, expected: Int64): Bool {
    match (v) {
        case i: Int64 => i == expected
        case _ => false
    }
}

private func checkStr(v: Any, expected: String): Bool {
    match (v) {
        case s: String => s == expected
        case _ => false
    }
}

@Test
public class QueryTest {
    @TestCase
    public func testQueryConstruction(): Unit {
        let q = Query<Int64>()
        @Expect(q.stmt.clauses.size, 0)
        @Expect(q.included.size, 0)
        @Expect(q.alias, "")
    }

    @TestCase
    public func testSelectAddsClause(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id"), Expr.Column("name")])
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.SelectClause(fields) => @Expect(fields.size, 2)
            case _ => @Fail("expected SelectClause")
        }
    }

    @TestCase
    public func testWhereSinglePredicate(): Unit {
        let q = Query<Int64>()
        q.filter(Expr.Binary(Expr.Column("age"), BinOp.Gt, Expr.Value(18)))
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.WhereClause(predicates) => @Expect(predicates.size, 1)
            case _ => @Fail("expected WhereClause")
        }
    }

    @TestCase
    public func testWhereMultiplePredicates(): Unit {
        let q = Query<Int64>()
        q.filter([
            Expr.Binary(Expr.Column("age"), BinOp.Gt, Expr.Value(18)),
            Expr.Binary(Expr.Column("status"), BinOp.Eq, Expr.Value("active"))
        ])
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.WhereClause(predicates) => @Expect(predicates.size, 2)
            case _ => @Fail("expected WhereClause")
        }
    }

    @TestCase
    public func testOrderBy(): Unit {
        let q = Query<Int64>()
        q.order([Expr.FuncCall("DESC", [Expr.Column("created_at")])])
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.OrderByClause(fields) => @Expect(fields.size, 1)
            case _ => @Fail("expected OrderByClause")
        }
    }

    @TestCase
    public func testLimit(): Unit {
        let q = Query<Int64>()
        q.limit(10)
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.LimitClause(n) => @Expect(n, 10)
            case _ => @Fail("expected LimitClause")
        }
    }

    @TestCase
    public func testOffset(): Unit {
        let q = Query<Int64>()
        q.offset(100)
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.OffsetClause(n) => @Expect(n, 100)
            case _ => @Fail("expected OffsetClause")
        }
    }

    @TestCase
    public func testGroupBy(): Unit {
        let q = Query<Int64>()
        q.groupBy([Expr.Column("dept")])
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.GroupByClause(fields) => @Expect(fields.size, 1)
            case _ => @Fail("expected GroupByClause")
        }
    }

    @TestCase
    public func testHaving(): Unit {
        let q = Query<Int64>()
        q.having([Expr.Binary(Expr.Column("count"), BinOp.Gt, Expr.Value(5))])
        @Expect(q.stmt.clauses.size, 1)
        match (q.stmt.clauses[0]) {
            case Clause.HavingClause(predicates) => @Expect(predicates.size, 1)
            case _ => @Fail("expected HavingClause")
        }
    }

    @TestCase
    public func testAllRequiresMapper(): Unit {
        let q = Query<Int64>()
        try {
            let _ = q.all()
            @Fail("expected QueryException")
        } catch (_: QueryException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testInclude(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel: IRelation = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let q = Query<Int64>()
        q.include(rel)
        @Expect(q.included.size, 1)
    }

    @TestCase
    public func testMethodChaining(): Unit {
        let q = Query<Int64>()
            .filter(Expr.Binary(Expr.Column("age"), BinOp.Gt, Expr.Value(18)))
            .order([Expr.Column("name")])
            .limit(10)
            .offset(20)
        @Expect(q.stmt.clauses.size, 4)
        match (q.stmt.clauses[0]) {
            case Clause.WhereClause(_) => ()
            case _ => @Fail("expected first clause to be WhereClause")
        }
        match (q.stmt.clauses[1]) {
            case Clause.OrderByClause(_) => ()
            case _ => @Fail("expected second clause to be OrderByClause")
        }
        match (q.stmt.clauses[2]) {
            case Clause.LimitClause(n) => @Expect(n, 10)
            case _ => @Fail("expected third clause to be LimitClause")
        }
        match (q.stmt.clauses[3]) {
            case Clause.OffsetClause(n) => @Expect(n, 20)
            case _ => @Fail("expected fourth clause to be OffsetClause")
        }
    }

    @TestCase
    public func testWhereOrderByLimitChain(): Unit {
        let q = Query<Int64>()
            .select([Expr.Column("id"), Expr.Column("name")])
            .filter(Expr.Binary(Expr.Column("age"), BinOp.Gt, Expr.Value(18)))
            .order([Expr.Column("name")])
            .limit(10)
        @Expect(q.stmt.clauses.size, 4)
        match (q.stmt.clauses[0]) {
            case Clause.SelectClause(fields) => @Expect(fields.size, 2)
            case _ => @Fail("expected SelectClause")
        }
        match (q.stmt.clauses[1]) {
            case Clause.WhereClause(predicates) => @Expect(predicates.size, 1)
            case _ => @Fail("expected WhereClause")
        }
        match (q.stmt.clauses[2]) {
            case Clause.OrderByClause(fields) => @Expect(fields.size, 1)
            case _ => @Fail("expected OrderByClause")
        }
        match (q.stmt.clauses[3]) {
            case Clause.LimitClause(n) => @Expect(n, 10)
            case _ => @Fail("expected LimitClause")
        }
    }

    @TestCase
    public func testIncludeRegistersRefTo(): Unit {
        let q = Query<Int64>()
        @Expect(q.included.size, 0)
        // Add RefTo - not a collection
        let fk = Col<Any>("user_id")
        let refTo: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id")], "users", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        q.include(refTo)
        @Expect(q.included.size, 1)
    }

    @TestCase
    public func testIncludeRegistersHasMany(): Unit {
        let q = Query<Int64>()
        let rel: IRelation = HasMany<Int64>("posts", "user_id", [Col<Any>("id")], "posts", dummyMapper, dummySetter, dummyTargetIdExtractor)
        q.include(rel)
        @Expect(q.included.size, 1)
    }

    @TestCase
    public func testFieldOverrideRelationResolve(): Unit {
        let inner: IRelation = HasMany<Int64>("tags", "post_id", [Col<Any>("id")], "tags", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let wrapper = FieldOverrideRelation(inner, [Col<Any>("name")])
        let (kind, name, _, fk, _, fields) = wrapper.resolve()
        @Expect(kind, RelationKind.HasManyRel)
        @Expect(name, "tags")
        @Expect(fields.size, 1)
    }

    @TestCase
    public func testCount(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        @Expect(q.stmt.clauses.size >= 2, true)
    }

    @TestCase
    public func testExists(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        @Expect(q.stmt.clauses.size >= 2, true)
    }

    @TestCase
    public func testExistsUsesSelectOneLimitOne(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = RowQueryResult(1)
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .filter(Expr.Binary(Expr.Column("a"), BinOp.Eq, Expr.Value(1)))
            .using(tx)
        let exists = q.exists()
        @Expect(exists, true)
        @Expect(conn.stmt.capturedSqlHistory.size >= 1, true)
        let sql = conn.stmt.capturedSqlHistory[0]
        // I13: exists() 必须用 SELECT 1 ... LIMIT 1，而不是全表 COUNT(*)
        @Expect(sql.contains("SELECT 1"), true)
        @Expect(sql.contains("LIMIT 1"), true)
        @Expect(sql.contains("COUNT"), false)
    }

    @TestCase
    public func testExistsFalseWhenNoRows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = MapperMockQueryResult([], [])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        let exists = q.exists()
        @Expect(exists, false)
    }

    @TestCase
    public func testFrom(): Unit {
        let q = Query<Int64>()
        q.from("mytable")
        @Expect(q.stmt.clauses.size, 1)
    }

    @TestCase
    public func testLimitAndOffset(): Unit {
        let q = Query<Int64>()
        q.limit(10)
        q.offset(5)
        var hasLimit = false
        var hasOffset = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.LimitClause(n) => hasLimit = true; @Expect(n, 10)
                case Clause.OffsetClause(n) => hasOffset = true; @Expect(n, 5)
                case _ => ()
            }
        }
        @Expect(hasLimit, true)
        @Expect(hasOffset, true)
    }

    // R-I3: one() 必须剥离已存在的 LIMIT/OFFSET 再追加 LIMIT 1。
    // 修复前 one() 复制全部子句（含 LimitClause(5)/OffsetClause(3)）再追加
    // LimitClause(1) → "LIMIT 5 LIMIT 1"（或 LIMIT/OFFSET 混排）三方言均语法错误。
    @TestCase
    public func testOneStripsExistingLimitAndOffset(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = MapperMockQueryResult([], [])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .limit(5)
            .offset(3)
            .using(tx)
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        let res = q.one()
        @Expect(res.isNone(), true)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT \"id\" FROM \"t\" LIMIT 1")
    }

    @TestCase
    public func testOneWithOnlyOffsetStillLimitsOne(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = MapperMockQueryResult([], [])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .offset(3)
            .using(tx)
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        let res = q.one()
        @Expect(res.isNone(), true)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT \"id\" FROM \"t\" LIMIT 1")
    }

    @TestCase
    public func testIncludeWithFieldsOverride(): Unit {
        let q = Query<Int64>()
        let rel: IRelation = HasMany<Int64>("posts", "user_id", [Col<Any>("id")], "posts", dummyMapper, dummySetter, dummyTargetIdExtractor)
        q.include(rel, [Col<Any>("title"), Col<Any>("body")])
        @Expect(q.included.size, 1)
        let (_, _, _, _, _, fields) = q.included[0].resolve()
        @Expect(fields.size, 2)
    }

    @TestCase
    public func testRequireExecutorThrows(): Unit {
        // Query without executor should throw when accessing requireExecutor
        // This is indirectly tested via all() which calls requireExecutor
        let q = Query<Int64>()
        try {
            q.all()
            @Fail("expected QueryException")
        } catch (_: QueryException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testChainAllMethods(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
            .from("t")
            .filter(Expr.Binary(Expr.Column("a"), BinOp.Gt, Expr.Value(1)))
            .order([Expr.Column("a")])
            .limit(5)
            .offset(10)
        @Expect(q.stmt.clauses.size, 6)
    }

    @TestCase
    public func testOneWithoutMapper(): Unit {
        let q = Query<Int64>()
        try {
            let _ = q.one()
            @Fail("expected QueryException")
        } catch (_: QueryException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testOneWithMapper(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        @Expect(q.mapper.isSome(), true)
        // mapper 已注册：one() 不再抛 "No auto-mapper"，而应因缺 executor 抛 QueryException
        try {
            let _ = q.one()
            @Fail("expected QueryException for missing executor")
        } catch (e: QueryException) {
            @Expect(e.message.contains("No execution context"), true)
        }
    }

    @TestCase
    public func testWhereMetaAlias(): Unit {
        let dialect = SQLiteDialect()
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("t")
        q.filter(Expr.Binary(Expr.Column("x"), BinOp.Eq, Expr.Value(1)))
        var found = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.WhereClause(p) => found = true; @Expect(p.size, 1)
                case _ => ()
            }
        }
        @Expect(found, true)
    }

    @TestCase
    public func testGetDialectDefault(): Unit {
        let q = Query<Int64>()
        @Expect(q.getDialect().name(), "sqlite")
    }

    @TestCase
    public func testSetMapper(): Unit {
        let q = Query<Int64>()
        @Expect(q.mapper.isNone(), true)
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        @Expect(q.mapper.isSome(), true)
    }

    @TestCase
    public func testBuildColumnMap(): Unit {
        let mockInfo = MockColumnInfo()
        let infos: Array<SqlColumnInfo> = [mockInfo]
        let cm = buildColumnMap(infos, 0)
        @Expect(cm.size, 1)
    }

    @TestCase
    public func testAllPropagatesMapperException(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        try {
            q.all({ r: QueryResult, cm: HashMap<String, Int64> =>
                throw QueryException("mapper boom")
            })
            @Fail("expected QueryException from mapper")
        } catch (e: QueryException) {
            @Expect(e.message, "mapper boom")
        }
    }

    @TestCase
    public func testAllPropagatesMapperExceptionOnLaterRow(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        let rows = [
            Array<Any>(1, {i => 1}),
            Array<Any>(1, {i => 2})
        ]
        conn.stmt.queryResult = MapperMockQueryResult(cols, rows)
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        try {
            q.all({ r: QueryResult, cm: HashMap<String, Int64> =>
                let id = r.get<Int64>(0)
                if (id == 2) {
                    throw QueryException("mapper boom on row 2")
                }
                0
            })
            @Fail("expected QueryException from mapper")
        } catch (e: QueryException) {
            @Expect(e.message, "mapper boom on row 2")
        }
    }

    @TestCase
    public func testAllPropagatesAfterFindHookException(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.hook<Int64>("C1AfterFindBoom", HookKind.AfterFind) { scope: Scope<Int64> =>
            throw QueryException("hook boom")
        }
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        q.typeName = "C1AfterFindBoom"
        q.ref = Some(rf)
        try {
            q.all({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
            @Fail("expected QueryException from AfterFind hook")
        } catch (e: QueryException) {
            @Expect(e.message, "hook boom")
        }
    }

    // I14: AfterFind 钩子调用 scope.abort() 时，executeHooks 返回的错误必须上抛，
    // 而不是被静默忽略（修复前 runAfterFindHooks 丢弃返回值）。
    @TestCase
    public func testAllPropagatesAfterFindHookAbort(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.hook<Int64>("C1AfterFindAbort", HookKind.AfterFind) { scope: Scope<Int64> =>
            scope.abort(QueryException("hook abort"))
        }
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        q.typeName = "C1AfterFindAbort"
        q.ref = Some(rf)
        try {
            q.all({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
            @Fail("expected QueryException from AfterFind hook abort")
        } catch (e: QueryException) {
            @Expect(e.message, "hook abort")
        }
    }

    // I14: 裸 Query（未绑定 Refine 实例）不触发 AfterFind —— 钩子只挂在实例级注册表上
    @TestCase
    public func testBareQueryDoesNotFireAfterFind(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let flag = HookFlag()
        rf.hook<Int64>("BareAfterFind", HookKind.AfterFind) { scope: Scope<Int64> =>
            flag.called = true
        }
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        q.typeName = "BareAfterFind"
        let rows = q.all({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        @Expect(rows.size, 1)
        @Expect(flag.called, false)
    }

    // I14: 同一查询绑定 Refine 实例后 AfterFind 正常触发（与裸 Query 对照）
    @TestCase
    public func testBoundQueryFiresAfterFind(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let flag = HookFlag()
        rf.hook<Int64>("BoundAfterFind", HookKind.AfterFind) { scope: Scope<Int64> =>
            flag.called = true
        }
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        q.typeName = "BoundAfterFind"
        q.ref = Some(rf)
        let rows = q.all({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        @Expect(rows.size, 1)
        @Expect(flag.called, true)
    }

    // R-I1 延续: using(session) 必须从携带 ref 的 Session 传播 Refine 绑定。
    // rf.session() 创建 Session(conn, rf, paramOffset) → ref = Some(rf)；修复前
    // using(exec) 只设 executor/queryDialect/columnOffset，此路径静默跳过 AfterFind。
    @TestCase
    public func testRefSessionCarriesRefFiresAfterFind(): Unit {
        let ds = QueryTrackDatasource()
        let rf = Refine(ds, SQLiteDialect(), 0)
        let flag = HookFlag()
        rf.hook<Int64>("RfSessionPropHook", HookKind.AfterFind) { scope: Scope<Int64> =>
            flag.called = true
        }
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        ds.conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let s = rf.session()
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(s)
        q.typeName = "RfSessionPropHook"
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        let rows = q.all()
        @Expect(rows.size, 1)
        @Expect(flag.called, true)
        s.close()
    }

    // R-I1 延续: 裸 Session（无 ref）不得触发 AfterFind，镜像裸 Tx 约束。
    @TestCase
    public func testBareSessionDoesNotFireAfterFind(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let flag = HookFlag()
        rf.hook<Int64>("BareSessionAfterFind", HookKind.AfterFind) { scope: Scope<Int64> =>
            flag.called = true
        }
        let s = Session(conn)
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(s)
        q.typeName = "BareSessionAfterFind"
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        let rows = q.all()
        @Expect(rows.size, 1)
        @Expect(flag.called, false)
        s.close()
    }

    // I14 回归：using(rf) 直接执行路径（rf.session() 持有真实连接）在 AfterFind 钩子
    // 抛错时，Session 必须 finally 关闭（修复前 closeExecutor 被跳过 → 连接泄漏）。
    @TestCase
    public func testAfterFindThrowClosesSessionAll(): Unit {
        let ds = QueryTrackDatasource()
        let rf = Refine(ds, SQLiteDialect(), 0)
        rf.hook<Int64>("LeakAll", HookKind.AfterFind) { scope: Scope<Int64> =>
            throw QueryException("hook boom all")
        }
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        ds.conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(rf)
        q.typeName = "LeakAll"
        try {
            q.all({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
            @Fail("expected QueryException from AfterFind hook")
        } catch (e: QueryException) {
            @Expect(e.message, "hook boom all")
        }
        @Expect(ds.conn.closedCount, 1)
    }

    @TestCase
    public func testAfterFindThrowClosesSessionOne(): Unit {
        let ds = QueryTrackDatasource()
        let rf = Refine(ds, SQLiteDialect(), 0)
        rf.hook<Int64>("LeakOne", HookKind.AfterFind) { scope: Scope<Int64> =>
            throw QueryException("hook boom one")
        }
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        ds.conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})])
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(rf)
        q.typeName = "LeakOne"
        try {
            q.one({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
            @Fail("expected QueryException from AfterFind hook")
        } catch (e: QueryException) {
            @Expect(e.message, "hook boom one")
        }
        @Expect(ds.conn.closedCount, 1)
    }

    // R-M4: page() 未挂 auto-mapper 时抛带说明的 QueryException（与 all()/one() 一致），
    // 而非 Option.getOrThrow 的裸错误。
    @TestCase
    public func testPageNoMapperThrowsFriendlyError(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        try {
            q.page(1, 10)
            @Fail("expected QueryException for missing auto-mapper")
        } catch (e: QueryException) {
            @Expect(e.message.contains("No auto-mapper"), true)
        }
    }

    @TestCase
    public func testAfterFindThrowClosesSessionPage(): Unit {
        let ds = QueryTrackDatasource()
        let rf = Refine(ds, SQLiteDialect(), 0)
        rf.hook<Int64>("LeakPage", HookKind.AfterFind) { scope: Scope<Int64> =>
            throw QueryException("hook boom page")
        }
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        ds.conn.stmt.queryResultQueue.add(RowQueryResult(1))
        ds.conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [Array<Any>(1, {i => 1})]))
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(rf)
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        q.typeName = "LeakPage"
        try {
            q.page(1, 10)
            @Fail("expected QueryException from AfterFind hook")
        } catch (e: QueryException) {
            @Expect(e.message, "hook boom page")
        }
        @Expect(ds.conn.closedCount, 1)
    }

    // batch include Task 3：ref_to 装配改为主查询 + 批量 IN 查询协议。
    // processIncluded 是 no-op（主查询不生成 JOIN），批量装配在 all() 主查询后触发：
    // 断言两次查询（主查询 + `SELECT ... FROM "user" WHERE "id" IN (?)`）与装配结果。
    @TestCase
    public func testRefToIncludeIssuesBatchQuery(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        // 主查询：postWithRel 自身列（user_id=99）
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else if (i == 2) { 99 } else { 0 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        // 批量查询：user 表 id IN (99)
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("email", false),
        ]
        let userRow = Array<Any>(3, {i => if (i == 0) { 99 } else if (i == 1) { "Alice" } else { "a@x.com" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let q = PostWithRel.query().include(PostWithRelRel.author).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("LEFT JOIN"), false)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"user\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.isSome(), true)
        @Expect(entities[0].author.getOrThrow().id, 99)
    }

    // batch include Task 4：has_many 批量装配协议。主查询返回 2 篇 Post，批量查询
    // `SELECT ... FROM "comment" WHERE "post_id" IN (主实体 id)` 按 fk 分组回填各实体。
    @TestCase
    public func testHasManyIncludeAssemblesBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [
            Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 0 }}),
            Array<Any>(4, {i => if (i == 0) { 2 } else if (i == 1) { "p2" } else { 0 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "first" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { "second" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 12 } else if (i == 1) { "third" } else { 2 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = PostWithRel.query().include(PostWithRelRel.comments).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("LEFT JOIN"), false)
        // 批量 SELECT 强制主键 id + fk 分组键 post_id + 字段并集 body
        @Expect(conn.stmt.capturedSqlHistory[1].contains("SELECT \"id\", \"post_id\", \"body\" FROM \"comment\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?, ?)"), true)
        @Expect(entities.size, 2)
        @Expect(entities[0].id, 1)
        @Expect(entities[0].comments.size, 2)
        @Expect(entities[0].comments[0].id, 10)
        @Expect(entities[0].comments[0].body, "first")
        @Expect(entities[0].comments[0].post_id, 1)
        @Expect(entities[0].comments[1].id, 11)
        @Expect(entities[1].id, 2)
        @Expect(entities[1].comments.size, 1)
        @Expect(entities[1].comments[0].id, 12)
        @Expect(entities[1].comments[0].post_id, 2)
    }

    // batch include Task 5：ref_many 改为 junction 批量查询装配，主查询无 JOIN。
    // 主查询返回 Post 实体后，按中间表 post_tags JOIN 目标表批量取关联 Tag 回填。
    @TestCase
    public func testProcessIncludedRefMany(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 1 } else { "p" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("postWithRel_id", false),
        ]
        let batchRows = [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "t" } else { 1 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = PostWithRel.query().include(PostWithRelRel.tags).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        // 主查询不再生成 include JOIN
        @Expect(conn.stmt.capturedSqlHistory[0].contains("JOIN"), false)
        // junction 批量查询：中间表 JOIN 目标表（INNER JOIN）+ 中间表源 id IN 主实体 id
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"post_tags\" JOIN \"tag\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("\"post_tags\".\"tag_id\" = \"tag\".\"id\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("\"post_tags\".\"postWithRel_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].tags.size, 1)
        @Expect(entities[0].tags[0].id, 9)
        @Expect(entities[0].tags[0].name, "t")
    }

    // ref_many 批量装配基础：2 个 Post × 各自 tags，按中间表源 id 正确分组回填。
    @TestCase
    public func testRefManyIncludeAssemblesBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "p1" }}),
            Array<Any>(2, {i => if (i == 0) { 2 } else { "p2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("postWithRel_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { "t2" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 12 } else if (i == 1) { "t3" } else { 2 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = PostWithRel.query().include(PostWithRelRel.tags).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?, ?)"), true)
        @Expect(entities.size, 2)
        @Expect(entities[0].tags.size, 2)
        @Expect(entities[0].tags[0].id, 10)
        @Expect(entities[0].tags[0].name, "t1")
        @Expect(entities[0].tags[1].id, 11)
        @Expect(entities[0].tags[1].name, "t2")
        @Expect(entities[1].tags.size, 1)
        @Expect(entities[1].tags[0].id, 12)
        @Expect(entities[1].tags[0].name, "t3")
    }

    // ref_many 空装配：中间表无该源 id 的行 → 批量查询空结果 → tags 保持空列表。
    @TestCase
    public func testRefManyIncludeEmptyNoJunctionRows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 5 } else { "lonely" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("postWithRel_id", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, []))
        let q = PostWithRel.query().include(PostWithRelRel.tags).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(entities.size, 1)
        @Expect(entities[0].tags.size, 0)
    }

    // ref_many 同 (via, 目标表) 多个关系合并为一条 junction 批量查询。
    // rel2 用 dummy setter 只验证 SQL 合并路径；真实回填由 tags 完成。
    @TestCase
    public func testRefManyIncludeMergesSameViaTarget(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 1 } else { "p" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("postWithRel_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { "t2" } else { 1 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let rel2: IRelation = RefMany<Int64>("moreTags", "post_tags",
            [Col<Any>("name")], "tag", dummyMapper, dummySetter, "tag_id", dummyTargetIdExtractor)
        let q = PostWithRel.query().include(PostWithRelRel.tags).include(rel2).using(tx)
        let entities = q.all()
        // 主查询 + 1 条合并的 junction 批量查询
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].tags.size, 2)
        @Expect(entities[0].tags[0].id, 10)
        @Expect(entities[0].tags[1].id, 11)
    }

    // ref_many 孤儿中间表行（指向已删目标）：INNER JOIN 语义下批量查询不返回该行，
    // 装配不抛错、该源实体不获得该关联（跳过）。
    @TestCase
    public func testRefManyIncludeOrphanJunctionSkipped(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "p1" }}),
            Array<Any>(2, {i => if (i == 0) { 2 } else { "p2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("postWithRel_id", false),
        ]
        // p2 的中间表行指向已删除的 tag → INNER JOIN 过滤后不出现在批量结果
        let batchRows = [Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 1 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = PostWithRel.query().include(PostWithRelRel.tags).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        // 必须是 INNER JOIN 而非 LEFT JOIN：孤儿行被数据库侧过滤
        @Expect(conn.stmt.capturedSqlHistory[1].contains("LEFT JOIN"), false)
        @Expect(conn.stmt.capturedSqlHistory[1].contains(" JOIN \""), true)
        @Expect(entities.size, 2)
        @Expect(entities[0].tags.size, 1)
        @Expect(entities[0].tags[0].id, 10)
        @Expect(entities[1].tags.size, 0)
    }

    // ref_many String-pk 主实体：中间表源 id 列按 String 读取分组（isStringPk 分支）。
    // 主实体主键是 String，rawId 用 String 值作为 IN 参数。
    @TestCase
    public func testRefManyIncludeStringPkMainEntity(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { "p-a" } else { "post" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("uuidKeyTagPost_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { "t1" } else if (i == 1) { "one" } else { "p-a" }}),
            Array<Any>(3, {i => if (i == 0) { "t2" } else if (i == 1) { "two" } else { "p-a" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = UuidKeyTagPost.query().include(UuidKeyTagPostRel.tags).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("WHERE \"uuid_key_tag_post_tags\".\"uuidKeyTagPost_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].tags.size, 2)
        @Expect(entities[0].tags[0].id, "t1")
        @Expect(entities[0].tags[0].name, "one")
        @Expect(entities[0].tags[1].id, "t2")
        @Expect(entities[0].tags[1].name, "two")
    }

    // 手工构造 RefMany 漏传 junctionTargetCol（空串）→ 装配在发 junction 批量查询前
    // 抛带说明的 QueryException，而不是生成 `"via".""_id` 的坏 SQL。
    @TestCase
    public func testRefManyIncludeMissingJunctionTargetColThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 1 } else { "p" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let rel: IRelation = RefMany<Int64>("tags", "post_tags",
            [Col<Any>("id")], "tag", dummyMapper, dummySetter, "", dummyTargetIdExtractor)
        let q = PostWithRel.query().include(rel).using(tx)
        try {
            let _ = q.all()
            @Fail("expected QueryException for empty junction target column")
        } catch (e: QueryException) {
            @Expect(e.message.contains("junction target column"), true)
        }
        // 主查询已发出，junction 批量查询被前置校验拦截
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
    }

    // 手写 Query 未设 FROM 却 include ref_many（junction 源列 `<源表>_id` 无从推导）→
    // 装配 fail-fast 抛带说明的 QueryException，而不是静默留下空关联列表。
    @TestCase
    public func testRefManyIncludeWithoutSourceTableThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        let mainRows = [Array<Any>(1, {i => 1})]
        conn.stmt.queryResult = MapperMockQueryResult(mainCols, mainRows)
        let rel: IRelation = RefMany<Int64>("tags", "post_tags",
            [Col<Any>("id")], "tag", dummyMapper, dummySetter, "tag_id", dummyTargetIdExtractor)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        q.setRawIdExtractor({ r: QueryResult, cm: HashMap<String, Int64> => 1 })
        q.include(rel)
        q.using(tx)
        try {
            let _ = q.all()
            @Fail("expected QueryException for missing source table")
        } catch (e: QueryException) {
            @Expect(e.message.contains("source table"), true)
        }
    }

    // 同一查询同时 include has_many 与 ref_many：两个集合装配协议各自独立跑一条批量查询，
    // 互不干扰（顺序：主查询 → has_many fk IN → ref_many junction）。
    @TestCase
    public func testHasManyAndRefManyMixedInclude(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 1 } else { "p1" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        // has_many comments：SELECT "id", "post_id", "body" FROM "comment" WHERE "post_id" IN (?)
        let commentsCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("post_id", false),
            MapperMockColumnInfo("body", false),
        ]
        let commentsRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { 1 } else { "first" }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { 1 } else { "second" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(commentsCols, commentsRows))
        // ref_many tags：SELECT "tag"."id", "tag"."name", "post_tags"."postWithRel_id"
        // FROM "post_tags" JOIN "tag" ON ... WHERE "post_tags"."postWithRel_id" IN (?)
        let tagsCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("postWithRel_id", false),
        ]
        let tagsRows = [
            Array<Any>(3, {i => if (i == 0) { 20 } else if (i == 1) { "t1" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 21 } else if (i == 1) { "t2" } else { 1 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(tagsCols, tagsRows))
        let q = PostWithRel.query().include(PostWithRelRel.comments).include(PostWithRelRel.tags).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"comment\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"post_tags\" JOIN \"tag\""), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].comments.size, 2)
        @Expect(entities[0].comments[0].id, 10)
        @Expect(entities[0].comments[0].body, "first")
        @Expect(entities[0].tags.size, 2)
        @Expect(entities[0].tags[0].id, 20)
        @Expect(entities[0].tags[0].name, "t1")
    }

    @TestCase
    public func testIncludeDoesNotGenerateJoin(): Unit {
        // Task 2: include 走批量装配，不生成 include JOIN（原 processIncluded 无 JOIN 挂接，
        // R-M3 已删除该 no-op 方法，此处保留「include 不改写主查询」的回归断言）
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        let fk = Col<Any>("user_id")
        let rel: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id")], "users", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        q.include(rel)
        let dialect = SQLiteDialect()
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("LEFT JOIN"), false)
    }

    // batch include Task 4：has_one 批量装配协议。主查询返回 1 个 User，批量查询
    // `SELECT ... FROM "profileWithRel" WHERE "user_id" IN (主实体 id)` 挂载唯一 Profile。
    @TestCase
    public func testHasOneIncludeAssemblesBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 7 } else { "nobody" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("bio", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let batchRows = [Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "dev" } else { 7 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = UserWithRel.query().include(UserWithRelRel.profile).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"profileWithRel\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 7)
        @Expect(entities[0].profile.isSome(), true)
        @Expect(entities[0].profile.getOrThrow().id, 1)
        @Expect(entities[0].profile.getOrThrow().bio, "dev")
        @Expect(entities[0].profile.getOrThrow().user_id, 7)
    }

    // ─── updateWhere / deleteWhere / forUpdate 渲染 ───

    @TestCase
    public func testUpdateWhereRendersSQL(): Unit {
        let q = Query<Int64>()
        q.from("users")
        q.filter(Col<Int64>("age") > 18)
        let stmt = Statement()
        stmt.addClause(UpdateClause("users", ["name", "email"], ["bob", "bob@t.com"]))
        stmt.addClause(WhereClause([Col<Int64>("age") > 18]))
        let dialect = MySQLDialect()
        let (sql, params) = dialect.render(stmt)
        @Expect(sql, "UPDATE `users` SET `name` = ?, `email` = ? WHERE `age` > ?")
        @Expect(params.size, 3)
    }

    @TestCase
    public func testDeleteWhereRendersSQL(): Unit {
        let stmt = Statement()
        stmt.addClause(DeleteClause("users"))
        stmt.addClause(WhereClause([Col<Int64>("age") > 18]))
        let dialect = MySQLDialect()
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "DELETE FROM `users` WHERE `age` > ?")
    }

    // 回归（I4）：updateWhere 带 JOIN 必须拒绝，避免 dialect 渲染静默丢弃 JOIN 导致误更新
    @TestCase
    public func testUpdateWhereRejectsJoin(): Unit {
        let q = Query<Int64>()
        q.from("users")
        q.stmt.addClause(JoinClause("posts", "p", Expr.Binary(Expr.Column("user_id"), BinOp.Eq, Expr.Column("id"))))
        try {
            q.updateWhere(["name"], ["bob"])
            @Fail("expected QueryException")
        } catch (e: QueryException) {
            @Expect(e.message.contains("does not support JOIN"), true)
        }
    }

    // 回归（I4）：deleteWhere 带 JOIN 必须拒绝，避免 dialect 渲染静默丢弃 JOIN 导致误删除
    @TestCase
    public func testDeleteWhereRejectsJoin(): Unit {
        let q = Query<Int64>()
        q.from("users")
        q.stmt.addClause(JoinClause("posts", "p", Expr.Binary(Expr.Column("user_id"), BinOp.Eq, Expr.Column("id"))))
        try {
            q.deleteWhere()
            @Fail("expected QueryException")
        } catch (e: QueryException) {
            @Expect(e.message.contains("does not support JOIN"), true)
        }
    }

    // 回归（I4）：无 JOIN 时 updateWhere 正常走通（rejectJoin 不得误伤合法查询）
    @TestCase
    public func testUpdateWhereWithoutJoinStillWorks(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 3
        let tx = Tx(conn, 0, MySQLDialect())
        tx.begin()
        let q = Query<Int64>()
        q.from("users")
        q.filter(Col<Int64>("age") > 18)
        q.using(tx)
        let count = q.updateWhere(["name"], ["bob"])
        @Expect(count, 3)
        @Expect(conn.stmt.capturedSql, "UPDATE `users` SET `name` = ? WHERE `age` > ?")
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(checkStr(conn.stmt.capturedSetValues[0], "bob"), true)
        @Expect(checkInt(conn.stmt.capturedSetValues[1], 18), true)
    }

    // 回归（I4）：无 JOIN 时 deleteWhere 正常走通（rejectJoin 不得误伤合法查询）
    @TestCase
    public func testDeleteWhereWithoutJoinStillWorks(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 2
        let tx = Tx(conn, 0, MySQLDialect())
        tx.begin()
        let q = Query<Int64>()
        q.from("users")
        q.filter(Col<Int64>("age") > 18)
        q.using(tx)
        let count = q.deleteWhere()
        @Expect(count, 2)
        @Expect(conn.stmt.capturedSql, "DELETE FROM `users` WHERE `age` > ?")
        @Expect(conn.stmt.capturedSetValues.size, 1)
        @Expect(checkInt(conn.stmt.capturedSetValues[0], 18), true)
    }

    @TestCase
    public func testForUpdateRendersMySQL(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        q.filter(Col<Int64>("age") > 18)
        q.forUpdate()
        let dialect = MySQLDialect()
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql, "SELECT `id` FROM `users` WHERE `age` > ? FOR UPDATE")
    }

    @TestCase
    public func testForUpdateIgnoredSQLite(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        q.forUpdate()
        let dialect = SQLiteDialect()
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql, "SELECT \"id\" FROM \"users\"")
    }

    @TestCase
    public func testAggregateRendersSQL(): Unit {
        let q = Query<Int64>()
        q.from("posts")
        q.filter(Col<Int64>("user_id") == 1)
        let stmt = Statement()
        stmt.addClause(SelectClause([Raw("SUM(id)")]))
        stmt.addClause(FromClause("posts"))
        stmt.addClause(WhereClause([Col<Int64>("user_id") == 1]))
        let dialect = MySQLDialect()
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT SUM(id) FROM `posts` WHERE `user_id` = ?")
    }
}

// ─── C4: page() 集合 include 批量协议（count + 主查询 + 批量 has_many 查询）──

@Test
public class C4PageCollectionTest {

    private func commentsRel(): IRelation {
        HasMany<UuidComment>("comments", "post_id",
            [Col<Any>("id"), Col<Any>("body")], "uuidComment",
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter, dummyTargetIdExtractor)
    }

    // Task 4 批量协议：page() = count + 主查询（LIMIT/OFFSET）+ 批量 has_many 查询三次。
    // 主查询无 JOIN（单页恰好 size 个主实体），comments 按 post_id 分组回填。
    @TestCase
    public func testPageWithHasManyIncludeBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(RowQueryResult(2))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let rows = [
            Array<Any>(2, {i => if (i == 0) { 5 } else { "post" }}),
            Array<Any>(2, {i => if (i == 0) { 6 } else { "other" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { "c1" } else if (i == 1) { "first" } else { 5 }}),
            Array<Any>(3, {i => if (i == 0) { "c2" } else if (i == 1) { "second" } else { 5 }}),
            Array<Any>(3, {i => if (i == 0) { "c3" } else if (i == 1) { "third" } else { 6 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = UuidPostWithRel.query().include(commentsRel(), [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let pg = q.page(1, 10)
        @Expect(pg.total, 2)
        @Expect(pg.items.size, 2)
        var byId = HashMap<Int64, UuidPostWithRel>()
        for (e in pg.items) { byId[e.id] = e }
        @Expect(byId.size, 2)
        @Expect(byId.get(5).getOrThrow().comments.size, 2)
        @Expect(byId.get(6).getOrThrow().comments.size, 1)
        // 三次查询：count + 主查询 + 批量查询；批量查询 IN 多值
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("LEFT JOIN"), false)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("IN (?, ?)"), true)
    }

    // Task 4：批量模式主查询无 JOIN，count 恒为 COUNT(*)，不再用 COUNT(DISTINCT id)。
    @TestCase
    public func testPageWithHasManyIncludeCountUsesStar(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(RowQueryResult(2))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let rows = [Array<Any>(2, {i => if (i == 0) { 5 } else { "post" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, []))
        let q = UuidPostWithRel.query().include(commentsRel(), [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let pg = q.page(1, 10)
        @Expect(pg.total, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("COUNT(*)"), true)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("COUNT(DISTINCT"), false)
    }

    @TestCase
    public func testPageWithoutCollectionStillWorks(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(RowQueryResult(3))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
        ]
        let rows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "a" }}),
            Array<Any>(2, {i => if (i == 0) { 2 } else { "b" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let pg = UuidRefComment.query().using(tx).page(1, 10)
        @Expect(pg.total, 3)
        @Expect(pg.items.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("COUNT(*)"), true)
    }

    @TestCase
    public func testPageNonCollectionRunsAfterFindHook(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.hook<UuidRefComment>("UuidRefComment", HookKind.AfterFind) { scope: Scope<UuidRefComment> =>
            scope.entity.body = "hooked"
        }
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
        ]
        let rows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "a" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let q = UuidRefComment.query().using(tx)
        q.ref = Some(rf)
        let pg = q.page(1, 10)
        @Expect(pg.items.size, 1)
        @Expect(pg.items[0].body, "hooked")
    }

    // batch include Task 3：page() 装配协议 = count 查询 + 主查询 + 批量 IN 查询三次。
    // 主查询无 LEFT JOIN，批量查询按 fk 回填目标。
    @TestCase
    public func testPageWithRefToIncludeBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "nice" } else { "p1" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let postCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("content", false),
        ]
        let postRow = Array<Any>(3, {i =>
            if (i == 0) { "p1" } else if (i == 1) { "First" } else { "Hello" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(postCols, [postRow]))
        let q = UuidRefComment.query().include(UuidRefCommentRel.post).using(tx)
        let pg = q.page(1, 10)
        @Expect(pg.total, 1)
        @Expect(pg.items.size, 1)
        @Expect(pg.items[0].post.isSome(), true)
        @Expect(pg.items[0].post.getOrThrow().id, "p1")
        @Expect(pg.items[0].post.getOrThrow().title, "First")
        // 三次查询：count + 主查询 + 批量查询；主查询无 JOIN，批量查询含 IN
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("LEFT JOIN"), false)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("IN (?)"), true)
    }

    // Task 3 批量协议：String-pk ref_to 的 fk（post_id）指向已删除目标，
    // 批量查询空结果 → 主实体保留、目标不挂载、不抛异常。
    @TestCase
    public func testRefToIncludeSkipsMissingTarget(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "orphan" } else { "nope" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let postCols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(postCols, []))
        let q = UuidRefComment.query().include(UuidRefCommentRel.post).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].post.isNone(), true)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }

    // Task 4 批量协议：批量查询命中 0 行（主实体无任何评论）→ comments 保持空列表、
    // 不挂载任何子对象、不抛异常（旧 JOIN 方案的 NULL 子行判空已被 IN 查询天然排除）。
    @TestCase
    public func testHasManyIncludeNoMatchingChildren(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let rows = [
            Array<Any>(2, {i => if (i == 0) { 5 } else { "post" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, []))
        let q = UuidPostWithRel.query().include(commentsRel(), [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].comments.size, 0)
        // 批量查询仍发出（主实体 id 非空），只是无命中行
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }

    // Task 3 批量协议：Int64 fk（user_id=99）指向不存在用户，默认 RowMapper 路径
    // （PostWithRel.query() + all()）下批量查询空结果 → 不崩溃、author 保持 None。
    @TestCase
    public func testRefToIncludeMissingTargetDefaultMapperNoCrash(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(4, {i =>
            if (i == 0) { 5 } else if (i == 1) { "orphan" } else if (i == 2) { 99 } else { 0 }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, []))
        let q = PostWithRel.query().include(PostWithRelRel.author).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].author.isNone(), true)
    }

    // Task 3 批量协议：多主实体引用多个目标 → 单个批量查询（IN 多值），逐个回填。
    @TestCase
    public func testRefToIncludeMultipleEntitiesBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [
            Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else if (i == 2) { 10 } else { 0 }}),
            Array<Any>(4, {i => if (i == 0) { 2 } else if (i == 1) { "p2" } else if (i == 2) { 20 } else { 0 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("email", false),
        ]
        let userRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "Alice" } else { "a@x.com" }}),
            Array<Any>(3, {i => if (i == 0) { 20 } else if (i == 1) { "Bob" } else { "b@x.com" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, userRows))
        let q = PostWithRel.query().include(PostWithRelRel.author).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?, ?)"), true)
        @Expect(entities.size, 2)
        @Expect(entities[0].author.getOrThrow().name, "Alice")
        @Expect(entities[1].author.getOrThrow().name, "Bob")
    }

    // Task 3 批量协议：所有 fk 均为 0（未设置）→ 批量查询整体跳过，只发主查询。
    @TestCase
    public func testRefToIncludeEmptyFkSetSkipsBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [
            Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else if (i == 2) { 0 } else { 0 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let q = PostWithRel.query().include(PostWithRelRel.author).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].author.isNone(), true)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
    }

    // R-I2 回归：主查询 SELECT 省略 ref_to 的 fk 列（如 select([id, title]) 不含 user_id）时，
    // 宏层 mapper 对缺失列宽容（列缺失字段留默认值 0/""），isEmptyFk 会把整批 fk 误判为空
    // 而静默跳过批量查询，author 恒为 None 且无任何错误。必须在装配入口抛带 fk 列名的
    // QueryException（fail-fast，风格同 has_many 的 rawIdExtractor 主键守卫）。
    @TestCase
    public func testRefToIncludeMissingFkColumnThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let rows = [Array<Any>(2, {i => if (i == 0) { 5 } else { "p1" }})]
        conn.stmt.queryResult = MapperMockQueryResult(cols, rows)
        let q = PostWithRel.query().select([Expr.Column("id"), Expr.Column("title")])
            .include(PostWithRelRel.author).using(tx)
        try {
            let _ = q.all()
            @Fail("expected QueryException for missing fk column in select")
        } catch (e: QueryException) {
            @Expect(e.message.contains("user_id"), true)
            @Expect(e.message.contains("author"), true)
        }
        // 守卫发生在主查询之后、批量查询之前：主查询已发、批量查询不发
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
    }

    // R-I2 回归：fk 列缺失时即使主查询返回空行集也必须抛错（配置错误 fail-fast，
    // 与数据无关；has_many 主键守卫同样与行数无关）。
    @TestCase
    public func testRefToIncludeMissingFkColumnEmptyRowsStillThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [])
        let q = PostWithRel.query().select([Expr.Column("id"), Expr.Column("title")])
            .include(PostWithRelRel.author).using(tx)
        try {
            let _ = q.all()
            @Fail("expected QueryException for missing fk column even with empty rows")
        } catch (e: QueryException) {
            @Expect(e.message.contains("user_id"), true)
        }
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
    }

    // R-I2 正向路径：SELECT 显式包含 fk 列（user_id）时 ref_to include 正常批量装配。
    @TestCase
    public func testRefToIncludeFkSelectedStillWorks(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "p1" } else { 10 }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("email", false),
        ]
        let userRow = Array<Any>(3, {i =>
            if (i == 0) { 10 } else if (i == 1) { "Alice" } else { "a@x.com" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let q = PostWithRel.query().select([Expr.Column("id"), Expr.Column("title"), Expr.Column("user_id")])
            .include(PostWithRelRel.author).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].author.isSome(), true)
        @Expect(entities[0].author.getOrThrow().name, "Alice")
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }

    // R-I2 回归：嵌套层 ref_to 的 fk 列不在上层批量查询结果中（上层关系字段子集不含
    // 该 fk）→ 递归装配同样抛带列名的 QueryException，而非静默丢关联。
    @TestCase
    public func testNestedRefToIncludeMissingFkColumnThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("author_id", false),
        ]
        let mainRow = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "c1" } else { 10 }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        // 上层 author 批量查询字段子集只有 id（FieldOverrideRelation），不含 team_id fk
        let authorCols: Array<SqlColumnInfo> = [MapperMockColumnInfo("id", false)]
        let authorRow = Array<Any>(1, {i => 10})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(authorCols, [authorRow]))
        let q = NestedCommentPost.query()
            .include(NestedCommentPostRel.author.withInclude(NestedUserRefRel.team), [Col<Any>("id")])
            .using(tx)
        try {
            let _ = q.all()
            @Fail("expected QueryException for missing nested fk column")
        } catch (e: QueryException) {
            @Expect(e.message.contains("team_id"), true)
        }
        // 主查询 + 上层 author 批量查询已发；嵌套 team 批量查询在守卫处被拦下
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }

    // Task 3 批量协议：主查询返回空（无实体）→ assembleRefTo 的 entities.size==0
    // 早退分支生效，不触发批量查询，只发主查询。
    @TestCase
    public func testRefToIncludeEmptyEntitiesSkipsBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, []))
        let q = PostWithRel.query().include(PostWithRelRel.author).using(tx)
        let entities = q.all()
        @Expect(entities.size, 0)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
    }

    // Task 3 批量协议：两个 ref_to 指向同一目标表 "user"（author 用 user_id、editor 用 post_id）
    // → 合并为单条批量查询 `WHERE "id" IN (?, ?)`，两关系共享同一 id→实体 映射分别回填。
    @TestCase
    public func testRefToIncludeMergesSameTargetTable(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [
            Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else if (i == 2) { 10 } else { 20 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("email", false),
        ]
        let userRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "Alice" } else { "a@x.com" }}),
            Array<Any>(3, {i => if (i == 0) { 20 } else if (i == 1) { "Eve" } else { "e@x.com" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, userRows))
        // editor 是手工构造的第二个指向 "user" 表的 ref_to，fk 读 post_id
        let captured = ArrayList<String>()
        let editorSetter: (Any, Any) -> Unit = { e: Any, t: Any =>
            let u = (t as User).getOrThrow()
            captured.add(u.id.toString())
        }
        let editor = RefTo<User>("editor", Col<Any>("post_id"),
            [Col<Any>("id"), Col<Any>("name")], "user",
            dummyMapper, editorSetter, { e: Any => (e as PostWithRel).getOrThrow().post_id }, dummyTargetIdExtractor)
        let q = PostWithRel.query()
            .include(PostWithRelRel.author)
            .include(editor)
            .using(tx)
        let entities = q.all()
        // 主查询 + 1 条合并批量查询（未合并会有 2 条批量查询）
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?, ?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.getOrThrow().id, 10)
        @Expect(captured.size, 1)
        @Expect(captured[0], "20")
    }

    // Task 3 批量协议：同表两个 ref_to 字段子集不同 → 合并查询按「并集」SELECT，
    // 共享 identity-map 实体携带并集列值（editor 只声明 id/email，其目标仍带 name）。
    @TestCase
    public func testRefToIncludeMergedFieldUnion(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [
            Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else if (i == 2) { 10 } else { 20 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("email", false),
        ]
        let userRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "Alice" } else { "a@x.com" }}),
            Array<Any>(3, {i => if (i == 0) { 20 } else if (i == 1) { "Eve" } else { "e@x.com" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, userRows))
        let captured = ArrayList<String>()
        // author 子集 [id, name]，editor 子集 [id, email]
        let authorSetter: (Any, Any) -> Unit = { e: Any, t: Any =>
            let u = (t as User).getOrThrow()
            captured.add("author:" + u.name)
        }
        let editorSetter: (Any, Any) -> Unit = { e: Any, t: Any =>
            let u = (t as User).getOrThrow()
            captured.add("editor:" + u.email)
        }
        let author = RefTo<User>("author", Col<Any>("user_id"),
            [Col<Any>("id"), Col<Any>("name")], "user",
            UserRowMapper, authorSetter, { e: Any => (e as PostWithRel).getOrThrow().user_id }, dummyTargetIdExtractor)
        let editor = RefTo<User>("editor", Col<Any>("post_id"),
            [Col<Any>("id"), Col<Any>("email")], "user",
            UserRowMapper, editorSetter, { e: Any => (e as PostWithRel).getOrThrow().post_id }, dummyTargetIdExtractor)
        let q = PostWithRel.query().include(author).include(editor).using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        // 合并查询 SELECT 字段并集：强制 id + author 的 name + editor 的 email
        @Expect(conn.stmt.capturedSqlHistory[1].contains("SELECT \"id\", \"name\", \"email\" FROM \"user\""), true)
        @Expect(entities.size, 1)
        // 回填顺序 = included 顺序：author 先、editor 后
        @Expect(captured.size, 2)
        @Expect(captured[0], "author:Alice")
        @Expect(captured[1], "editor:e@x.com")
    }

    // Task 4 批量协议：has_one 目标侧 fk 批量装配。主查询无 profile.* JOIN 列，
    // profile 由批量查询 `WHERE "user_id" IN (主实体 id)` 挂载。
    @TestCase
    public func testHasOneIncludeAssembled(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let row = Array<Any>(2, {i => if (i == 0) { 7 } else { "nobody" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [row]))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("bio", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let batchRow = Array<Any>(3, {i => if (i == 0) { 3 } else if (i == 1) { "engineer" } else { 7 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, [batchRow]))
        let q = UserWithRel.query().include(UserWithRelRel.profile).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 7)
        @Expect(entities[0].profile.isSome(), true)
        @Expect(entities[0].profile.getOrThrow().id, 3)
        @Expect(entities[0].profile.getOrThrow().bio, "engineer")
        // has_one 触发主查询 + 批量查询两次
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }
}

// ─── I12: all() 返回顺序必须保持主查询行序（SQL 行序反映 ORDER BY） ──

@Test
public class C4CollectionIncludeOrderTest {

    private func commentsRel(): IRelation {
        HasMany<UuidComment>("comments", "post_id",
            [Col<Any>("id"), Col<Any>("body")], "uuidComment",
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter, dummyTargetIdExtractor)
    }

    @TestCase
    public func testAllWithCollectionIncludePreservesRowOrder(): Unit {
        // 批量协议：主查询行序即返回顺序（每行一个主实体，无 JOIN 展开/去重），
        // comments 按 fk 分组回填后仍保持该顺序。
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        // 主查询行序刻意打乱 id 数值序：返回顺序必须与行序一致（9, 3, 7, 11, 5），
        // 即 SQL 行序（反映 ORDER BY），批量装配不得重排实体列表。
        let rows = [
            Array<Any>(2, {i => if (i == 0) { 9 } else { "post9" }}),
            Array<Any>(2, {i => if (i == 0) { 3 } else { "post3" }}),
            Array<Any>(2, {i => if (i == 0) { 7 } else { "post7" }}),
            Array<Any>(2, {i => if (i == 0) { 11 } else { "post11" }}),
            Array<Any>(2, {i => if (i == 0) { 5 } else { "post5" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { "c1" } else if (i == 1) { "first" } else { 9 }}),
            Array<Any>(3, {i => if (i == 0) { "c2" } else if (i == 1) { "second" } else { 9 }}),
            Array<Any>(3, {i => if (i == 0) { "c3" } else if (i == 1) { "third" } else { 3 }}),
            Array<Any>(3, {i => if (i == 0) { "c4" } else if (i == 1) { "fourth" } else { 7 }}),
            Array<Any>(3, {i => if (i == 0) { "c5" } else if (i == 1) { "fifth" } else { 11 }}),
            Array<Any>(3, {i => if (i == 0) { "c6" } else if (i == 1) { "sixth" } else { 5 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = UuidPostWithRel.query().include(commentsRel(), [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 5)
        @Expect(entities[0].id, 9)
        @Expect(entities[1].id, 3)
        @Expect(entities[2].id, 7)
        @Expect(entities[3].id, 11)
        @Expect(entities[4].id, 5)
        @Expect(entities[0].comments.size, 2)
        @Expect(entities[1].comments.size, 1)
        @Expect(entities[1].comments[0].id, "c3")
    }
}

// ─── Task 4：has_many / has_one 批量装配边界用例 ──

@Test
public class C4CollectionBatchTest {

    // 批量结果中出现 fk 不匹配任何主实体 id 的行（脏数据/查询边界）→ 该行只进独立分组，
    // 不装配到任何主实体，主实体列表不受影响。
    @TestCase
    public func testHasManyIncludeIgnoresForeignFkRows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 0 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let batchRows = [
            Array<Any>(2, {i => if (i == 0) { 10 } else { 1 }}),
            Array<Any>(2, {i => if (i == 0) { 99 } else { 999 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = PostWithRel.query().include(PostWithRelRel.comments).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 1)
        @Expect(entities[0].comments.size, 1)
        @Expect(entities[0].comments[0].id, 10)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }

    // 批量查询命中 0 行（主实体无任何评论）→ comments 保持空列表，不抛异常。
    @TestCase
    public func testHasManyIncludeEmptyChildrenStaysEmpty(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 0 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, []))
        let q = PostWithRel.query().include(PostWithRelRel.comments).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].comments.size, 0)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }

    // 两个 has_many 指向同一目标表 + 同一 fk → 合并为一条批量查询（字段并集，共回填两组）。
    @TestCase
    public func testHasManyIncludeMergesSameTargetTable(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 0 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "first" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { "second" } else { 1 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let captured = ArrayList<Int64>()
        let secondSetter: (Any, Any) -> Unit = { e: Any, t: Any =>
            let c = (t as Comment).getOrThrow()
            captured.add(c.id)
        }
        let moderated = HasMany<Comment>("moderated", "post_id",
            [Col<Any>("id"), Col<Any>("body")], "comment",
            CommentRowMapper, secondSetter, dummyTargetIdExtractor)
        let q = PostWithRel.query()
            .include(PostWithRelRel.comments)
            .include(moderated)
            .using(tx)
        let entities = q.all()
        // 主查询 + 1 条合并批量查询（未合并会有 2 条批量查询）
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].comments.size, 2)
        // moderated 关系与 comments 共享同一分组，回填同一批评论
        @Expect(captured.size, 2)
        @Expect(captured[0], 10)
        @Expect(captured[1], 11)
    }

    // one() 批量协议：主查询 LIMIT 1，批量查询按 fk IN 回填该单实体。
    @TestCase
    public func testHasManyIncludeOne(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 0 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let batchRows = [Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "first" } else { 1 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = PostWithRel.query().include(PostWithRelRel.comments).using(tx)
        let res = q.one()
        @Expect(res.isSome(), true)
        @Expect(res.getOrThrow().id, 1)
        @Expect(res.getOrThrow().comments.size, 1)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("LIMIT 1"), true)
    }

    // has_one 批量查询命中 0 行 → profile 保持 None，不抛异常。
    @TestCase
    public func testHasOneIncludeEmptyStaysNone(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 7 } else { "nobody" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, []))
        let q = UserWithRel.query().include(UserWithRelRel.profile).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].profile.isNone(), true)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
    }

    // has_one 目标侧 fk 重复（唯一约束被破坏）→ 取分组第一条，不抛错。
    @TestCase
    public func testHasOneIncludeMultipleTargetsTakesFirst(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRows = [Array<Any>(2, {i => if (i == 0) { 7 } else { "nobody" }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("bio", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "first" } else { 7 }}),
            Array<Any>(3, {i => if (i == 0) { 2 } else if (i == 1) { "second" } else { 7 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = UserWithRel.query().include(UserWithRelRel.profile).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].profile.isSome(), true)
        @Expect(entities[0].profile.getOrThrow().id, 1)
        @Expect(entities[0].profile.getOrThrow().bio, "first")
    }

    // 主实体缺单列主键提取器（手动构造 Query 未 setRawIdExtractor；宏层对复合主键
    // 也不生成 rawIdExtractor，见计划 D6）→ 集合 include 装配入口抛带说明的 QueryException。
    @TestCase
    public func testCollectionIncludeWithoutRawIdExtractorThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let rel: IRelation = HasMany<Int64>("posts", "user_id",
            [Col<Any>("id")], "posts", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        q.include(rel)
        q.using(tx)
        try {
            let _ = q.all()
            @Fail("expected QueryException for missing raw id extractor")
        } catch (e: QueryException) {
            @Expect(e.message.contains("single-column primary key"), true)
        }
        // 守卫在查询执行前抛错，主查询不发
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    // String-pk 主实体 + has_many：批量查询 fk 按 String 读取分组（isStringPk 分支）。
    // 用手工构造 Query 挂 String rawIdExtractor 覆盖该分支（宏层 has_many 级联代码生成
    // 目前假设主实体有 id 字段，String-pk has_many 主实体无法经 @Rel 声明编译）。
    @TestCase
    public func testHasManyIncludeStringPkMainEntity(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [MapperMockColumnInfo("key", false)]
        let mainRows = [Array<Any>(1, {i => "p-a"})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_key", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { "c1" } else if (i == 1) { "hello" } else { "p-a" }}),
            Array<Any>(3, {i => if (i == 0) { "c2" } else if (i == 1) { "world" } else { "p-a" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let captured = ArrayList<UuidKeyComment>()
        let setter: (Any, Any) -> Unit = { e: Any, t: Any =>
            captured.add((t as UuidKeyComment).getOrThrow())
        }
        let rel = HasMany<UuidKeyComment>("comments", "post_key",
            [Col<Any>("id"), Col<Any>("body")], "uuidKeyComment",
            UuidKeyCommentRowMapper, setter, dummyTargetIdExtractor)
        let q = Query<Int64>()
        q.select([Expr.Column("key")])
        q.from("uuidKeyPost")
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        q.setRawIdExtractor({ r: QueryResult, cm: HashMap<String, Int64> => "p-a" })
        q.include(rel)
        q.using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("WHERE \"post_key\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(captured.size, 2)
        @Expect(captured[0].id, "c1")
        @Expect(captured[0].body, "hello")
        @Expect(captured[0].post_key, "p-a")
        @Expect(captured[1].id, "c2")
        @Expect(captured[1].body, "world")
        @Expect(captured[1].post_key, "p-a")
    }

    // 主查询 SELECT 省略主键列（如 select([title])）→ 集合 include 批量装配无法读主键，
    // 必须抛带说明的 QueryException（而不是 Option.getOrThrow 的裸错误）。
    @TestCase
    public func testCollectionIncludeMissingPkColumnThrows(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let cols: Array<SqlColumnInfo> = [MapperMockColumnInfo("title", false)]
        let rows = [Array<Any>(1, {i => "p1"})]
        conn.stmt.queryResult = MapperMockQueryResult(cols, rows)
        let q = PostWithRel.query().select([Expr.Column("title")]).include(PostWithRelRel.comments).using(tx)
        try {
            let _ = q.all()
            @Fail("expected QueryException for missing pk column in select")
        } catch (e: QueryException) {
            @Expect(e.message.contains("必须包含主键列"), true)
        }
    }

    // 批量结果中目标 fk 为 NULL 的脏行（可空 fk）→ 分组时跳过，不抛异常、不装配。
    @TestCase
    public func testHasManyIncludeSkipsNullFkRow(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRows = [Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 0 }})]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let batchCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        // 第二行 post_id 用非 Int64 值模拟驱动 NULL（MapperMockQueryResult.getOrNull 类型不匹配 → None）
        let batchRows = [
            Array<Any>(2, {i => if (i == 0) { 10 } else { 1 }}),
            Array<Any>(2, {i => if (i == 0) { 99 } else { "orphan" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let q = PostWithRel.query().include(PostWithRelRel.comments).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].comments.size, 1)
        @Expect(entities[0].comments[0].id, 10)
    }
}

// ─── Task 6: 嵌套 include 递归装配（withInclude 链 + 深度守卫） ─────────────────

// 深度守卫测试用自定义 IRelation：getNested() 返回自身形成 include 环。没有深度守卫时
// 递归装配将无限循环（每层发一条批量查询）；MaxNestedDepth 超限后抛 QueryException。
// 公开 withInclude 链（clone-on-write + 去重）无法构造环，只能经自定义 IRelation 触发。
class CyclicNestedRelation <: IRelation {
    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (RelationKind.HasManyRel, "cycle", "cycleTable", "parent_id", None, [])
    }
    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any { dummyMapper }
    public func getFieldSetter(): (Any, Any) -> Unit { dummySetter }
    public func getForeignKeyExtractor(): (Any) -> Any { dummyFkExtractor }
    public func getTargetIdExtractor(): (Any) -> Any { { t: Any => 1 } }
    public func getJunctionTargetCol(): String { "" }
    public func withInclude(rel: IRelation): IRelation { this }
    public func getNested(): Array<IRelation> { [this] }
    public func isBatchSupported(): Bool { true }
}

@Test
public class NestedIncludeTest {

    // 宏层生成的目标 id 提取器：从 Any 目标实体读主键（嵌套层主实体是上一级装配结果）。
    // 提取器按关系目标类型强转：NestedPostRel.author 的目标是 NestedUser，故传 NestedUser。
    @TestCase
    public func testGeneratedTargetIdExtractorReadsEntityId(): Unit {
        let u = NestedUser()
        u.id = 77
        match (NestedPostRel.author.getTargetIdExtractor()(u)) {
            case v: Int64 => @Expect(v, 77)
            case _ => @Fail("expected Int64 id")
        }
    }

    // 两层 ref_to → has_one：Post.author（ref_to User）装配后，对装配出的 User 目标
    // 递归装配其嵌套 profile（has_one）→ 主查询 + author 批量 + profile 批量三次查询。
    @TestCase
    public func testNestedRefToThenHasOne(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let profileCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("bio", false),
        ]
        let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 99 } else { "engineer" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        let q = NestedPost.query()
            .include(NestedPostRel.author.withInclude(NestedUserRel.profile))
            .using(tx)
        let entities = q.all()
        // 主查询 + author 批量 + profile 批量 = 三次查询
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("LEFT JOIN"), false)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"nestedUser\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?)"), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedProfile\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("WHERE \"user_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.isSome(), true)
        @Expect(entities[0].author.getOrThrow().id, 99)
        @Expect(entities[0].author.getOrThrow().name, "Alice")
        @Expect(entities[0].author.getOrThrow().profile.isSome(), true)
        @Expect(entities[0].author.getOrThrow().profile.getOrThrow().id, 5)
        @Expect(entities[0].author.getOrThrow().profile.getOrThrow().bio, "engineer")
    }

    // 两层 ref_to → has_many：Post.author 装配后递归装配 author 的 comments（has_many），
    // 嵌套层 mainIds 来自 author 目标实体的 getTargetIdExtractor。
    @TestCase
    public func testNestedRefToThenHasMany(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let commentCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("body", false),
        ]
        let commentRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { 99 } else { "c1" }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { 99 } else { "c2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(commentCols, commentRows))
        let q = NestedPost.query()
            .include(NestedPostRel.author.withInclude(NestedUserRel.comments))
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedComment\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("WHERE \"user_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.getOrThrow().id, 99)
        @Expect(entities[0].author.getOrThrow().comments.size, 2)
        @Expect(entities[0].author.getOrThrow().comments[0].id, 10)
        @Expect(entities[0].author.getOrThrow().comments[0].body, "c1")
        @Expect(entities[0].author.getOrThrow().comments[1].id, 11)
    }

    // 三层：Post.author → User.profile → Profile.skills。每层一条批量查询，共 4 次。
    @TestCase
    public func testNestedThreeLevels(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let profileCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("bio", false),
        ]
        let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 99 } else { "engineer" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        let skillCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("profile_id", false),
            MapperMockColumnInfo("name", false),
        ]
        let skillRow = Array<Any>(3, {i => if (i == 0) { 100 } else if (i == 1) { 5 } else { "cangjie" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(skillCols, [skillRow]))
        let q = NestedPost.query()
            .include(NestedPostRel.author
                .withInclude(NestedUserRel.profile.withInclude(NestedProfileRel.skills)))
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 4)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedProfile\""), true)
        @Expect(conn.stmt.capturedSqlHistory[3].contains("FROM \"nestedSkill\""), true)
        @Expect(conn.stmt.capturedSqlHistory[3].contains("WHERE \"profile_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        let profile = entities[0].author.getOrThrow().profile.getOrThrow()
        @Expect(profile.id, 5)
        @Expect(profile.skills.size, 1)
        @Expect(profile.skills[0].id, 100)
        @Expect(profile.skills[0].name, "cangjie")
    }

    // 多个主实体引用同一目标（两篇 Post 同一 author）：ref_to 装配的目标按关系去重，
    // 递归层只对唯一目标发一次批量查询（3 次而非 4 次），且共享的 author 实例同时可见 profile。
    @TestCase
    public func testNestedSharedTargetDedup(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRows = [
            Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }}),
            Array<Any>(3, {i => if (i == 0) { 2 } else if (i == 1) { "p2" } else { 99 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let profileCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("bio", false),
        ]
        let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 99 } else { "engineer" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        let q = NestedPost.query()
            .include(NestedPostRel.author.withInclude(NestedUserRel.profile))
            .using(tx)
        let entities = q.all()
        // 主查询 + author 批量 + profile 批量（去重后 author 目标仅一个）→ 仍 3 次
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(entities.size, 2)
        @Expect(entities[0].author.getOrThrow().profile.getOrThrow().bio, "engineer")
        @Expect(entities[1].author.getOrThrow().profile.getOrThrow().bio, "engineer")
    }

    // 顶层 has_many 的嵌套：Category.children.withInclude(Category.children)，
    // 第二层 mainIds 来自第一层子分类实体（getTargetIdExtractor）。
    @TestCase
    public func testNestedHasManyTopLevel(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("parent_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "root" } else { 0 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let childCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("parent_id", false),
            MapperMockColumnInfo("name", false),
        ]
        let childRow = Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { 1 } else { "child" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(childCols, [childRow]))
        let grandRow = Array<Any>(3, {i => if (i == 0) { 20 } else if (i == 1) { 10 } else { "grandchild" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(childCols, [grandRow]))
        let q = CategoryWithRel.query()
            .include(CategoryWithRelRel.children.withInclude(CategoryWithRelRel.children))
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"categoryWithRel\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("WHERE \"parent_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].children.size, 1)
        @Expect(entities[0].children[0].id, 10)
        @Expect(entities[0].children[0].children.size, 1)
        @Expect(entities[0].children[0].children[0].id, 20)
        @Expect(entities[0].children[0].children[0].name, "grandchild")
    }

    // 嵌套层的字段子集：withInclude(FieldOverrideRelation(profile, [id, bio]))，
    // 批量查询按子集 SELECT（强制 id + user_id 分组键 + 子集 bio）。
    @TestCase
    public func testNestedFieldSubset(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let profileCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("bio", false),
        ]
        let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 99 } else { "engineer" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        let q = NestedPost.query()
            .include(NestedPostRel.author
                .withInclude(FieldOverrideRelation(NestedUserRel.profile, [Col<Any>("id"), Col<Any>("bio")])))
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("SELECT \"id\", \"user_id\", \"bio\" FROM \"nestedProfile\""), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.getOrThrow().profile.getOrThrow().bio, "engineer")
    }

    // 两层 ref_to → ref_to：NestedCommentPost.author（ref_to NestedUserRef）装配后递归
    // 装配 author 的 team（ref_to NestedTeamRef）——嵌套层 assembleRefTo 在 Array<Any>
    // 目标实体上读 fk（getForeignKeyExtractor）批量装配。
    @TestCase
    public func testNestedRefToThenRefTo(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("author_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "c1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("team_id", false),
        ]
        let userRow = Array<Any>(3, {i => if (i == 0) { 99 } else if (i == 1) { "Alice" } else { 7 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let teamCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let teamRow = Array<Any>(2, {i => if (i == 0) { 7 } else { "eng" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(teamCols, [teamRow]))
        let q = NestedCommentPost.query()
            .include(NestedCommentPostRel.author.withInclude(NestedUserRefRel.team))
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"nestedUserRef\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedTeamRef\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("WHERE \"id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.isSome(), true)
        @Expect(entities[0].author.getOrThrow().name, "Alice")
        @Expect(entities[0].author.getOrThrow().team.isSome(), true)
        @Expect(entities[0].author.getOrThrow().team.getOrThrow().id, 7)
        @Expect(entities[0].author.getOrThrow().team.getOrThrow().name, "eng")
    }

    // 嵌套 ref_many：Post.author 装配后递归装配 author 的 tags（ref_many）。junction 源列
    // 必须是「当前层级」表（author 实体的表 nestedUser_id），而不是顶层主查询表（nestedPost_id）。
    // 回归：assembleRefMany 曾用 getSourceTable()（恒为顶层 FROM）推导源列，嵌套层会生成
    // "nestedUser_tags"."nestedPost_id"（PG 上 column does not exist）。
    // mock 同时提供 nestedUser_id 与 nestedPost_id 两列：修复前装配走错误源列也能返回行，
    // 由 SQL 断言精确暴露源列错误（避免直接抛错掩盖问题）。
    @TestCase
    public func testNestedRefToThenRefMany(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let tagCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("nestedUser_id", false),
            MapperMockColumnInfo("nestedPost_id", false),
        ]
        let tagRow = Array<Any>(4, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(tagCols, [tagRow]))
        let q = NestedPost.query()
            .include(NestedPostRel.author.withInclude(NestedUserRel.tags))
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedUser_tags\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("\"nestedUser_tags\".\"nestedUser_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.getOrThrow().tags.size, 1)
        @Expect(entities[0].author.getOrThrow().tags[0].id, 10)
    }

    // Task 6 batch-include 回归：顶层 ref_many → 嵌套 has_many，两个主实体共享同一目标。
    // NestedUser.tags（ref_many NestedTag）装配出的 tag 目标上递归装配 notes（has_many）。
    // 两个 NestedUser 都关联 tag t1（junction 两行）→ assembleRefMany 收集的目标列表
    // 含同一 tag id（10）的两个副本实例。修复前不按 target id 去重，嵌套层对两个副本
    // 各自跑一次 notes 装配；嵌套层 assembleCollections 再把共享的 note 实例重复收集进
    // targets，往下一层（NestedTagNote.items）时 setter .add() 对同一 note 追加两次。
    @TestCase
    public func testNestedRefManySharedTargetDedup(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "u1" }}),
            Array<Any>(2, {i => if (i == 0) { 2 } else { "u2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let tagCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("nestedUser_id", false),
        ]
        let tagRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 2 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(tagCols, tagRows))
        let noteCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("tag_id", false),
            MapperMockColumnInfo("body", false),
        ]
        let noteRows = [
            Array<Any>(3, {i => if (i == 0) { 100 } else if (i == 1) { 10 } else { "n1" }}),
            Array<Any>(3, {i => if (i == 0) { 101 } else if (i == 1) { 10 } else { "n2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(noteCols, noteRows))
        let q = NestedUser.query()
            .include(NestedUserRel.tags.withInclude(NestedTagRel.notes))
            .using(tx)
        let entities = q.all()
        // 主查询 + junction 批量 + notes 批量 = 三次查询；notes 装配每 tag id 只跑一次
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"nestedUser_tags\" JOIN \"nestedTag\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedTagNote\""), true)
        @Expect(entities.size, 2)
        @Expect(entities[0].tags.size, 1)
        @Expect(entities[0].tags[0].id, 10)
        @Expect(entities[0].tags[0].notes.size, 2)
        @Expect(entities[0].tags[0].notes[0].body, "n1")
        @Expect(entities[0].tags[0].notes[1].body, "n2")
        @Expect(entities[1].tags.size, 1)
        @Expect(entities[1].tags[0].id, 10)
        @Expect(entities[1].tags[0].notes.size, 2)
    }

    // R-M9: 组内按目标 id 去重——同一 (源 id, 目标 id) 的重复 junction 行（DB 数据损坏或
    // 手工 INSERT 触发；正常 save 的 append 每次只写一行）会把同一目标实例 add 进组两次，
    // 单层 setter 对同一父实体 .add() 两次、tags 出现同实例两份。mock 返回两条完全相同
    // （source=1, target=10）的 junction 行：修复前 u1.tags.size == 2，修复后只保留一份。
    @TestCase
    public func testRefManyDuplicateJunctionRowDedup(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "u1" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let tagCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("nestedUser_id", false),
        ]
        let dupRow = Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 1 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(tagCols, [dupRow, dupRow]))
        let q = NestedUser.query()
            .include(NestedUserRel.tags)
            .using(tx)
        let entities = q.all()
        // 主查询 + junction 批量 = 两次查询；组内按目标 id 去重后目标只装配一次
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(entities.size, 1)
        @Expect(entities[0].tags.size, 1)
        @Expect(entities[0].tags[0].id, 10)
    }

    // 共享目标再往下一层（ref_many → has_many → has_many）：修复前嵌套层 assembleCollections
    // 把共享的 note 实例（同一 tag 的两个副本各命中同一分组）重复收集进 targets，items 递归
    // 对同一 note 跑两次 → note.items 被 .add() 追加成 [i1, i1]。修复后每 target id 只装配一次。
    @TestCase
    public func testNestedRefManySharedTargetNoDeepDuplicate(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "u1" }}),
            Array<Any>(2, {i => if (i == 0) { 2 } else { "u2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, mainRows))
        let tagCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("nestedUser_id", false),
        ]
        let tagRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 1 }}),
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 2 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(tagCols, tagRows))
        let noteCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("tag_id", false),
            MapperMockColumnInfo("body", false),
        ]
        let noteRows = [
            Array<Any>(3, {i => if (i == 0) { 100 } else if (i == 1) { 10 } else { "n1" }}),
            Array<Any>(3, {i => if (i == 0) { 101 } else if (i == 1) { 10 } else { "n2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(noteCols, noteRows))
        let itemCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("note_id", false),
            MapperMockColumnInfo("name", false),
        ]
        let itemRows = [
            Array<Any>(3, {i => if (i == 0) { 1000 } else if (i == 1) { 100 } else { "i1" }}),
            Array<Any>(3, {i => if (i == 0) { 1001 } else if (i == 1) { 101 } else { "i2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(itemCols, itemRows))
        let q = NestedUser.query()
            .include(NestedUserRel.tags
                .withInclude(NestedTagRel.notes.withInclude(NestedTagNoteRel.items)))
            .using(tx)
        let entities = q.all()
        // 主查询 + junction + notes + items = 四次查询
        @Expect(conn.stmt.capturedSqlHistory.size, 4)
        @Expect(entities.size, 2)
        @Expect(entities[0].tags.size, 1)
        @Expect(entities[0].tags[0].notes.size, 2)
        @Expect(entities[0].tags[0].notes[0].items.size, 1)
        @Expect(entities[0].tags[0].notes[0].items[0].id, 1000)
        @Expect(entities[0].tags[0].notes[0].items[0].name, "i1")
        @Expect(entities[0].tags[0].notes[1].items.size, 1)
        @Expect(entities[0].tags[0].notes[1].items[0].id, 1001)
        @Expect(entities[0].tags[0].notes[1].items[0].name, "i2")
    }

    // R-M10: diamond include —— 同一层两条 ref_to（DiamondPost.author/editor）指向同一
    // 目标表且带相同嵌套 has_many include，author 与 editor 指向同一个用户（ref_to
    // identity-map 共享同一实例）。修复前递归层对每对 pair 各跑一次嵌套装配，共享目标
    // 实例的 skills 被 setter .add() 追加成两份（查询次数也翻倍）。修复后按目标表合并
    // 递归：skills 每目标只装配一次，author/editor 因是同一实例都可见完整 skills。
    @TestCase
    public func testDiamondIncludeSharedTargetHasManyNoDuplicate(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("author_id", false),
            MapperMockColumnInfo("editor_id", false),
        ]
        let mainRow = Array<Any>(4, {i =>
            if (i == 0) { 1 } else if (i == 1) { "p1" } else if (i == 2) { 99 } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let skillCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("name", false),
        ]
        let skillRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { 99 } else { "s1" }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { 99 } else { "s2" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(skillCols, skillRows))
        let q = DiamondPost.query()
            .include(DiamondPostRel.author.withInclude(DiamondUserRel.skills))
            .include(DiamondPostRel.editor.withInclude(DiamondUserRel.skills))
            .using(tx)
        let entities = q.all()
        // 主查询 + author/editor 合并批量（同一目标表）+ skills 一次 = 三次查询
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"diamondUser\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"diamondSkill\""), true)
        @Expect(entities.size, 1)
        let author = entities[0].author.getOrThrow()
        let editor = entities[0].editor.getOrThrow()
        @Expect(author.id, 99)
        @Expect(author.skills.size, 2)
        @Expect(author.skills[0].id, 10)
        @Expect(author.skills[0].name, "s1")
        @Expect(author.skills[1].id, 11)
        @Expect(author.skills[1].name, "s2")
        // ref_to identity-map：author 与 editor 是同一实例，skills 同样可见且不重复
        @Expect(editor.skills.size, 2)
        @Expect(editor.skills[0].id, 10)
    }

    // R-M10 回归：同一目标表的两个 ref_to 带相同嵌套 include，但目标不同（author=用户A、
    // editor=用户B）——合并后同一递归层装配两个目标，各自的 skills 互不串扰、不丢失
    // （防「按目标表去重的朴素守卫把第二条目标整体跳过」的漏数据回归）。
    @TestCase
    public func testDiamondIncludeDistinctTargetsNoDataLoss(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("author_id", false),
            MapperMockColumnInfo("editor_id", false),
        ]
        let mainRow = Array<Any>(4, {i =>
            if (i == 0) { 1 } else if (i == 1) { "p1" } else if (i == 2) { 99 } else { 100 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRows = [
            Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }}),
            Array<Any>(2, {i => if (i == 0) { 100 } else { "Bob" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, userRows))
        let skillCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("name", false),
        ]
        let skillRows = [
            Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { 99 } else { "s1" }}),
            Array<Any>(3, {i => if (i == 0) { 11 } else if (i == 1) { 99 } else { "s2" }}),
            Array<Any>(3, {i => if (i == 0) { 12 } else if (i == 1) { 100 } else { "s3" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(skillCols, skillRows))
        let q = DiamondPost.query()
            .include(DiamondPostRel.author.withInclude(DiamondUserRel.skills))
            .include(DiamondPostRel.editor.withInclude(DiamondUserRel.skills))
            .using(tx)
        let entities = q.all()
        // 主查询 + 合并批量（两个目标一次 IN）+ skills 一次 = 三次查询
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(entities.size, 1)
        let author = entities[0].author.getOrThrow()
        let editor = entities[0].editor.getOrThrow()
        @Expect(author.id, 99)
        @Expect(author.skills.size, 2)
        @Expect(author.skills[0].name, "s1")
        @Expect(author.skills[1].name, "s2")
        @Expect(editor.id, 100)
        @Expect(editor.skills.size, 1)
        @Expect(editor.skills[0].name, "s3")
    }

    // 嵌套 include 环（自定义 IRelation getNested 返回自身）：深度守卫必须终止递归并抛错。
    @TestCase
    public func testNestedCycleDepthGuard(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        // 环每层发一条批量查询，预置超过 MaxNestedDepth 的结果。每层查询的 IN 主键集合：
        // 第 1 层 = author 目标实体 id（99）；第 2 层起 = CyclicNestedRelation 提取器返回 1。
        // 故第 1 条 mock 行的 fk 用 99 命中分组、其余用 1 命中，确保每层都有目标实体、
        // 递归持续进行直到深度守卫抛错。
        let cycleCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("parent_id", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cycleCols,
            [Array<Any>(2, {i => if (i == 0) { 1 } else { 99 }})]))
        for (i in 0..30) {
            conn.stmt.queryResultQueue.add(MapperMockQueryResult(cycleCols,
                [Array<Any>(2, {i => if (i == 0) { 1 } else { 1 }})]))
        }
        let q = NestedPost.query()
            .include(NestedPostRel.author.withInclude(CyclicNestedRelation()))
            .using(tx)
        try {
            q.all()
            @Fail("expected QueryException from nested include depth guard")
        } catch (e: QueryException) {
            @Expect(e.message.contains("depth"), true)
        }
    }
}

// Task 7: includeAll 字符串点号路径 DSL（宏层 forName + getTargetRelResolver）。
// 全部断言针对宏生成的 Nested* fixture 链（NestedPost.author → NestedUser.profile →
// NestedProfile.skills，NestedUser.tags 为 ref_many NestedTag）。
@Test
public class StringPathIncludeTest {

    // forName：已知关系名解析到对应静态成员（author → ref_to NestedUser）。
    @TestCase
    public func testForNameResolvesKnownRelation(): Unit {
        match (NestedPostRel.forName("author")) {
            case Some(r) =>
                let (kind, name, targetTable, _, _, _) = r.resolve()
                @Expect(kind == RelationKind.RefToRel, true)
                @Expect(name, "author")
                @Expect(targetTable, "nestedUser")
            case None => @Fail("forName('author') should return Some")
        }
    }

    // forName：与宏生成的静态成员是同一个对象（includeAll 顶层解析必须等价于 include(PostRel.author)）。
    @TestCase
    public func testForNameReturnsSameStaticMember(): Unit {
        match (NestedPostRel.forName("author")) {
            case Some(r) =>
                let (k1, n1, t1, f1, v1, fs1) = r.resolve()
                let (k2, n2, t2, f2, v2, fs2) = NestedPostRel.author.resolve()
                @Expect(k1 == k2, true)
                @Expect(n1, n2)
                @Expect(t1, t2)
                @Expect(f1, f2)
                @Expect(v1, v2)
                @Expect(fs1.size, fs2.size)
            case None => @Fail("forName('author') should return Some")
        }
    }

    // forName：未知关系名返回 None。
    @TestCase
    public func testForNameReturnsNoneForUnknown(): Unit {
        match (NestedPostRel.forName("doesNotExist")) {
            case Some(_) => @Fail("expected None for unknown relation name")
            case None => ()
        }
    }

    // getTargetRelResolver：关系携带目标实体 Rel 类的 forName 闭包（author 的目标是
    // NestedUser，故 "profile" 解析到 NestedUserRel.profile）。
    @TestCase
    public func testGetTargetRelResolver(): Unit {
        match (NestedPostRel.author.getTargetRelResolver()("profile")) {
            case Some(r) =>
                let (_, name, targetTable, _, _, _) = r.resolve()
                @Expect(name, "profile")
                @Expect(targetTable, "nestedProfile")
            case None => @Fail("expected 'profile' via target rel resolver")
        }
        match (NestedPostRel.author.getTargetRelResolver()("doesNotExist")) {
            case Some(_) => @Fail("expected None for unknown nested relation")
            case None => ()
        }
    }

    // 单段路径：includeAll(["author"]) 等价于 include(NestedPostRel.author)。
    @TestCase
    public func testIncludeAllSinglePath(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let q = NestedPost.query()
            .includeAll(["author"])
            .using(tx)
        let entities = q.all()
        // 主查询 + author 批量 = 两次查询
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"nestedUser\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.isSome(), true)
        @Expect(entities[0].author.getOrThrow().id, 99)
        @Expect(entities[0].author.getOrThrow().name, "Alice")
    }

    // 多段路径：includeAll(["author.profile"]) 等价于
    // include(NestedPostRel.author.withInclude(NestedUserRel.profile))。
    @TestCase
    public func testIncludeAllNestedPath(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let profileCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("bio", false),
        ]
        let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 99 } else { "engineer" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        let q = NestedPost.query()
            .includeAll(["author.profile"])
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"nestedUser\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedProfile\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("WHERE \"user_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.getOrThrow().id, 99)
        @Expect(entities[0].author.getOrThrow().profile.isSome(), true)
        @Expect(entities[0].author.getOrThrow().profile.getOrThrow().bio, "engineer")
    }

    // 多路径数组：includeAll(["profile", "comments"]) 一次装配两条顶层关系。
    @TestCase
    public func testIncludeAllMultiplePaths(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRow = Array<Any>(2, {i => if (i == 0) { 1 } else { "u1" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let profileCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("bio", false),
        ]
        let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 1 } else { "engineer" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        let commentCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("body", false),
        ]
        let commentRow = Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { 1 } else { "c1" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(commentCols, [commentRow]))
        let q = NestedUser.query()
            .includeAll(["profile", "comments"])
            .using(tx)
        let entities = q.all()
        // 主查询 + profile 批量 + comments 批量（不同目标表各一条）= 三次查询
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"nestedProfile\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedComment\""), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].profile.getOrThrow().bio, "engineer")
        @Expect(entities[0].comments.size, 1)
        @Expect(entities[0].comments[0].body, "c1")
    }

    // 三层深路径：includeAll(["author.profile.skills"])，每层一条批量查询共 4 次。
    @TestCase
    public func testIncludeAllDeepPath(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
        ]
        let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let userCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let profileCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("bio", false),
        ]
        let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 99 } else { "engineer" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        let skillCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("profile_id", false),
            MapperMockColumnInfo("name", false),
        ]
        let skillRow = Array<Any>(3, {i => if (i == 0) { 100 } else if (i == 1) { 5 } else { "cangjie" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(skillCols, [skillRow]))
        let q = NestedPost.query()
            .includeAll(["author.profile.skills"])
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 4)
        @Expect(conn.stmt.capturedSqlHistory[3].contains("FROM \"nestedSkill\""), true)
        @Expect(conn.stmt.capturedSqlHistory[3].contains("WHERE \"profile_id\" IN (?)"), true)
        @Expect(entities.size, 1)
        let profile = entities[0].author.getOrThrow().profile.getOrThrow()
        @Expect(profile.skills.size, 1)
        @Expect(profile.skills[0].id, 100)
        @Expect(profile.skills[0].name, "cangjie")
    }

    // 嵌套 ref_many：includeAll(["tags.notes"])——junction 源列仍是当前层级表
    // nestedUser_id（顶层主查询表），与 withInclude 链等价。
    @TestCase
    public func testIncludeAllRefManyNested(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        let mainCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
        ]
        let mainRow = Array<Any>(2, {i => if (i == 0) { 1 } else { "u1" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let tagCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("nestedUser_id", false),
        ]
        let tagRow = Array<Any>(3, {i => if (i == 0) { 10 } else if (i == 1) { "t1" } else { 1 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(tagCols, [tagRow]))
        let noteCols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("tag_id", false),
            MapperMockColumnInfo("body", false),
        ]
        let noteRow = Array<Any>(3, {i => if (i == 0) { 100 } else if (i == 1) { 10 } else { "n1" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(noteCols, [noteRow]))
        let q = NestedUser.query()
            .includeAll(["tags.notes"])
            .using(tx)
        let entities = q.all()
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"nestedUser_tags\" JOIN \"nestedTag\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("\"nestedUser_tags\".\"nestedUser_id\" IN (?)"), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("FROM \"nestedTagNote\""), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].tags.size, 1)
        @Expect(entities[0].tags[0].id, 10)
        @Expect(entities[0].tags[0].notes.size, 1)
        @Expect(entities[0].tags[0].notes[0].body, "n1")
    }

    // includeAll 与 withInclude 链的 SQL 完全一致（同一装配路径，等价性证明）。
    @TestCase
    public func testIncludeAllEqualsWithIncludeChain(): Unit {
        let connA = CaptureConnection()
        let txA = Tx(connA)
        txA.begin()
        let connB = CaptureConnection()
        let txB = Tx(connB)
        txB.begin()
        for (conn in [connA, connB]) {
            let mainCols: Array<SqlColumnInfo> = [
                MapperMockColumnInfo("id", false),
                MapperMockColumnInfo("title", false),
                MapperMockColumnInfo("user_id", false),
            ]
            let mainRow = Array<Any>(3, {i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { 99 }})
            conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
            let userCols: Array<SqlColumnInfo> = [
                MapperMockColumnInfo("id", false),
                MapperMockColumnInfo("name", false),
            ]
            let userRow = Array<Any>(2, {i => if (i == 0) { 99 } else { "Alice" }})
            conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
            let profileCols: Array<SqlColumnInfo> = [
                MapperMockColumnInfo("id", false),
                MapperMockColumnInfo("user_id", false),
                MapperMockColumnInfo("bio", false),
            ]
            let profileRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { 99 } else { "engineer" }})
            conn.stmt.queryResultQueue.add(MapperMockQueryResult(profileCols, [profileRow]))
        }
        let a = NestedPost.query().includeAll(["author.profile"]).using(txA).all()
        let b = NestedPost.query()
            .include(NestedPostRel.author.withInclude(NestedUserRel.profile))
            .using(txB)
            .all()
        @Expect(connA.stmt.capturedSqlHistory.size, connB.stmt.capturedSqlHistory.size)
        for (i in 0..connA.stmt.capturedSqlHistory.size) {
            @Expect(connA.stmt.capturedSqlHistory[i], connB.stmt.capturedSqlHistory[i])
        }
        @Expect(a.size, b.size)
        @Expect(a[0].author.getOrThrow().id, b[0].author.getOrThrow().id)
        @Expect(a[0].author.getOrThrow().profile.getOrThrow().bio, b[0].author.getOrThrow().profile.getOrThrow().bio)
    }

    // 未知顶层关系：立即抛 QueryException（带关系名），不发任何查询。
    @TestCase
    public func testIncludeAllUnknownTopLevelThrows(): Unit {
        let q = NestedPost.query()
        try {
            q.includeAll(["doesNotExist"])
            @Fail("expected QueryException for unknown top-level relation")
        } catch (e: QueryException) {
            @Expect(e.message.contains("doesNotExist"), true)
        }
    }

    // 未知嵌套关系：抛 QueryException，消息带失败段与已解析前缀。
    @TestCase
    public func testIncludeAllUnknownNestedThrows(): Unit {
        let q = NestedPost.query()
        try {
            q.includeAll(["author.doesNotExist"])
            @Fail("expected QueryException for unknown nested relation")
        } catch (e: QueryException) {
            @Expect(e.message.contains("doesNotExist"), true)
            @Expect(e.message.contains("author"), true)
        }
    }

    // 空路径字符串：抛 QueryException。
    @TestCase
    public func testIncludeAllEmptyPathThrows(): Unit {
        let q = NestedPost.query()
        try {
            q.includeAll([""])
            @Fail("expected QueryException for empty path")
        } catch (e: QueryException) {
            @Expect(e.message.contains("empty"), true)
        }
    }

    // 空路径段（"author..profile" / ".author"）：抛 QueryException。
    @TestCase
    public func testIncludeAllEmptySegmentThrows(): Unit {
        let q = NestedPost.query()
        try {
            q.includeAll(["author..profile"])
            @Fail("expected QueryException for empty path segment")
        } catch (e: QueryException) {
            @Expect(e.message.contains("empty"), true)
        }
        try {
            q.includeAll([".author"])
            @Fail("expected QueryException for leading dot")
        } catch (e: QueryException) {
            @Expect(e.message.contains("empty"), true)
        }
    }

    // 未挂载 relResolver 的手工 Query：抛带说明的 QueryException。
    @TestCase
    public func testIncludeAllNoResolverWiredThrows(): Unit {
        let q = Query<NestedPost>()
        try {
            q.includeAll(["author"])
            @Fail("expected QueryException when no rel resolver wired")
        } catch (e: QueryException) {
            @Expect(e.message.contains("resolver"), true)
        }
    }

    // 空路径数组：no-op，返回自身（对返回的 Query 继续 include 会反映到原 Query 上）。
    @TestCase
    public func testIncludeAllEmptyPathsNoop(): Unit {
        let q = NestedPost.query()
        let same = q.includeAll([])
        @Expect(q.included.size, 0)
        same.include(NestedPostRel.author)
        @Expect(q.included.size, 1)
    }
}

// ─── M8: 聚合列名方言引号化 + String min/max ───────────────

@Test
public class AggregateQueryTest {
    @TestCase
    public func testSumRendersQuotedColumnAndReadsValue(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [Array<Any>(1, {i => 42})]))
        let q = Query<Int64>().from("posts").using(tx)
        @Expect(q.sum(Col<Int64>("id")), 42)
        // M8: 列名经 dialect.quoteIdentifier（SQLite 双引号），不再 Raw 拼接裸列名
        @Expect(conn.stmt.capturedSql, "SELECT SUM(\"id\") FROM \"posts\"")
    }

    @TestCase
    public func testAvgReadsFloatValue(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [Array<Any>(1, {i => 2.5})]))
        let q = Query<Int64>().from("posts").using(tx)
        @Expect(q.avg(Col<Int64>("score")), 2.5)
        @Expect(conn.stmt.capturedSql, "SELECT AVG(\"score\") FROM \"posts\"")
    }

    @TestCase
    public func testMinStringReturnsString(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], [Array<Any>(1, {i => "abc"})]))
        let q = Query<Int64>().from("posts").using(tx)
        @Expect(q.min(Col<String>("name")), "abc")
        @Expect(conn.stmt.capturedSql, "SELECT MIN(\"name\") FROM \"posts\"")
    }

    @TestCase
    public func testMaxStringEmptyResultReturnsEmptyString(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], []))
        let q = Query<Int64>().from("posts").using(tx)
        @Expect(q.max(Col<String>("name")), "")
        @Expect(conn.stmt.capturedSql, "SELECT MAX(\"name\") FROM \"posts\"")
    }

    @TestCase
    public func testMaxInt64EmptyResultReturnsZero(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(MapperMockQueryResult([], []))
        let q = Query<Int64>().from("posts").using(tx)
        @Expect(q.max(Col<Int64>("id")), 0)
    }
}

// ─── R-I5: 分组查询 count/page/exists/聚合携带 GROUP BY/HAVING ──────────
// 修复前 copyDataClauses 只保留 From/Where/Join，count/exists/聚合对分组查询
// 静默返回未分组结果，page().total 与 items 不一致。修复后：
//   - count()  对分组查询返回「分组数」（每组一行 COUNT(*)，数行数），与 page 数据端对齐；
//   - exists() 按组判断是否存在；
//   - 聚合     携带 GroupBy/Having，取结果首行（首个分组）的值（见 aggregate 注释）。

@Test
public class R5GroupedQueryTest {

    @TestCase
    public func testCountWithGroupByCountsGroups(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        // 3 个分组 → COUNT(*) 每组一行，3 行
        conn.stmt.queryResult = MapperMockQueryResult(
            [MapperMockColumnInfo("COUNT(*)", false)],
            [Array<Any>(1, {i => 2}), Array<Any>(1, {i => 5}), Array<Any>(1, {i => 3})]
        )
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .groupBy([Expr.Column("dept")])
            .using(tx)
        let cnt = q.count()
        @Expect(cnt, 3)
        @Expect(conn.stmt.capturedSql, "SELECT COUNT(*) FROM \"t\" GROUP BY \"dept\"")
    }

    @TestCase
    public func testCountWithGroupByAndHavingRendersBoth(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = MapperMockQueryResult(
            [MapperMockColumnInfo("COUNT(*)", false)],
            [Array<Any>(1, {i => 7})]
        )
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .groupBy([Expr.Column("dept")])
            .having([Expr.Binary(Expr.FuncCall("COUNT", [Expr.Column("id")]), BinOp.Gt, Expr.Value(5))])
            .using(tx)
        let cnt = q.count()
        @Expect(cnt, 1)
        @Expect(conn.stmt.capturedSql, "SELECT COUNT(*) FROM \"t\" GROUP BY \"dept\" HAVING COUNT(\"id\") > ?")
    }

    // R-I5 核心：分组 page 的 total = 分组数（COUNT(*) 行数），与分页数据（每组一条）对齐。
    @TestCase
    public func testPageWithGroupByTotalCountsGroups(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        // 分组 count：4 行 = 4 个分组
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(
            [MapperMockColumnInfo("COUNT(*)", false)],
            [Array<Any>(1, {i => 1}), Array<Any>(1, {i => 1}), Array<Any>(1, {i => 1}), Array<Any>(1, {i => 1})]
        ))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("dept", false),
        ]
        let rows = [
            Array<Any>(2, {i => if (i == 0) { 1 } else { "a" }}),
            Array<Any>(2, {i => if (i == 0) { 2 } else { "b" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let q = Query<Int64>()
            .select([Expr.Column("id"), Expr.Column("dept")])
            .from("t")
            .groupBy([Expr.Column("dept")])
            .using(tx)
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        let pg = q.page(1, 10)
        @Expect(pg.total, 4)
        @Expect(pg.items.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("GROUP BY"), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("GROUP BY"), true)
    }

    // exists() 携带 GROUP BY：SQL 应含 GROUP BY，且按组判断存在性。
    @TestCase
    public func testExistsWithGroupByCarriesGroupBy(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = RowQueryResult(1)
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .groupBy([Expr.Column("dept")])
            .using(tx)
        let exists = q.exists()
        @Expect(exists, true)
        @Expect(conn.stmt.capturedSql, "SELECT 1 FROM \"t\" GROUP BY \"dept\" LIMIT 1")
    }

    // 聚合携带 GROUP BY/HAVING：取结果首行（首个分组）的值。
    @TestCase
    public func testAggregateWithGroupByCarriesGroupBy(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = MapperMockQueryResult(
            [MapperMockColumnInfo("SUM(\"salary\")", false)],
            [Array<Any>(1, {i => 42})]
        )
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .groupBy([Expr.Column("dept")])
            .using(tx)
        let s = q.sum(Col<Int64>("salary"))
        @Expect(s, 42)
        @Expect(conn.stmt.capturedSql, "SELECT SUM(\"salary\") FROM \"t\" GROUP BY \"dept\"")
    }

    // 非分组查询的 count 语义保持不变（取首行值）。
    @TestCase
    public func testCountWithoutGroupByStillReadsFirstRowValue(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = MapperMockQueryResult(
            [MapperMockColumnInfo("COUNT(*)", false)],
            [Array<Any>(1, {i => 7})]
        )
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .using(tx)
        let cnt = q.count()
        @Expect(cnt, 7)
        @Expect(conn.stmt.capturedSql, "SELECT COUNT(*) FROM \"t\"")
    }

    // R-I5 延续: 分组查询无分组时（HAVING 滤掉全部组/空表）count() 必须为 0——
    // 行数计数循环对空结果集不产生计数（修复前若误取首行值，空集读到 0 之外的错误值）。
    @TestCase
    public func testCountWithGroupByEmptyReturnsZero(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResult = MapperMockQueryResult(
            [MapperMockColumnInfo("COUNT(*)", false)],
            []
        )
        let q = Query<Int64>()
            .select([Expr.Column("id")])
            .from("t")
            .groupBy([Expr.Column("dept")])
            .using(tx)
        let cnt = q.count()
        @Expect(cnt, 0)
    }

    // R-I5 延续: 分组 page 空结果时 total = 0、items 空，与分组 count 语义一致。
    @TestCase
    public func testPageWithGroupByEmptyTotalZero(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        tx.begin()
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(
            [MapperMockColumnInfo("COUNT(*)", false)],
            []
        ))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("dept", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, []))
        let q = Query<Int64>()
            .select([Expr.Column("id"), Expr.Column("dept")])
            .from("t")
            .groupBy([Expr.Column("dept")])
            .using(tx)
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        let pg = q.page(1, 10)
        @Expect(pg.total, 0)
        @Expect(pg.items.size, 0)
    }
}
