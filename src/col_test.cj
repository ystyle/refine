package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ColTest {
    @TestCase
    public func testColEqInt(): Unit {
        let col = Col<Int64>("age")
        let expr = col == 42
        match (expr) {
            case Expr.Binary(left, op, right) =>
                @Expect(op, BinOp.Eq)
                match (left) {
                    case Expr.Column(n) => @Expect(n, "age")
                    case _ => @Fail("expected left Column")
                }
                match (right) {
                    case Expr.Value(v) => match (v) {
                        case i: Int64 => @Expect(i, 42)
                        case _ => @Fail("expected Int64")
                    }
                    case _ => @Fail("expected Value")
                }
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColNeInt(): Unit {
        let col = Col<Int64>("age")
        let expr = col != 42
        match (expr) {
            case Expr.Binary(left, op, _) =>
                @Expect(op, BinOp.Ne)
                match (left) {
                    case Expr.Column(n) => @Expect(n, "age")
                    case _ => @Fail("expected Column")
                }
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColGtInt(): Unit {
        let col = Col<Int64>("age")
        let expr = col > 18
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.Gt)
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColLtInt(): Unit {
        let col = Col<Int64>("age")
        let expr = col < 65
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.Lt)
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColGeInt(): Unit {
        let col = Col<Int64>("age")
        let expr = col >= 18
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.Ge)
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColLeInt(): Unit {
        let col = Col<Int64>("age")
        let expr = col <= 65
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.Le)
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColLike(): Unit {
        let col = Col<String>("name")
        let expr = col.like("%hello%")
        match (expr) {
            case Expr.FuncCall(fn, args) =>
                @Expect(fn, "LIKE")
                match (args[0]) {
                    case Expr.Column(n) => @Expect(n, "name")
                    case _ => @Fail("expected Column in args[0]")
                }
            case _ => @Fail("expected FuncCall")
        }
    }

    @TestCase
    public func testColIsTrue(): Unit {
        let col = Col<Bool>("active")
        let expr = col.isTrue()
        match (expr) {
            case Expr.Unary(op, _) => @Expect(op, UnaryOp.IsNotNull)
            case _ => @Fail("expected Unary")
        }
    }

    @TestCase
    public func testColIsFalse(): Unit {
        let col = Col<Bool>("active")
        let expr = col.isFalse()
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.Eq)
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColAsc(): Unit {
        let col = Col<Int64>("id")
        let expr = col.asc()
        match (expr) {
            case Expr.FuncCall(fn, args) =>
                @Expect(fn, "ASC")
                match (args[0]) {
                    case Expr.Column(n) => @Expect(n, "id")
                    case _ => @Fail("expected Column")
                }
            case _ => @Fail("expected FuncCall")
        }
    }

    @TestCase
    public func testColDesc(): Unit {
        let col = Col<Int64>("id")
        let expr = col.desc()
        match (expr) {
            case Expr.FuncCall(fn, args) =>
                @Expect(fn, "DESC")
                match (args[0]) {
                    case Expr.Column(n) => @Expect(n, "id")
                    case _ => @Fail("expected Column")
                }
            case _ => @Fail("expected FuncCall")
        }
    }

    @TestCase
    public func testColIn(): Unit {
        let col = Col<Int64>("id")
        let expr = col.`in`([1, 2, 3])
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.In)
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColNotIn(): Unit {
        let col = Col<Int64>("id")
        let expr = col.notIn([1, 2, 3])
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.NotIn)
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColEqCol(): Unit {
        let colA = Col<Int64>("a")
        let colB = Col<Int64>("b")
        let expr = colA == colB
        match (expr) {
            case Expr.Binary(left, op, right) =>
                @Expect(op, BinOp.Eq)
                match (left) {
                    case Expr.Column(n) => @Expect(n, "a")
                    case _ => @Fail("expected left Column")
                }
                match (right) {
                    case Expr.Column(n) => @Expect(n, "b")
                    case _ => @Fail("expected right Column")
                }
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testColNeCol(): Unit {
        let colA = Col<Int64>("a")
        let colB = Col<Int64>("b")
        let expr = colA != colB
        match (expr) {
            case Expr.Binary(_, op, _) => @Expect(op, BinOp.Ne)
            case _ => @Fail("expected Binary")
        }
    }
}
