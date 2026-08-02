package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList

struct TestEntity {
    var value: String
    var id: Int64

    public init(value: String, id: Int64) {
        this.value = value
        this.id = id
    }
}

// Mutable container for capturing hook execution order in tests
class OrderBuffer {
    var items = ArrayList<String>()

    public init() {}

    public func add(item: String): Unit {
        items.add(item)
    }
}

@Test
public class HookTest {
    @TestCase
    public func testHookExecutionOrder(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let order = OrderBuffer()

        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            order.add("first")
        }
        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            order.add("second")
        }
        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            order.add("third")
        }

        let entity = TestEntity("hello", 1)
        let scope = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxBeforeCreate, scope)

        @Expect(order.items.size, 3)
        @Expect(order.items[0], "first")
        @Expect(order.items[1], "second")
        @Expect(order.items[2], "third")
    }

    @TestCase
    public func testAbortStopsSubsequentHooks(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let executed = OrderBuffer()

        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            executed.add("first")
        }
        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            executed.add("second")
            scope.abort(Exception("stop"))
        }
        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            executed.add("third")
        }

        let entity = TestEntity("test", 2)
        let scope = Scope<TestEntity>(entity)
        let err = rf.executeHooks("TestEntity", HookKind.TxBeforeCreate, scope)

        @Expect(executed.items.size, 2)
        @Expect(executed.items[0], "first")
        @Expect(executed.items[1], "second")
        @Expect(scope.aborted, true)
        @Expect(err.isSome(), true)
    }

    @TestCase
    public func testNoHooksIsNoop(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let entity = TestEntity("noop", 3)
        let scope = Scope<TestEntity>(entity)
        let err = rf.executeHooks("TestEntity", HookKind.AfterFind, scope)
        let noError = match (err) {
            case None => true
            case _ => false
        }

        @Expect(scope.aborted, false)
        @Expect(noError, true)
    }

    @TestCase
    public func testDifferentKindsDoNotInterfere(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let beforeCalls = OrderBuffer()
        let afterCalls = OrderBuffer()

        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            beforeCalls.add("before")
        }
        rf.hook<TestEntity>("TestEntity", HookKind.TxAfterCreate) { scope: Scope<TestEntity> =>
            afterCalls.add("after")
        }

        let entity = TestEntity("x", 4)
        let scope1 = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxBeforeCreate, scope1)

        let scope2 = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxAfterCreate, scope2)

        @Expect(beforeCalls.items.size, 1)
        @Expect(afterCalls.items.size, 1)
        @Expect(beforeCalls.items[0], "before")
        @Expect(afterCalls.items[0], "after")
    }

    // I14: 钩子注册表已彻底实例级 —— 不同 Refine 实例的注册互不可见
    @TestCase
    public func testInstanceIsolation(): Unit {
        let rf1 = Refine(RMockDS(), SQLiteDialect(), 0)
        let rf2 = Refine(RMockDS(), SQLiteDialect(), 0)
        let called = OrderBuffer()

        rf1.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            called.add("rf1")
        }

        let entity = TestEntity("iso", 9)
        let scope2 = Scope<TestEntity>(entity)
        let err2 = rf2.executeHooks("TestEntity", HookKind.TxBeforeCreate, scope2)

        @Expect(called.items.size, 0)
        @Expect(err2.isNone(), true)
    }

    // I14: Refine.clearHooks() 清空实例级注册表（替代已移除的全局 clearHooks）
    @TestCase
    public func testClearHooks(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let called = OrderBuffer()

        rf.hook<TestEntity>("TestEntity", HookKind.TxAfterUpdate) { scope: Scope<TestEntity> =>
            called.add("fired")
        }
        rf.clearHooks()

        let entity = TestEntity("clear", 10)
        let scope = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxAfterUpdate, scope)

        @Expect(called.items.size, 0)
    }

    @TestCase
    public func testTxBeforeDeleteAndAfterDelete(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let before = OrderBuffer()
        let after = OrderBuffer()

        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeDelete) { scope: Scope<TestEntity> =>
            before.add("before")
        }
        rf.hook<TestEntity>("TestEntity", HookKind.TxAfterDelete) { scope: Scope<TestEntity> =>
            after.add("after")
        }

        let entity = TestEntity("z", 7)
        let scope1 = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxBeforeDelete, scope1)

        let scope2 = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxAfterDelete, scope2)

        @Expect(before.items.size, 1)
        @Expect(after.items.size, 1)
    }

    @TestCase
    public func testTxBeforeAndAfterCreateOrder(): Unit {
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let order = OrderBuffer()

        rf.hook<TestEntity>("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            order.add("before")
        }
        rf.hook<TestEntity>("TestEntity", HookKind.TxAfterCreate) { scope: Scope<TestEntity> =>
            order.add("after")
        }

        let entity = TestEntity("w", 8)
        let beforeScope = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxBeforeCreate, beforeScope)

        let afterScope = Scope<TestEntity>(entity)
        rf.executeHooks("TestEntity", HookKind.TxAfterCreate, afterScope)

        @Expect(order.items.size, 2)
        @Expect(order.items[0], "before")
        @Expect(order.items[1], "after")
    }
}
