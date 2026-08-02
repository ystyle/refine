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
        let rel = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
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
        let rel: IRelation = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
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
        let rel = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
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

    @TestCase
    public func testHasOne(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let rel = HasOne<Int64>("profile", "user_id", [Col<Any>("id")], "profiles", mapper, setter)
        let (kind, name, table, fk, via, fields) = rel.resolve()
        @Expect(kind, RelationKind.HasOneRel)
        @Expect(name, "profile")
        @Expect(table, "profiles")
        @Expect(fk, "user_id")
        @Expect(via.isNone(), true)
        @Expect(fields.size, 1)
        let tm = rel.getTargetMapper()
        let fs = rel.getFieldSetter()
        @Expect(true, true)
    }

    @TestCase
    public func testHasMany(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let rel = HasMany<String>("posts", "user_id", [Col<Any>("id")], "posts", mapper, setter)
        let (kind, name, _, fk, _, _) = rel.resolve()
        @Expect(kind, RelationKind.HasManyRel)
        @Expect(name, "posts")
        @Expect(fk, "user_id")
        @Expect(true, true)
    }

    @TestCase
    public func testFieldOverrideRelation(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let inner = HasMany<String>("tags", "post_id", [Col<Any>("id")], "tags", mapper, setter)
        let overrides = [Col<Any>("name"), Col<Any>("color")]
        let wrapper = FieldOverrideRelation(inner, overrides)
        let (kind, name, _, fk, _, fields) = wrapper.resolve()
        @Expect(kind, RelationKind.HasManyRel)
        @Expect(fields.size, 2)
        let tm = wrapper.getTargetMapper()
        let fs = wrapper.getFieldSetter()
        @Expect(true, true)
    }

    @TestCase
    public func testWithIncludeAppendsNested(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter)
        let returned = author.withInclude(profile)
        @Expect(author.getNested().size, 0)
        @Expect(author.isBatchSupported(), true)
        @Expect(returned.getNested().size, 1)
    }

    @TestCase
    public func testWithIncludeChaining(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter)
        let tags = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", dummyMapper, dummySetter)
        let chained: IRelation = author.withInclude(profile).withInclude(tags)
        @Expect(author.getNested().size, 0)
        @Expect(chained.getNested().size, 2)
    }

    @TestCase
    public func testNestedEmptyByDefault(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        @Expect(author.getNested().size, 0)
        @Expect(author.isBatchSupported(), true)
    }

    @TestCase
    public func testHasManyInheritsNesting(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let posts = HasMany<String>("posts", "user_id", [Col<Any>("id")], "posts", mapper, setter)
        let author = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let returned = posts.withInclude(author)
        @Expect(posts.getNested().size, 0)
        @Expect(posts.isBatchSupported(), true)
        @Expect(returned.getNested().size, 1)
    }

    @TestCase
    public func testFieldOverrideRelationDelegatesNesting(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let inner = HasMany<String>("tags", "post_id", [Col<Any>("id")], "tags", mapper, setter)
        let wrapper = FieldOverrideRelation(inner, [Col<Any>("name")])
        @Expect(wrapper.isBatchSupported(), true)
        @Expect(wrapper.getNested().size, 0)
        let rel = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let newWrapper = wrapper.withInclude(rel)
        @Expect(wrapper.getNested().size, 0)
        @Expect(inner.getNested().size, 0)
        @Expect(newWrapper.getNested().size, 1)
    }

    @TestCase
    public func testWithIncludeDoesNotMutateSource(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter)
        let _ = author.withInclude(profile)
        @Expect(author.getNested().size, 0)
    }

    @TestCase
    public func testWithIncludeIndependentChains(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter)
        let tags = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", dummyMapper, dummySetter)
        let chainA = author.withInclude(profile)
        let chainB = author.withInclude(tags)
        @Expect(author.getNested().size, 0)
        @Expect(chainA.getNested().size, 1)
        @Expect(chainB.getNested().size, 1)
    }

    @TestCase
    public func testWithIncludeDedup(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter)
        let chain = author.withInclude(profile).withInclude(profile)
        @Expect(chain.getNested().size, 1)
    }

    @TestCase
    public func testClonePreservesExistingNested(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter)
        let tags = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", dummyMapper, dummySetter)
        let chain = author.withInclude(profile).withInclude(tags)
        @Expect(chain.getNested().size, 2)
        let nested = chain.getNested()
        let (k0, n0, _, _, _, _) = nested[0].resolve()
        let (k1, n1, _, _, _, _) = nested[1].resolve()
        @Expect(k0, RelationKind.HasOneRel)
        @Expect(n0, "profile")
        @Expect(k1, RelationKind.HasManyRel)
        @Expect(n1, "tags")
    }

    // ─── Task 3: fk 提取器（ref_to 批量装配的外键值读取） ───

    @TestCase
    public func testRefToExposesFkExtractor(): Unit {
        let extractor: (Any) -> Any = { e: Any => 7 }
        let rel = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, extractor)
        let got = rel.getForeignKeyExtractor()
        match (got("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64 fk value")
        }
    }

    @TestCase
    public func testNonRefToHasNoFkExtractor(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let rel = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", mapper, setter)
        try {
            let _ = rel.getForeignKeyExtractor()
            @Fail("expected RefineException")
        } catch (e: RefineException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testFieldOverrideRelationDelegatesFkExtractor(): Unit {
        let extractor: (Any) -> Any = { e: Any => 7 }
        let inner: IRelation = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, extractor)
        let wrapper = FieldOverrideRelation(inner, [Col<Any>("id")])
        match (wrapper.getForeignKeyExtractor()("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64 fk value")
        }
    }

    @TestCase
    public func testClonePreservesFkExtractor(): Unit {
        let extractor: (Any) -> Any = { e: Any => 7 }
        let author = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, extractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter)
        // withInclude 走 clone-on-write，fkExtractor 必须随克隆保留
        let chain = author.withInclude(profile)
        match (chain.getForeignKeyExtractor()("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64 fk value")
        }
    }
}
