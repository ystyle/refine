package refine

import refine.naming.*
import std.unittest.*
import std.unittest.testmacro.*

// Task 2: 命名策略纯函数单测（camelToSnake + applyTableNameStrategy/applyColumnNameStrategy）。
// 实现位于常规包 refine.naming（src/naming/naming.cj）——宏包 refine.macros 在展开期
// import 调用同一份实现，测试直接 import 单测，无运行时副本漂移风险。

@Test
public class CamelToSnakeTest {
    @TestCase
    public func testUserName(): Unit {
        @Expect(camelToSnake("userName"), "user_name")
    }

    @TestCase
    public func testUserID(): Unit {
        @Expect(camelToSnake("userID"), "user_id")
    }

    @TestCase
    public func testHTMLParser(): Unit {
        @Expect(camelToSnake("HTMLParser"), "html_parser")
    }

    @TestCase
    public func testIdempotentSnake(): Unit {
        @Expect(camelToSnake("user_name"), "user_name")
    }

    @TestCase
    public func testSimpleId(): Unit {
        @Expect(camelToSnake("id"), "id")
    }

    @TestCase
    public func testEmptyString(): Unit {
        @Expect(camelToSnake(""), "")
    }

    @TestCase
    public func testLeadingUpper(): Unit {
        @Expect(camelToSnake("UserName"), "user_name")
    }

    @TestCase
    public func testAllCapsSingleWord(): Unit {
        @Expect(camelToSnake("URL"), "url")
    }

    @TestCase
    public func testDigitBeforeUpper(): Unit {
        @Expect(camelToSnake("user2Name"), "user2_name")
    }

    @TestCase
    public func testMultibyteBoundary(): Unit {
        @Expect(camelToSnake("用户Name"), "用户_name")
    }
}

@Test
public class ApplyStrategyTest {
    @TestCase
    public func testTableSnake(): Unit {
        @Expect(applyTableNameStrategy("BlogPost", "snake"), "blog_post")
    }

    @TestCase
    public func testTableNoneLowerFirst(): Unit {
        @Expect(applyTableNameStrategy("BlogPost", "none"), "blogPost")
    }

    @TestCase
    public func testTableSnakeIdempotent(): Unit {
        @Expect(applyTableNameStrategy("blog_post", "snake"), "blog_post")
    }

    @TestCase
    public func testColumnSnake(): Unit {
        @Expect(applyColumnNameStrategy("userName", "snake"), "user_name")
    }

    @TestCase
    public func testColumnNoneUnchanged(): Unit {
        @Expect(applyColumnNameStrategy("userName", "none"), "userName")
    }

    @TestCase
    public func testLowerTableName(): Unit {
        @Expect(lowerTableName("BlogPost"), "blogPost")
    }

    @TestCase
    public func testUpperFirstLetter(): Unit {
        @Expect(upperFirstLetter("userName"), "UserName")
    }

    @TestCase
    public func testLowerTableNameEmpty(): Unit {
        @Expect(lowerTableName(""), "")
    }

    @TestCase
    public func testLowerTableNameMultibyte(): Unit {
        @Expect(lowerTableName("用户"), "用户")
    }

    @TestCase
    public func testUpperFirstLetterEmpty(): Unit {
        @Expect(upperFirstLetter(""), "")
    }

    @TestCase
    public func testUpperFirstLetterMultibyte(): Unit {
        @Expect(upperFirstLetter("用户"), "用户")
    }
}
