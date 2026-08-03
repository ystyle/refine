package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.HashMap
import std.database.sql.QueryResult

class RelUser {}
class RelTag {}

// F3(c): 关系 getter 返回的 setter 闭包是否被真实调用的探针（替代 @Expect(true, true) 空占位）
class SetterProbe {
    var called: Bool = false
    public init() {}
}

@Test
public class RelationTest {
    @TestCase
    public func testRefToConstruction(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
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
        let rel = RefMany<RelTag>("tags", "post_tags", fields, "reltag", dummyMapper, dummySetter, "reltag_id", dummyTargetIdExtractor)
        @Expect(rel.name, "tags")
        @Expect(rel.kind, RelationKind.RefManyRel)
        match (rel.via) {
            case Some(v) => @Expect(v, "post_tags")
            case _ => @Fail("expected Some")
        }
        // Task 5: 中间表目标列名随 RefMany 构造传入
        @Expect(rel.getJunctionTargetCol(), "reltag_id")
    }

    @TestCase
    public func testIRelationResolveRefTo(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let rel: IRelation = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
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
        let rel: IRelation = RefMany<RelTag>("tags", "post_tags", fields, "reltag", dummyMapper, dummySetter, "reltag_id", dummyTargetIdExtractor)
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
        let rel = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
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
        let probe = SetterProbe()
        let setter: (Any, Any) -> Unit = { e, t => probe.called = true }
        let rel = HasOne<Int64>("profile", "user_id", [Col<Any>("id")], "profiles", mapper, setter, dummyTargetIdExtractor)
        let (kind, name, table, fk, via, fields) = rel.resolve()
        @Expect(kind, RelationKind.HasOneRel)
        @Expect(name, "profile")
        @Expect(table, "profiles")
        @Expect(fk, "user_id")
        @Expect(via.isNone(), true)
        @Expect(fields.size, 1)
        // getTargetMapper/getFieldSetter 返回的闭包必须可用（行为断言，非引用相等）
        rel.getFieldSetter()(1, 2)
        @Expect(probe.called, true)
        match (rel.getTargetMapper()(RowQueryResult(1), HashMap<String, Int64>())) {
            case v: Int64 => @Expect(v, 1)
            case _ => @Fail("expected Int64 mapper result")
        }
    }

    @TestCase
    public func testHasMany(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let probe = SetterProbe()
        let setter: (Any, Any) -> Unit = { e, t => probe.called = true }
        let rel = HasMany<String>("posts", "user_id", [Col<Any>("id")], "posts", mapper, setter, dummyTargetIdExtractor)
        let (kind, name, _, fk, _, _) = rel.resolve()
        @Expect(kind, RelationKind.HasManyRel)
        @Expect(name, "posts")
        @Expect(fk, "user_id")
        rel.getFieldSetter()(1, 2)
        @Expect(probe.called, true)
        match (rel.getTargetMapper()(RowQueryResult(1), HashMap<String, Int64>())) {
            case v: Int64 => @Expect(v, 1)
            case _ => @Fail("expected Int64 mapper result")
        }
    }

    @TestCase
    public func testFieldOverrideRelation(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let probe = SetterProbe()
        let setter: (Any, Any) -> Unit = { e, t => probe.called = true }
        let inner = HasMany<String>("tags", "post_id", [Col<Any>("id")], "tags", mapper, setter, dummyTargetIdExtractor)
        let overrides = [Col<Any>("name"), Col<Any>("color")]
        let wrapper = FieldOverrideRelation(inner, overrides)
        let (kind, name, _, fk, _, fields) = wrapper.resolve()
        @Expect(kind, RelationKind.HasManyRel)
        @Expect(fields.size, 2)
        // FieldOverrideRelation 必须透传目标 mapper/setter（行为断言）
        wrapper.getFieldSetter()(1, 2)
        @Expect(probe.called, true)
        match (wrapper.getTargetMapper()(RowQueryResult(1), HashMap<String, Int64>())) {
            case v: Int64 => @Expect(v, 1)
            case _ => @Fail("expected Int64 mapper result")
        }
    }

    @TestCase
    public func testWithIncludeAppendsNested(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let returned = author.withInclude(profile)
        @Expect(author.getNested().size, 0)
        @Expect(author.isBatchSupported(), true)
        @Expect(returned.getNested().size, 1)
    }

    @TestCase
    public func testWithIncludeChaining(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let tags = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let chained: IRelation = author.withInclude(profile).withInclude(tags)
        @Expect(author.getNested().size, 0)
        @Expect(chained.getNested().size, 2)
    }

    @TestCase
    public func testNestedEmptyByDefault(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        @Expect(author.getNested().size, 0)
        @Expect(author.isBatchSupported(), true)
    }

    @TestCase
    public func testHasManyInheritsNesting(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let posts = HasMany<String>("posts", "user_id", [Col<Any>("id")], "posts", mapper, setter, dummyTargetIdExtractor)
        let author = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let returned = posts.withInclude(author)
        @Expect(posts.getNested().size, 0)
        @Expect(posts.isBatchSupported(), true)
        @Expect(returned.getNested().size, 1)
    }

