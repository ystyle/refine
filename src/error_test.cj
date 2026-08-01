package refine

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class RefineExceptionTest {
    @TestCase
    public func testCreateRefineException(): Unit {
        let e = RefineException("general error")
        @Expect(e.message, "general error")
    }

    @TestCase
    public func testCreateConnectionException(): Unit {
        let e = ConnectionException("connection failed")
        @Expect(e.message, "connection failed")
    }

    @TestCase
    public func testCreateQueryException(): Unit {
        let e = QueryException("invalid query")
        @Expect(e.message, "invalid query")
    }

    @TestCase
    public func testCreateMappingException(): Unit {
        let e = MappingException("mapping failed")
        @Expect(e.message, "mapping failed")
    }

    @TestCase
    public func testCreateMigrationException(): Unit {
        let e = MigrationException("migration failed")
        @Expect(e.message, "migration failed")
    }

    @TestCase
    public func testCreateConfigException(): Unit {
        let e = ConfigException("invalid config")
        @Expect(e.message, "invalid config")
    }

    @TestCase
    public func testCreateHookException(): Unit {
        let e = HookException("hook failed")
        @Expect(e.message, "hook failed")
    }

    @TestCase
    public func testCatchAllAsRefineException(): Unit {
        let exceptions = ArrayList<RefineException>()
        exceptions.add(ConnectionException("conn"))
        exceptions.add(QueryException("query"))
        exceptions.add(MappingException("mapping"))
        exceptions.add(MigrationException("migration"))
        exceptions.add(ConfigException("config"))
        exceptions.add(HookException("hook"))
        for (e in exceptions) {
            let ok = match (e.message) {
                case "conn" => true
                case "query" => true
                case "mapping" => true
                case "migration" => true
                case "config" => true
                case "hook" => true
                case _ => false
            }
            if (!ok) {
                @Fail("unexpected exception message: " + e.message)
            }
        }
    }

    @TestCase
    public func testSpecificCatchConnectionException(): Unit {
        let e: RefineException = ConnectionException("db down")
        let result = match (e) {
            case connErr: ConnectionException => connErr.message
            case _ => "wrong type"
        }
        @Expect(result, "db down")
    }

    @TestCase
    public func testSpecificCatchQueryException(): Unit {
        let e: RefineException = QueryException("bad sql")
        let result = match (e) {
            case qErr: QueryException => qErr.message
            case _ => "wrong type"
        }
        @Expect(result, "bad sql")
    }

    @TestCase
    public func testSpecificCatchMappingException(): Unit {
        let e: RefineException = MappingException("no rows")
        let result = match (e) {
            case mErr: MappingException => mErr.message
            case _ => "wrong type"
        }
        @Expect(result, "no rows")
    }

    @TestCase
    public func testSpecificCatchMigrationException(): Unit {
        let e: RefineException = MigrationException("version conflict")
        let result = match (e) {
            case mErr: MigrationException => mErr.message
            case _ => "wrong type"
        }
        @Expect(result, "version conflict")
    }

    @TestCase
    public func testSpecificCatchConfigException(): Unit {
        let e: RefineException = ConfigException("bad config")
        let result = match (e) {
            case cErr: ConfigException => cErr.message
            case _ => "wrong type"
        }
        @Expect(result, "bad config")
    }

    @TestCase
    public func testSpecificCatchHookException(): Unit {
        let e: RefineException = HookException("hook failed")
        let result = match (e) {
            case hErr: HookException => hErr.message
            case _ => "wrong type"
        }
        @Expect(result, "hook failed")
    }

    @TestCase
    public func testSubtypeNotMatchOtherType(): Unit {
        let e: RefineException = QueryException("query error")
        let result = match (e) {
            case ce: ConnectionException => "connection"
            case qe: QueryException => "query"
            case _ => "unknown"
        }
        @Expect(result, "query")
    }

    @TestCase
    public func testTryCatchRefineException(): Unit {
        try {
            throw ConnectionException("timeout")
        } catch (e: RefineException) {
            @Expect(e.message, "timeout")
        }
    }

    @TestCase
    public func testTryCatchSpecificException(): Unit {
        try {
            throw QueryException("syntax error")
        } catch (e: QueryException) {
            @Expect(e.message, "syntax error")
        }
    }

    @TestCase
    public func testChainOfInheritance(): Unit {
        let e: Exception = ConnectionException("chain test")
        @Expect(e.message, "chain test")
    }

    @TestCase
    public func testCreateOptimisticLockException(): Unit {
        let e = OptimisticLockException("User", 42, 3, 5)
        @Expect(e.entityType, "User")
        @Expect(e.pk, "42")
        @Expect(e.expected, 3)
        @Expect(e.actual, 5)
        @Expect(e.message, "optimistic lock conflict on User pk=42 expected version 3 got 5")
    }

    @TestCase
    public func testCreateOptimisticLockExceptionStringPk(): Unit {
        let e = OptimisticLockException("Event", "abc-123", 7, 8)
        @Expect(e.entityType, "Event")
        @Expect(e.pk, "abc-123")
        @Expect(e.message.contains("abc-123"), true)
        @Expect(e.message, "optimistic lock conflict on Event pk=abc-123 expected version 7 got 8")
    }

    @TestCase
    public func testCatchOptimisticLockExceptionAsRefineException(): Unit {
        try {
            throw OptimisticLockException("User", 42, 3, 5)
        } catch (e: RefineException) {
            @Expect(e.message.contains("optimistic lock conflict"), true)
        }
    }
}
