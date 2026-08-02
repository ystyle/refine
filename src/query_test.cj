package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.HashMap
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

// 模拟驱动 SQL NULL 单元格：值是 Option<Int64>.None，任何 get<T> 类型匹配都失败
// （get<T> 抛类型不匹配，getOrNull<T> 返回 None），与真实驱动对 NULL 列的行为一致。
private func sqlNull(): Any {
    Option<Int64>.None
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
        let rel: IRelation = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter)
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
    public func testQualifyExpr(): Unit {
        let dialect = SQLiteDialect()
        let col = Expr.Column("id")
        let qualified = qualifyExpr(col, "user", dialect)
        match (qualified) {
            case Expr.Raw(s) => @Expect(s, "\"user\".\"id\"")
            case _ => @Fail("expected Raw")
        }
        let binary = Expr.Binary(Expr.Column("id"), BinOp.Eq, Expr.Value(1))
        let qBinary = qualifyExpr(binary, "user", dialect)
        match (qBinary) {
            case Expr.Binary(l, op, r) =>
                @Expect(op, BinOp.Eq)
                match (l) {
                    case Expr.Raw(s) => @Expect(s, "\"user\".\"id\"")
                    case _ => @Fail("expected Raw left")
                }
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testQualifyExprUnary(): Unit {
        let dialect = SQLiteDialect()
        let unary = Expr.Unary(UnaryOp.Not, Expr.Column("id"))
        let q = qualifyExpr(unary, "t", dialect)
        match (q) {
            case Expr.Unary(op, e) =>
                @Expect(op, UnaryOp.Not)
                match (e) {
                    case Expr.Raw(s) => @Expect(s, "\"t\".\"id\"")
                    case _ => @Fail("expected Raw")
                }
            case _ => @Fail("expected Unary")
        }
    }

    @TestCase
    public func testQualifyExprAliased(): Unit {
        let dialect = SQLiteDialect()
        let aliased = Expr.Aliased(Expr.Column("id"), "myid")
        let q = qualifyExpr(aliased, "t", dialect)
        match (q) {
            case Expr.Aliased(e, alias) =>
                @Expect(alias, "myid")
                match (e) {
                    case Expr.Raw(s) => @Expect(s, "\"t\".\"id\"")
                    case _ => @Fail("expected Raw")
                }
            case _ => @Fail("expected Aliased")
        }
    }

    @TestCase
    public func testQualifyExprOrdered(): Unit {
        let dialect = SQLiteDialect()
        let ordered = Expr.Ordered(Expr.Column("id"), "ASC")
        let q = qualifyExpr(ordered, "t", dialect)
        match (q) {
            case Expr.Ordered(e, dir) =>
                @Expect(dir, "ASC")
                match (e) {
                    case Expr.Raw(s) => @Expect(s, "\"t\".\"id\"")
                    case _ => @Fail("expected Raw")
                }
            case _ => @Fail("expected Ordered")
        }
    }

    @TestCase
    public func testQualifyExprValuePassThrough(): Unit {
        let dialect = SQLiteDialect()
        let v = Expr.Value(42)
        let q = qualifyExpr(v, "t", dialect)
        match (q) {
            case Expr.Value(n) => match (n) {
                case i: Int64 => @Expect(i, 42)
                case _ => @Fail("expected Int64")
            }
            case _ => @Fail("expected Value")
        }
    }

    @TestCase
    public func testHasCollectionInclude(): Unit {
        let q = Query<Int64>()
        @Expect(q.included.size, 0)
        // Add RefTo - not a collection
        let fk = Col<Any>("user_id")
        let refTo: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id")], "users", dummyMapper, dummySetter)
        q.include(refTo)
        @Expect(q.included.size, 1)
    }

    @TestCase
    public func testHasCollectionIncludeWithHasMany(): Unit {
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
    public func testIsNullId(): Unit {
        // I7: isNullId 语义——目标 id 列为 NULL 时不下挂载（getOrNull<String> → None）。
        // isNullId 是 Query<T> 私有方法，通过 include 装配路径做真实行为测试：
        // 见 testCollectionIncludeSkipsNullChildId / testRefToIncludeSkipsNullTargetId。
        @Expect(true, true)
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
    public func testStripPrefix(): Unit {
        let cm = HashMap<String, Int64>()
        cm.add("id", 1)
        cm.add("name", 2)
        cm.add("posts.id", 3)
        cm.add("posts.title", 4)
        let stripped = stripPrefix(cm, "posts.")
        @Expect(stripped.size, 2)
        @Expect(stripped.contains("id"), true)
        @Expect(stripped.contains("title"), true)
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

    @TestCase
    public func testProcessIncludedAddsJoins(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id"), Expr.Column("name")])
        q.from("users")
        let fk = Col<Any>("user_id")
        let rel: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id"), Col<Any>("name")], "users", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        var hasJoin = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.JoinClause(_, _, _) => hasJoin = true
                case _ => ()
            }
        }
        @Expect(hasJoin, true)
    }

    @TestCase
    public func testProcessIncludedQualifiesWhere(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        q.filter(Expr.Binary(Expr.Column("id"), BinOp.Eq, Expr.Value(1)))
        let fk = Col<Any>("user_id")
        let rel: IRelation = HasMany<Int64>("posts", "user_id", [Col<Any>("id")], "posts", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("\"users\".\"id\""), true)
    }

    @TestCase
    public func testProcessIncludedHasMany(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        let rel: IRelation = HasMany<Int64>("posts", "user_id", [Col<Any>("id"), Col<Any>("title")], "posts", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("LEFT JOIN"), true)
        @Expect(sql.contains("posts"), true)
    }

    @TestCase
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
        // Query without FROM clause — processIncluded should return early
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        let fk = Col<Any>("user_id")
        let rel: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id")], "users", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("LEFT JOIN"), false)
    }

    @TestCase
    public func testProcessIncludedHasOne(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        let rel: IRelation = HasOne<Int64>("profile", "user_id", [Col<Any>("id")], "profiles", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("LEFT JOIN"), true)
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

    @TestCase
    public func testProcessIncludedQualifiesSelect(): Unit {
        let q = Query<Int64>()
        q.select([Expr.Column("id")])
        q.from("users")
        let fk = Col<Any>("user_id")
        let rel: IRelation = RefTo<Int64>("author", fk, [Col<Any>("id")], "users", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("\"users\".\"id\""), true)
    }

    @TestCase
    public func testProcessIncludedQualifiesOrderByGroupByHaving(): Unit {
        // I1: include 产生的 JOIN 后，ORDER BY / GROUP BY / HAVING 必须同样限定表名，
        // 否则两侧表都有 "id" 时所有方言都会报 ambiguous column。
        let q = Query<Int64>()
        q.select([Expr.Column("id"), Expr.Column("dept")])
        q.from("users")
        q.filter(Expr.Binary(Expr.Column("status"), BinOp.Eq, Expr.Value("active")))
        q.order([Expr.Ordered(Expr.Column("id"), "ASC")])
        q.groupBy([Expr.Column("dept")])
        q.having([Expr.Binary(Expr.Column("cnt"), BinOp.Gt, Expr.Value(5))])
        let fk = Col<Any>("user_id")
        let rel: IRelation = HasMany<Int64>("posts", "user_id", [Col<Any>("id")], "posts", dummyMapper, dummySetter)
        q.include(rel)
        let dialect = SQLiteDialect()
        q.processIncluded(dialect)
        let (sql, _) = dialect.render(q.stmt)
        @Expect(sql.contains("ORDER BY \"users\".\"id\" ASC"), true)
        @Expect(sql.contains("GROUP BY \"users\".\"dept\""), true)
        @Expect(sql.contains("HAVING \"users\".\"cnt\" > ?"), true)
        @Expect(sql.contains("ORDER BY \"id\""), false)
        @Expect(sql.contains("GROUP BY \"dept\""), false)
        @Expect(sql.contains("HAVING \"cnt\""), false)
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

// ─── C4: page() 集合 include 去重 + countWith 含集合 include 用 COUNT(DISTINCT) ──

@Test
public class C4PageCollectionTest {

    private func commentsRel(): IRelation {
        HasMany<UuidComment>("comments", "post_id",
            [Col<Any>("id"), Col<Any>("body")], "uuidComment",
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter)
    }

    @TestCase
    public func testPageWithHasManyIncludeDedupsParents(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        conn.stmt.queryResultQueue.add(RowQueryResult(2))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("comments.id", false),
            MapperMockColumnInfo("comments.body", false),
        ]
        let rows = [
            Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post" } else if (i == 2) { "c1" } else { "first" }}),
            Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post" } else if (i == 2) { "c2" } else { "second" }}),
            Array<Any>(4, {i => if (i == 0) { 6 } else if (i == 1) { "other" } else if (i == 2) { "c3" } else { "third" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let q = UuidPostWithRel.query().include(commentsRel(), [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let pg = q.page(1, 10)
        @Expect(pg.total, 2)
        @Expect(pg.items.size, 2)
        var byId = HashMap<Int64, UuidPostWithRel>()
        for (e in pg.items) { byId[e.id] = e }
        @Expect(byId.size, 2)
        @Expect(byId.get(5).getOrThrow().comments.size, 2)
        @Expect(byId.get(6).getOrThrow().comments.size, 1)
    }

    @TestCase
    public func testPageWithHasManyIncludeCountUsesDistinct(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        conn.stmt.queryResultQueue.add(RowQueryResult(2))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("comments.id", false),
            MapperMockColumnInfo("comments.body", false),
        ]
        let rows = [
            Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post" } else if (i == 2) { "c1" } else { "first" }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, rows))
        let q = UuidPostWithRel.query().include(commentsRel(), [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let pg = q.page(1, 10)
        @Expect(pg.total, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("COUNT(DISTINCT"), true)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("\"uuidPostWithRel\".\"id\""), true)
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

    @TestCase
    public func testPageWithRefToIncludeJoins(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        conn.stmt.queryResultQueue.add(RowQueryResult(1))
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
            MapperMockColumnInfo("post.id", false),
            MapperMockColumnInfo("post.title", false),
            MapperMockColumnInfo("post.content", false),
        ]
        let row = Array<Any>(6, {i =>
            if (i == 0) { 5 } else if (i == 1) { "nice" } else if (i == 2) { "p1" }
            else if (i == 3) { "p1" } else if (i == 4) { "First" } else { "Hello" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [row]))
        let q = UuidRefComment.query().include(UuidRefCommentRel.post).using(tx)
        let pg = q.page(1, 10)
        @Expect(pg.total, 1)
        @Expect(pg.items.size, 1)
        @Expect(pg.items[0].post.isSome(), true)
        @Expect(pg.items[0].post.getOrThrow().id, "p1")
        @Expect(pg.items[0].post.getOrThrow().title, "First")
        // page() 必须先 processIncluded：分页 SQL 必须带 RefTo 的 LEFT JOIN
        @Expect(conn.stmt.capturedSqlHistory[1].contains("LEFT JOIN"), true)
    }

    // I7: RefTo 目标 id 列存在但为 NULL（LEFT JOIN 无匹配）时，isNullId 必须判真，
    // 主实体保留、目标不挂载、不抛异常。修复前依赖驱动对 get<String> 的异常行为，跨驱动脆弱。
    // 用自定义 base mapper（不读 RefTo 字段），使 wrapMapper.isNullId 成为目标 id 的首个读取点。
    @TestCase
    public func testRefToIncludeSkipsNullTargetId(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
            MapperMockColumnInfo("post.id", false),
        ]
        // post.id 为 NULL（非 String 模拟驱动 NULL，getOrNull<String> → None）
        let row = Array<Any>(4, {i =>
            if (i == 0) { 5 } else if (i == 1) { "orphan" } else if (i == 2) { "nope" }
            else { 0 }
        })
        conn.stmt.queryResult = MapperMockQueryResult(cols, [row])
        let q = UuidRefComment.query()
        q.setMapper({ result: QueryResult, cm: HashMap<String, Int64> =>
            let e = UuidRefComment()
            e.id = result.get<Int64>(cm.get("id").getOrThrow())
            e.body = result.get<String>(cm.get("body").getOrThrow())
            e.post_id = result.get<String>(cm.get("post_id").getOrThrow())
            e
        })
        q.include(UuidRefCommentRel.post)
        q.using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].post.isNone(), true)
    }

    // I7: 集合 include 子行 id 为 NULL（LEFT JOIN 无匹配）时，isNullId 必须判真，
    // 不挂载子对象且不抛异常（修复前 get<String> 的类型不匹配异常被 try/catch 吞掉，
    // 但依赖驱动边界行为；现用文档化 getOrNull 判空）。
    @TestCase
    public func testCollectionIncludeSkipsNullChildId(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("comments.id", false),
            MapperMockColumnInfo("comments.body", false),
        ]
        // comments.id 为 NULL（非 String 模拟驱动 NULL）
        let rows = [
            Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post" } else if (i == 2) { 0 } else { "orphan" }}),
        ]
        conn.stmt.queryResult = MapperMockQueryResult(cols, rows)
        let q = UuidPostWithRel.query().include(commentsRel(), [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].comments.size, 0)
    }

    // I7 follow-up: 真实 LEFT JOIN 无匹配时，目标 id 列「存在但为 NULL」。
    // 之前的 I7/C2 用例只覆盖「列缺失」或「自定义 base mapper」，未覆盖生成 base mapper
    // 先于 wrapMapper.isNullId 读取 NULL 列的真实路径（生成代码 result.get<Int64> 会抛异常）。
    // 此处走默认 auto mapper（生成 RowMapper + wrapMapper 链），author.id 用 None 模拟驱动 NULL：
    // get<Int64> 抛类型不匹配（旧代码崩溃），getOrNull<Int64> 返回 None（新代码不挂载）。
    @TestCase
    public func testRefToIncludeNullTargetIdDefaultMapperNoCrash(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
            MapperMockColumnInfo("author.id", false),
            MapperMockColumnInfo("author.name", false),
            MapperMockColumnInfo("author.email", false),
        ]
        // author.* 全为 NULL（sqlNull 模拟驱动 NULL，非 Int64 → get<Int64> 抛、getOrNull<Int64> → None）
        let row = Array<Any>(7, {i =>
            if (i == 0) { 5 } else if (i == 1) { "orphan" } else if (i == 2) { 99 } else if (i == 3) { 0 }
            else { sqlNull() }
        })
        conn.stmt.queryResult = MapperMockQueryResult(cols, [row])
        let q = PostWithRel.query().include(PostWithRelRel.author).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].author.isNone(), true)
    }

    @TestCase
    public func testHasOneIncludeNullTargetIdDefaultMapperNoCrash(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("profile.id", false),
            MapperMockColumnInfo("profile.bio", false),
            MapperMockColumnInfo("profile.user_id", false),
        ]
        // profile.* 全为 NULL（has_one 无匹配：LEFT JOIN 目标侧全 NULL）
        let row = Array<Any>(5, {i =>
            if (i == 0) { 7 } else if (i == 1) { "nobody" }
            else { sqlNull() }
        })
        conn.stmt.queryResult = MapperMockQueryResult(cols, [row])
        let q = UserWithRel.query().include(UserWithRelRel.profile).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 7)
        @Expect(entities[0].profile.isNone(), true)
    }

    @TestCase
    public func testRefToStringPkIncludeNullTargetIdDefaultMapperNoCrash(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
            MapperMockColumnInfo("post.id", false),
            MapperMockColumnInfo("post.title", false),
            MapperMockColumnInfo("post.content", false),
        ]
        // String-pk 目标（UuidPost）：post.id 为 NULL，getOrNull<String> → None
        let row = Array<Any>(6, {i =>
            if (i == 0) { 5 } else if (i == 1) { "orphan" } else if (i == 2) { "nope" }
            else { sqlNull() }
        })
        conn.stmt.queryResult = MapperMockQueryResult(cols, [row])
        let q = UuidRefComment.query().include(UuidRefCommentRel.post).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].post.isNone(), true)
    }
}

