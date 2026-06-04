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
        clearHooks()
        let order = OrderBuffer()

        registerHook("TestEntity", HookKind.BeforeCreate) { scope: Scope<TestEntity> =>
            order.add("first")
        }
        registerHook("TestEntity", HookKind.BeforeCreate) { scope: Scope<TestEntity> =>
            order.add("second")
        }
        registerHook("TestEntity", HookKind.BeforeCreate) { scope: Scope<TestEntity> =>
            order.add("third")
        }

        let entity = TestEntity("hello", 1)
        let scope = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.BeforeCreate, scope)

        @Expect(order.items.size, 3)
        @Expect(order.items[0], "first")
        @Expect(order.items[1], "second")
        @Expect(order.items[2], "third")
    }

    @TestCase
    public func testAbortStopsSubsequentHooks(): Unit {
        clearHooks()
        let executed = OrderBuffer()

        registerHook("TestEntity", HookKind.BeforeSave) { scope: Scope<TestEntity> =>
            executed.add("first")
        }
        registerHook("TestEntity", HookKind.BeforeSave) { scope: Scope<TestEntity> =>
            executed.add("second")
            scope.abort(Exception("stop"))
        }
        registerHook("TestEntity", HookKind.BeforeSave) { scope: Scope<TestEntity> =>
            executed.add("third")
        }

        let entity = TestEntity("test", 2)
        let scope = Scope<TestEntity>(entity)
        let err = executeHooks("TestEntity", HookKind.BeforeSave, scope)

        @Expect(executed.items.size, 2)
        @Expect(executed.items[0], "first")
        @Expect(executed.items[1], "second")
        @Expect(scope.aborted, true)
    }

    @TestCase
    public func testNoHooksIsNoop(): Unit {
        clearHooks()
        let entity = TestEntity("noop", 3)
        let scope = Scope<TestEntity>(entity)
        let err = executeHooks("TestEntity", HookKind.AfterFind, scope)
        let noError = match (err) {
            case None => true
            case _ => false
        }

        @Expect(scope.aborted, false)
        @Expect(noError, true)
    }

    @TestCase
    public func testDifferentKindsDoNotInterfere(): Unit {
        clearHooks()
        let beforeCalls = OrderBuffer()
        let afterCalls = OrderBuffer()

        registerHook("TestEntity", HookKind.BeforeCreate) { scope: Scope<TestEntity> =>
            beforeCalls.add("before")
        }
        registerHook("TestEntity", HookKind.AfterCreate) { scope: Scope<TestEntity> =>
            afterCalls.add("after")
        }

        let entity = TestEntity("x", 4)
        let scope1 = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.BeforeCreate, scope1)

        let scope2 = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.AfterCreate, scope2)

        @Expect(beforeCalls.items.size, 1)
        @Expect(afterCalls.items.size, 1)
        @Expect(beforeCalls.items[0], "before")
        @Expect(afterCalls.items[0], "after")
    }

    @TestCase
    public func testTxBeforeCreateSeparateFromBeforeCreate(): Unit {
        clearHooks()
        let txCalled = OrderBuffer()
        let nonTxCalled = OrderBuffer()

        registerHook("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            txCalled.add("tx")
        }
        registerHook("TestEntity", HookKind.BeforeCreate) { scope: Scope<TestEntity> =>
            nonTxCalled.add("non-tx")
        }

        let entity = TestEntity("x", 5)
        // Fire only TxBeforeCreate
        let scope = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.TxBeforeCreate, scope)

        @Expect(txCalled.items.size, 1)
        @Expect(txCalled.items[0], "tx")
        @Expect(nonTxCalled.items.size, 0)
    }

    @TestCase
    public func testTxAfterUpdateSeparateFromAfterUpdate(): Unit {
        clearHooks()
        let txCalled = OrderBuffer()
        let nonTxCalled = OrderBuffer()

        registerHook("TestEntity", HookKind.TxAfterUpdate) { scope: Scope<TestEntity> =>
            txCalled.add("tx")
        }
        registerHook("TestEntity", HookKind.AfterUpdate) { scope: Scope<TestEntity> =>
            nonTxCalled.add("non-tx")
        }

        let entity = TestEntity("y", 6)
        let scope = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.TxAfterUpdate, scope)

        @Expect(txCalled.items.size, 1)
        @Expect(nonTxCalled.items.size, 0)
    }

    @TestCase
    public func testTxBeforeDeleteAndAfterDelete(): Unit {
        clearHooks()
        let before = OrderBuffer()
        let after = OrderBuffer()

        registerHook("TestEntity", HookKind.TxBeforeDelete) { scope: Scope<TestEntity> =>
            before.add("before")
        }
        registerHook("TestEntity", HookKind.TxAfterDelete) { scope: Scope<TestEntity> =>
            after.add("after")
        }

        let entity = TestEntity("z", 7)
        let scope1 = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.TxBeforeDelete, scope1)

        let scope2 = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.TxAfterDelete, scope2)

        @Expect(before.items.size, 1)
        @Expect(after.items.size, 1)
    }

    @TestCase
    public func testTxBeforeAndAfterCreateOrder(): Unit {
        clearHooks()
        let order = OrderBuffer()

        registerHook("TestEntity", HookKind.TxBeforeCreate) { scope: Scope<TestEntity> =>
            order.add("before")
        }
        registerHook("TestEntity", HookKind.TxAfterCreate) { scope: Scope<TestEntity> =>
            order.add("after")
        }

        let entity = TestEntity("w", 8)
        let beforeScope = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.TxBeforeCreate, beforeScope)

        let afterScope = Scope<TestEntity>(entity)
        executeHooks("TestEntity", HookKind.TxAfterCreate, afterScope)

        @Expect(order.items.size, 2)
        @Expect(order.items[0], "before")
        @Expect(order.items[1], "after")
    }
}
