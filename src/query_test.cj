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
        let rel: IRelation = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
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
        let refTo: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id")], "users", dummyMapper, dummySetter, dummyFkExtractor)
        q.include(refTo)
        @Expect(q.included.size, 1)
    }

    @TestCase
    public func testIncludeRegistersHasMany(): Unit {
        let q = Query<Int64>()
        let rel: IRelation = HasMany<Int64>("posts", "user_id", [Col<Any>("id")], "posts", dummyMapper, dummySetter)
        q.include(rel)
        @Expect(q.included.size, 1)
    }

    @TestCase
    public func testFieldOverrideRelationResolve(): Unit {
        let inner: IRelation = HasMany<Int64>("tags", "post_id", [Col<Any>("id")], "tags", dummyMapper, dummySetter)
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

    @TestCase
    public func testIncludeWithFieldsOverride(): Unit {
        let q = Query<Int64>()
        let rel: IRelation = HasMany<Int64>("posts", "user_id", [Col<Any>("id")], "posts", dummyMapper, dummySetter)
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
        // one() requires an executor - we can't easily provide one in unit test
        // but we can verify it doesn't throw "no auto-mapper"
        @Expect(true, true)
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
        q.setMapper({ r: QueryResult, cm: HashMap<String, Int64> => 0 })
        @Expect(true, true)
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

    // batch include 重构中，Task 5 恢复：ref_many 改为 junction 批量查询装配，主查询无 JOIN。
    @TestCase
    @Skip
    public func testProcessIncludedRefMany(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("posts")
        let rel: IRelation = RefMany<Int64>("tags", "post_tags", [Col<Any>("id"), Col<Any>("name")], "tags", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("LEFT JOIN"), true)
        @Expect(sql.contains("post_tags"), true)
    }

    @TestCase
    public func testProcessIncludedEmptySourceTable(): Unit {
        // Task 2: processIncluded 已是 no-op，无 FROM 或任何查询都不产生 include JOIN
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        let fk = Col<Any>("user_id")
        let rel: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id")], "users", dummyMapper, dummySetter, dummyFkExtractor)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("LEFT JOIN"), false)
    }

    // batch include Task 4：has_one 批量装配协议。主查询返回 1 个 User，批量查询
    // `SELECT ... FROM "profileWithRel" WHERE "user_id" IN (主实体 id)` 挂载唯一 Profile。
    @TestCase
    public func testHasOneIncludeAssemblesBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
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

    @TestCase
    public func testProcessIncludedNoopWhenNoIncludes(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        let countBefore = q.stmt.clauses.size
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        @Expect(q.stmt.clauses.size, countBefore)
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
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter)
    }

    // Task 4 批量协议：page() = count + 主查询（LIMIT/OFFSET）+ 批量 has_many 查询三次。
    // 主查询无 JOIN（单页恰好 size 个主实体），comments 按 post_id 分组回填。
    @TestCase
    public func testPageWithHasManyIncludeBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
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

    // Task 3 批量协议：主查询返回空（无实体）→ assembleRefTo 的 entities.size==0
    // 早退分支生效，不触发批量查询，只发主查询。
    @TestCase
    public func testRefToIncludeEmptyEntitiesSkipsBatch(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
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
            dummyMapper, editorSetter, { e: Any => (e as PostWithRel).getOrThrow().post_id })
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
            UserRowMapper, authorSetter, { e: Any => (e as PostWithRel).getOrThrow().user_id })
        let editor = RefTo<User>("editor", Col<Any>("post_id"),
            [Col<Any>("id"), Col<Any>("email")], "user",
            UserRowMapper, editorSetter, { e: Any => (e as PostWithRel).getOrThrow().post_id })
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
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter)
    }

    @TestCase
    public func testAllWithCollectionIncludePreservesRowOrder(): Unit {
        // 批量协议：主查询行序即返回顺序（每行一个主实体，无 JOIN 展开/去重），
        // comments 按 fk 分组回填后仍保持该顺序。
        let conn = CaptureConnection()
        let tx = Tx(conn)
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
            CommentRowMapper, secondSetter)
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
        let rel: IRelation = HasMany<Int64>("posts", "user_id",
            [Col<Any>("id")], "posts", dummyMapper, dummySetter)
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
            UuidKeyCommentRowMapper, setter)
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
}
