package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ExprTest {
    @TestCase
    public func testColumnConstruction(): Unit {
        let col = Expr.Column("name")
        match (col) {
            case Expr.Column(n) => @Expect(n, "name")
            case _ => @Fail("expected Column variant")
        }
    }

    @TestCase
    public func testValueConstructionInt(): Unit {
        let val = Expr.Value(42)
        match (val) {
            case Expr.Value(v) => match (v) {
                case i: Int64 => @Expect(i, 42)
                case _ => @Fail("expected Int64")
            }
            case _ => @Fail("expected Value variant")
        }
    }

    @TestCase
    public func testValueConstructionString(): Unit {
        let val = Expr.Value("hello")
        match (val) {
            case Expr.Value(v) => match (v) {
                case s: String => @Expect(s, "hello")
                case _ => @Fail("expected String")
            }
            case _ => @Fail("expected Value variant")
        }
    }

    @TestCase
    public func testBinaryConstruction(): Unit {
        let left = Expr.Column("a")
        let right = Expr.Column("b")
        let expr = Expr.Binary(left, BinOp.Eq, right)
        match (expr) {
            case Expr.Binary(l, op, r) =>
                @Expect(op, BinOp.Eq)
                match (l) {
                    case Expr.Column(n) => @Expect(n, "a")
                    case _ => @Fail("expected left Column")
                }
                match (r) {
                    case Expr.Column(n) => @Expect(n, "b")
                    case _ => @Fail("expected right Column")
                }
            case _ => @Fail("expected Binary variant")
        }
    }

    @TestCase
    public func testBinOpValues(): Unit {
        @Expect(BinOp.Eq, BinOp.Eq)
        @Expect(BinOp.Ne, BinOp.Ne)
        @Expect(BinOp.Gt, BinOp.Gt)
        @Expect(BinOp.Ge, BinOp.Ge)
        @Expect(BinOp.Lt, BinOp.Lt)
        @Expect(BinOp.Le, BinOp.Le)
        @Expect(BinOp.And, BinOp.And)
        @Expect(BinOp.Or, BinOp.Or)
        @Expect(BinOp.Like, BinOp.Like)
        @Expect(BinOp.In, BinOp.In)
        @Expect(BinOp.NotIn, BinOp.NotIn)
        @Expect(BinOp.Between, BinOp.Between)
        @Expect(BinOp.Add, BinOp.Add)
        @Expect(BinOp.Sub, BinOp.Sub)
        @Expect(BinOp.Mul, BinOp.Mul)
        @Expect(BinOp.Div, BinOp.Div)
        @Expect(BinOp.Mod, BinOp.Mod)
    }

    @TestCase
    public func testUnaryOpValues(): Unit {
        @Expect(UnaryOp.Not, UnaryOp.Not)
        @Expect(UnaryOp.IsNull, UnaryOp.IsNull)
        @Expect(UnaryOp.IsNotNull, UnaryOp.IsNotNull)
    }

    @TestCase
    public func testAndExtensionMethod(): Unit {
        let a = Expr.Column("a")
        let b = Expr.Column("b")
        let expr = a.and(b)
        match (expr) {
            case Expr.Binary(l, op, r) =>
                @Expect(op, BinOp.And)
                match (l) {
                    case Expr.Column(n) => @Expect(n, "a")
                    case _ => @Fail("expected left Column")
                }
                match (r) {
                    case Expr.Column(n) => @Expect(n, "b")
                    case _ => @Fail("expected right Column")
                }
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testOrExtensionMethod(): Unit {
        let a = Expr.Column("a")
        let b = Expr.Column("b")
        let expr = a.or(b)
        match (expr) {
            case Expr.Binary(l, op, r) =>
                @Expect(op, BinOp.Or)
                match (l) {
                    case Expr.Column(n) => @Expect(n, "a")
                    case _ => @Fail("expected left Column")
                }
                match (r) {
                    case Expr.Column(n) => @Expect(n, "b")
                    case _ => @Fail("expected right Column")
                }
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testNotExtensionMethod(): Unit {
        let a = Expr.Column("a")
        let expr = a.not()
        match (expr) {
            case Expr.Unary(op, inner) =>
                @Expect(op, UnaryOp.Not)
                match (inner) {
                    case Expr.Column(n) => @Expect(n, "a")
                    case _ => @Fail("expected Column")
                }
            case _ => @Fail("expected Unary")
        }
    }

    @TestCase
    public func testChainedAndOr(): Unit {
        let a = Expr.Column("a")
        let b = Expr.Column("b")
        let c = Expr.Column("c")
        let expr = a.and(b).or(c)
        match (expr) {
            case Expr.Binary(left, op, right) =>
                @Expect(op, BinOp.Or)
                match (left) {
                    case Expr.Binary(l, innerOp, r) => @Expect(innerOp, BinOp.And)
                    case _ => @Fail("expected left Binary")
                }
                match (right) {
                    case Expr.Column(n) => @Expect(n, "c")
                    case _ => @Fail("expected right Column")
                }
            case _ => @Fail("expected Binary")
        }
    }

    @TestCase
    public func testRangeConstruction(): Unit {
        let expr = Expr.Range(Expr.Column("age"), Expr.Value(18), Expr.Value(65))
        match (expr) {
            case Expr.Range(subject, low, high) =>
                match (subject) {
                    case Expr.Column(n) => @Expect(n, "age")
                    case _ => @Fail("expected Column")
                }
                match (low) {
                    case Expr.Value(v) => match (v) {
                        case i: Int64 => @Expect(i, 18)
                        case _ => @Fail("expected Int64")
                    }
                    case _ => @Fail("expected Value")
                }
                match (high) {
                    case Expr.Value(v) => match (v) {
                        case i: Int64 => @Expect(i, 65)
                        case _ => @Fail("expected Int64")
                    }
                    case _ => @Fail("expected Value")
                }
            case _ => @Fail("expected Range")
        }
    }
}