    @TestCase
    public func testFieldOverrideRelationDelegatesNesting(): Unit {
        let mapper: (QueryResult, HashMap<String, Int64>) -> Any = { r, cm => 1 }
        let setter: (Any, Any) -> Unit = { e, t => () }
        let inner = HasMany<String>("tags", "post_id", [Col<Any>("id")], "tags", mapper, setter, dummyTargetIdExtractor)
        let wrapper = FieldOverrideRelation(inner, [Col<Any>("name")])
        @Expect(wrapper.isBatchSupported(), true)
        @Expect(wrapper.getNested().size, 0)
        let rel = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let newWrapper = wrapper.withInclude(rel)
        @Expect(wrapper.getNested().size, 0)
        @Expect(inner.getNested().size, 0)
        @Expect(newWrapper.getNested().size, 1)
    }

    @TestCase
    public func testWithIncludeDoesNotMutateSource(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let _ = author.withInclude(profile)
        @Expect(author.getNested().size, 0)
    }

    @TestCase
    public func testWithIncludeIndependentChains(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let tags = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", dummyMapper, dummySetter, dummyTargetIdExtractor)
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
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let chain = author.withInclude(profile).withInclude(profile)
        @Expect(chain.getNested().size, 1)
    }

    @TestCase
    public func testClonePreservesExistingNested(): Unit {
        let fk = Col<Any>("user_id")
        let fields = [Col<Any>("id"), Col<Any>("name")]
        let author = RefTo<RelUser>("author", fk, fields, "reluser", dummyMapper, dummySetter, dummyFkExtractor, dummyTargetIdExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        let tags = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", dummyMapper, dummySetter, dummyTargetIdExtractor)
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
        let rel = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, extractor, dummyTargetIdExtractor)
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
        let rel = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", mapper, setter, dummyTargetIdExtractor)
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
        let inner: IRelation = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, extractor, dummyTargetIdExtractor)
        let wrapper = FieldOverrideRelation(inner, [Col<Any>("id")])
        match (wrapper.getForeignKeyExtractor()("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64 fk value")
        }
    }

    @TestCase
    public func testClonePreservesFkExtractor(): Unit {
        let extractor: (Any) -> Any = { e: Any => 7 }
        let author = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, extractor, dummyTargetIdExtractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        // withInclude 走 clone-on-write，fkExtractor 必须随克隆保留
        let chain = author.withInclude(profile)
        match (chain.getForeignKeyExtractor()("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64 fk value")
        }
    }

    // ─── Task 6: 目标 id 提取器（嵌套 include 递归装配读取目标实体主键） ───

    @TestCase
    public func testRefToExposesTargetIdExtractor(): Unit {
        let extractor: (Any) -> Any = { t: Any => 42 }
        let rel = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, dummyFkExtractor, extractor)
        match (rel.getTargetIdExtractor()("x")) {
            case v: Int64 => @Expect(v, 42)
            case _ => @Fail("expected Int64 target id value")
        }
    }

    // 所有关系种类都必须携带目标 id 提取器（任意关系的目标实体都可能再声明嵌套 include）
    @TestCase
    public func testAllRelationKindsExposeTargetIdExtractor(): Unit {
        let extractor: (Any) -> Any = { t: Any => 7 }
        let one = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, extractor)
        let many = HasMany<RelTag>("tags", "post_id", [Col<Any>("id")], "reltag", dummyMapper, dummySetter, extractor)
        let manyRef = RefMany<RelTag>("tags2", "post_tags", [Col<Any>("id")], "reltag", dummyMapper, dummySetter, "reltag_id", extractor)
        match (one.getTargetIdExtractor()("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64")
        }
        match (many.getTargetIdExtractor()("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64")
        }
        match (manyRef.getTargetIdExtractor()("x")) {
            case v: Int64 => @Expect(v, 7)
            case _ => @Fail("expected Int64")
        }
    }

    @TestCase
    public func testClonePreservesTargetIdExtractor(): Unit {
        let extractor: (Any) -> Any = { t: Any => 9 }
        let author = RefTo<RelUser>("author", Col<Any>("user_id"), [Col<Any>("id")], "reluser", dummyMapper, dummySetter, dummyFkExtractor, extractor)
        let profile = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, dummyTargetIdExtractor)
        // withInclude 走 clone-on-write，targetIdExtractor 必须随克隆保留
        let chain = author.withInclude(profile)
        match (chain.getTargetIdExtractor()("x")) {
            case v: Int64 => @Expect(v, 9)
            case _ => @Fail("expected Int64 target id value")
        }
    }

    // FieldOverrideRelation（include(rel, fields) 字段子集包装）必须透传目标 id 提取器
    @TestCase
    public func testFieldOverrideRelationDelegatesTargetIdExtractor(): Unit {
        let extractor: (Any) -> Any = { t: Any => 3 }
        let inner: IRelation = HasOne<RelUser>("profile", "user_id", [Col<Any>("id")], "relprofile", dummyMapper, dummySetter, extractor)
        let wrapper = FieldOverrideRelation(inner, [Col<Any>("id")])
        match (wrapper.getTargetIdExtractor()("x")) {
            case v: Int64 => @Expect(v, 3)
            case _ => @Fail("expected Int64 target id value")
        }
    }
}
