package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.HashMap
import std.database.sql.QueryResult

class RelUser {}
class RelTag {}

@Test
public class RelationTest {
    @TestCase
    public func testRefToConstruction(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter)
        @Expect(rel.name, "author")
        @Expect(rel.kind, RelationKind.RefToRel)
        @Expect(rel.foreignKey, "user_id")
        match (rel.via) {
            case None => ()
            case _ => @Fail("expected None")
        }
    }

    @TestCase
    public func testRefManyConstruction(): Unit {
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel = RefMany<RelTag>("tags", "post_tags", fields, "reltag", dummyMapper, dummySetter)
        @Expect(rel.name, "tags")
        @Expect(rel.kind, RelationKind.RefManyRel)
        match (rel.via) {
            case Some(v) => @Expect(v, "post_tags")
            case _ => @Fail("expected Some")
        }
    }

    @TestCase
    public func testIRelationResolveRefTo(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel: IRelation = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter)
        let (kind, name, targetTable, foreignKey, via, resolvedFields) = rel.resolve()
        @Expect(kind, RelationKind.RefToRel)
        @Expect(name, "author")
        @Expect(foreignKey, "user_id")
        match (via) {
            case None => ()
            case _ => @Fail("expected None")
        }
    }

    @TestCase
    public func testIRelationResolveRefMany(): Unit {
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel: IRelation = RefMany<RelTag>("tags", "post_tags", fields, "reltag", dummyMapper, dummySetter)
        let (kind, name, targetTable, foreignKey, via, resolvedFields) = rel.resolve()
        @Expect(kind, RelationKind.RefManyRel)
        @Expect(name, "tags")
        match (via) {
            case Some(v) => @Expect(v, "post_tags")
            case _ => @Fail("expected Some")
        }
    }

    @TestCase
    public func testRelationFieldsOverride(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter)
        let extra = [Col<Any>("email")]
        rel.setFields(extra)
        @Expect(rel.fields[0].name, "email")
    }

    @TestCase
    public func testRelationKindValues(): Unit {
        @Expect(RelationKind.RefToRel, RelationKind.RefToRel)
        @Expect(RelationKind.RefManyRel, RelationKind.RefManyRel)
        @Expect(RelationKind.HasOneRel, RelationKind.HasOneRel)
        @Expect(RelationKind.HasManyRel, RelationKind.HasManyRel)
    }
}