// ─── I12: aggregateWithCollections 必须保持行序（SQL 行序反映 ORDER BY） ──

@Test
public class C4CollectionIncludeOrderTest {

    private func commentsRel(): IRelation {
        HasMany<UuidComment>("comments", "post_id",
            [Col<Any>("id"), Col<Any>("body")], "uuidComment",
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter)
    }

    @TestCase
    public func testAllWithCollectionIncludePreservesRowOrder(): Unit {
        let conn = CaptureConnection()
        let tx = Tx(conn)
        let cols: Array<SqlColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("comments.id", false),
            MapperMockColumnInfo("comments.body", false),
        ]
        // 行序刻意打乱 id 数值序：去重后返回顺序必须与行序一致（9, 3, 7, 11, 5），
        // 即 SQL 行序（反映 ORDER BY），而不是依赖 HashMap 内部迭代序。
        let rows = [
            Array<Any>(4, {i => if (i == 0) { 9 } else if (i == 1) { "post9" } else if (i == 2) { "c1" } else { "first" }}),
            Array<Any>(4, {i => if (i == 0) { 3 } else if (i == 1) { "post3" } else if (i == 2) { "c2" } else { "second" }}),
            Array<Any>(4, {i => if (i == 0) { 7 } else if (i == 1) { "post7" } else if (i == 2) { "c3" } else { "third" }}),
            Array<Any>(4, {i => if (i == 0) { 11 } else if (i == 1) { "post11" } else if (i == 2) { "c4" } else { "fourth" }}),
            Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post5" } else if (i == 2) { "c5" } else { "fifth" }}),
            Array<Any>(4, {i => if (i == 0) { 9 } else if (i == 1) { "post9" } else if (i == 2) { "c6" } else { "sixth" }}),
        ]
        conn.stmt.queryResult = MapperMockQueryResult(cols, rows)
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
    }
}
