package refine

import refine.macros.*
import std.collection.ArrayList
import std.collection.HashMap
import std.collection.HashSet
import std.database.sql.{Connection, Transaction, QueryResult, UpdateResult, ColumnInfo, ConnectionState, SqlDbType}
import std.database.sql.Statement as SqlStatement
import std.time.DateTime
import std.math.numeric.Decimal
import std.unittest.*
import std.unittest.testmacro.*

// Task 1: @Refine[naming: "snake"] 属性宏参数解析——双参重载解析命名策略并展开。
// 命名策略白名单 {"none", "snake"} 之外的值（如 "kebab"/"SNAKE"）与 `naming:` 缺值
// 均在宏展开期抛编译错误（refine_macro.cj 双参宏校验），故本文件不放非法值 fixture
//（放进来整个测试工程编译失败）；合法值行为由下面三组 fixture 覆盖：
//   - @Refine[naming: "snake"]（SnakeBlogPost）——显式 snake
//   - @Refine[naming: "none"]（ExplicitNonePost）——显式 none，等价默认
//   - @Refine[]（EmptyAttrPost）——双参宏空 attr 路径，等价默认
@Refine[naming: "snake"]
public class SnakeBlogPost {
    var id: Int64 = 0
    var userName: String = ""
}

@Refine[naming: "none"]
public class ExplicitNonePost {
    var id: Int64 = 0
    var title: String = ""
}

@Refine[]
public class EmptyAttrPost {
    var id: Int64 = 0
    var title: String = ""
}

@Refine
public class Post {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
}

@Refine
public class User {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""
}

@Refine
public class Tag {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
public class Comment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
public class UuidPost {
    var id: String = ""
    var title: String = ""
    var content: String = ""
}

@Refine
public class ManualIdPost {
    @Id[auto, false]
    var id: Int64 = 0
    var title: String = ""
}

@Refine
public class OrderTag {
    @Id[]
    var order_id: Int64 = 0
    @Id[]
    var tag_id: Int64 = 0
}

@Refine
public class StringKeyEntity {
    @Id[]
    var key: String = ""
    var name: String = ""
}

@Refine
public class CustomAutoPkEntity {
    @Id[auto, true]
    var uid: Int64 = 0
    var label: String = ""
}

@Refine
public class OrderItemTag {
    @Id[]
    var order_id: Int64 = 0
    @Id[]
    var item_id: Int64 = 0
    var quantity: Int64 = 0
}

// 显式 @Table 全小写表名：宏层写路径（INSERT/UPDATE/DELETE）生成未加引号的标识符，
// PG 对未加引号标识符折叠为小写。驼峰表名（默认 PgPost->pgPost）在写路径下无法命中
// 引号原样建出的表，故这些 fixture 固定全小写表名（与写路径折叠结果一致）。
@Refine
@Table["pgpost"]
public class PgPost {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
}

// R-C2 fixture: 窄整数/单精度浮点字段实体——宏层接受这些类型并映射
// StorageType.Integer（BIGINT 列）/ StorageType.Float（DOUBLE 列），但修复前
// dispatchSet 只认 Int32/Int64/Float64，其余落 setNull 静默写 NULL。此实体供
// 真实 PG/MySQL 集成测试验证写路径绑定正确（save 后列值非空且等于字段值）。
@Refine
@Table["narrowfield"]
public class NarrowField {
    var id: Int64 = 0
    var u8: UInt8 = 0
    var u16: UInt16 = 0
    var u32: UInt32 = 0
    var u64: UInt64 = 0
    var i8: Int8 = 0
    var i16: Int16 = 0
    var f32: Float32 = 0.0
}

@Refine
@Table["pgevent"]
public class PgEvent {
    var id: String = ""
    var name: String = ""
    var payload: String = ""
}

// R-I8 fixture: Array<UInt8> 是 Bytes 存储（一等存储类型），不是 ref_many 集合。
// 修复前 detectRelations 把一切 Array<X> 当 ref_many → 生成 RefMany<UInt8> 引用
// 不存在的 UInt8Schema/UInt8Rel → 难懂编译错误，Bytes 实体字段不可达。
@Refine
public class ByteBlobEntity {
    var id: Int64 = 0
    var name: String = ""
    var data: Array<UInt8> = []
}

// I2 回归实体：驼峰表名/列名 + 驼峰关系名，验证 PG 标识符原样保留
@Refine
public class CamelUser {
    var id: Int64 = 0
    var displayName: String = ""
}

@Refine
public class CamelPost {
    var id: Int64 = 0
    var title: String = ""
    var authorId: Int64 = 0
    @Ref[CamelUser, authorId]
    var authorProfile: Option<CamelUser> = None
}

// Task 9: 同表多 ref 合并集成测试 fixture。SameTableRefPost 声明两个 ref_to 指向
// 同一目标表（author 用 author_id、editor 用 editor_id），批量 include 按目标表合并
// 为单条批量查询并分别回填（查询次数在单元层用 mock 断言，此处供真实 MySQL/PG
// 验证两个 ref 均正确装配的数据正确性）。
@Refine
public class SameTableRefUser {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""
}

@Refine
public class SameTableRefPost {
    var id: Int64 = 0
    var title: String = ""
    var author_id: Int64 = 0
    var editor_id: Int64 = 0

    @Ref[SameTableRefUser, author_id]
    var author: Option<SameTableRefUser> = None

    @Ref[SameTableRefUser, editor_id]
    var editor: Option<SameTableRefUser> = None
}

@Refine
public class PostWithRel {
    var id: Int64 = 0
    var title: String = ""
    var user_id: Int64 = 0
    var post_id: Int64 = 0

    @Ref[User, user_id]
    var author: Option<User> = None

    @Ref[Tag, via: post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()
}

@Refine
@Table["custom_tags"]
public class CustomTag {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
@Table["custom_tag_posts"]
public class CustomTagPost {
    var id: Int64 = 0
    var title: String = ""

    @Ref[CustomTag, via: custom_post_tags]
    var tags: ArrayList<CustomTag> = ArrayList<CustomTag>()
}

@Refine
public class UuidTag {
    var id: String = ""
    var name: String = ""
}

@Refine
public class UuidTagPost {
    var id: Int64 = 0
    var title: String = ""

    @Ref[UuidTag, via: uuid_tag_post_tags]
    var tags: ArrayList<UuidTag> = ArrayList<UuidTag>()
}

// Task 5: ref_many String-pk 主实体 fixture（中间表源列按 String 存取，
// 覆盖 assembleRefMany 的 isStringPk 分支）。默认 id String 字段即为主键。
@Refine
public class UuidKeyTagPost {
    var id: String = ""
    var title: String = ""

    @Ref[UuidTag, via: uuid_key_tag_post_tags]
    var tags: ArrayList<UuidTag> = ArrayList<UuidTag>()
}

// I20 fixture：驼峰自增主键列（postId），PG save 的 RETURNING 需把 postId 引号化
//（未引号则折叠为 postid，找不到列）。
@Refine
public class CamelAutoPkPost {
    @Id[auto, true]
    var postId: Int64 = 0
    var title: String = ""
}

// I21 fixture：驼峰 via 中间表名（camelViaPostTags）+ 驼峰源列（camelViaPost_id），
// 验证 junction 写路径 SQL 对 via 表名/列名的运行时引号化。
@Refine
public class CamelViaPost {
    var id: Int64 = 0
    var title: String = ""

    @Ref[Tag, via: camelViaPostTags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

// R-I6 fixture：驼峰表名 + 驼峰 fk 的管理方法（loadX/clearX/setX/removeX）。
// 修复前 refToSQL/hasManyLoadSQL/hasManyClearSQL/hasOneLoadSQL/hasOneRemoveSQL 把
// 表名（TargetSchema().tableName() 未引号）、id、r.by fk 列裸写进 SQL，PG 下驼峰
// 标识符折叠小写无法命中。修复后经 tx.getDialect().quoteIdentifier 运行时引号化。
@Refine
public class CamelComment {
    var id: Int64 = 0
    var body: String = ""
    var camelPostId: Int64 = 0
}

@Refine
public class CamelProfile {
    var id: Int64 = 0
    var bio: String = ""
    var camelPostId: Int64 = 0
}

@Refine
public class CamelPostWithRel {
    var id: Int64 = 0
    var title: String = ""

    @Rel[has_many, CamelComment, camelPostId]
    var comments: ArrayList<CamelComment> = ArrayList<CamelComment>()

    @Rel[has_one, CamelProfile, camelPostId]
    var profile: Option<CamelProfile> = None
}

// F1 fixture：String-pk 源实体 → Int64-pk 目标（Tag）。junction 源列类型跟随源主键
//（String→StorageType.String），目标列跟随目标主键（Tag 为 Int64→Integer），
// 是 String-pk 源 junction 在真实 PG 上可完整读写的最小组合。
@Refine
public class StringKeyPost {
    var id: String = ""
    var title: String = ""

    @Ref[Tag, via: string_key_post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

// F1 回归 fixture：Bool storageOverride 主键的 ref_many 源。junction 源列类型跟随
// 源主键 storageOverride（Bool→StorageType.`Bool`），验证宏层把 Bool 转义为反引号形式
//（与 buildSchemaClass:44-46 一致），修复前生成裸 StorageType.Bool 编译失败。
@Refine
public class BoolPkPost {
    @Id[auto, true]
    @Field[`Bool`]
    var id: Int64 = 0
    var title: String = ""

    @Ref[Tag, via: bool_pk_post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

// F1 回归 fixture：Bool-pk 目标（BoolPkTag，storageOverride `Bool`）的 ref_many。
// junction 目标列类型运行时从目标实体 Schema 读取——应得 StorageType.`Bool`，
// 验证 Bool 关键字在运行时推断路径不被硬编码 Integer 覆盖。
@Refine
public class BoolPkTag {
    @Id[auto, true]
    @Field[`Bool`]
    var id: Int64 = 0
    var name: String = ""
}

@Refine
public class BoolPkTagPost {
    var id: Int64 = 0
    var title: String = ""

    @Ref[BoolPkTag, via: bool_pk_tag_post_tags]
    var tags: ArrayList<BoolPkTag> = ArrayList<BoolPkTag>()
}

@Refine
public class UnderscoreFieldEntity {
    var id: Int64 = 0
    var _note: String = ""

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()
}

@Refine
public class UuidRefComment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: String = ""

    @Ref[UuidPost, post_id]
    var post: Option<UuidPost> = None
}

@Refine
public class UuidPostWithRel {
    var id: Int64 = 0
    var title: String = ""

    @Rel[has_many, UuidComment, post_id]
    var comments: ArrayList<UuidComment> = ArrayList<UuidComment>()
}

@Refine
public class UuidComment {
    var id: String = ""
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
public class UuidKeyComment {
    var id: String = ""
    var body: String = ""
    var post_key: String = ""
}

@Refine
public class ProfileWithRel {
    var id: Int64 = 0
    var bio: String = ""
    var user_id: Int64 = 0
}

@Refine
public class UserWithRel {
    var id: Int64 = 0
    var name: String = ""

    @Rel[has_one, ProfileWithRel, user_id]
    var profile: Option<ProfileWithRel> = None
}

@Refine
public class CategoryWithRel {
    var id: Int64 = 0
    var name: String = ""
    var parent_id: Int64 = 0

    @Rel[has_many, CategoryWithRel, parent_id]
    var children: ArrayList<CategoryWithRel> = ArrayList<CategoryWithRel>()
}

// F2(b): 复合主键实体 fixture（级联删除测试）。主键为 tenant_id + line_no 复合键。
// id 字段保留：has_many 的目标类被宏硬编码读 `.id`（addX/removeX/cascadePostSave/
// 目标 id 提取器），无 id 字段的目标类编译失败（已知限制，见 method_gen.cj:69-71）。
// 级联删除键为 "OrderLineItem:<tenant_id>:<line_no>"（pk 字段，与 id 无关）。
@Refine
public class OrderLineItem {
    @Id[]
    var tenant_id: Int64 = 0
    @Id[]
    var line_no: Int64 = 0
    var sku: String = ""
    var order_id: Int64 = 0
    var id: Int64 = 0
}

@Refine
public class OrderWithRel {
    var id: Int64 = 0
    var note: String = ""

    @Rel[has_many, OrderLineItem, order_id]
    var lines: ArrayList<OrderLineItem> = ArrayList<OrderLineItem>()
}

// Task 6: 嵌套 include 递归装配 fixture 链。
// NestedPost.author (ref_to NestedUser) → NestedUser.profile (has_one NestedProfile)
//                                          NestedUser.comments (has_many NestedComment)
// NestedProfile.skills (has_many NestedSkill) → 三层。
@Refine
public class NestedPost {
    var id: Int64 = 0
    var title: String = ""
    var user_id: Int64 = 0

    @Ref[NestedUser, user_id]
    var author: Option<NestedUser> = None
}

@Refine
public class NestedUser {
    var id: Int64 = 0
    var name: String = ""

    @Rel[has_one, NestedProfile, user_id]
    var profile: Option<NestedProfile> = None

    @Rel[has_many, NestedComment, user_id]
    var comments: ArrayList<NestedComment> = ArrayList<NestedComment>()

    // Task 6 嵌套 ref_many 回归：author（ref_to NestedUser）装配出的 User 实体上声明
    // ref_many tags。junction 源列必须是当前层级表（nestedUser_id）而非顶层表（nestedPost_id）。
    @Ref[NestedTag, via: nestedUser_tags]
    var tags: ArrayList<NestedTag> = ArrayList<NestedTag>()
}

@Refine
public class NestedTag {
    var id: Int64 = 0
    var name: String = ""

    // Task 6 batch-include 回归 fixture：ref_many（NestedUser.tags）目标上的嵌套
    // has_many notes。两个 NestedUser 共享同一 tag 时，assembleRefMany 收集的目标
    // 若不按 target id 去重，递归层会对同一 tag 装配两次（副本实例各跑一次），
    // 再往下一层（NestedTagNote.items）时共享的 note 实例被 setter .add() 追加两次。
    @Rel[has_many, NestedTagNote, tag_id]
    var notes: ArrayList<NestedTagNote> = ArrayList<NestedTagNote>()
}

@Refine
public class NestedTagNote {
    var id: Int64 = 0
    var body: String = ""
    var tag_id: Int64 = 0

    @Rel[has_many, NestedTagItem, note_id]
    var items: ArrayList<NestedTagItem> = ArrayList<NestedTagItem>()
}

@Refine
public class NestedTagItem {
    var id: Int64 = 0
    var name: String = ""
    var note_id: Int64 = 0
}

@Refine
public class NestedProfile {
    var id: Int64 = 0
    var bio: String = ""
    var user_id: Int64 = 0

    @Rel[has_many, NestedSkill, profile_id]
    var skills: ArrayList<NestedSkill> = ArrayList<NestedSkill>()
}

@Refine
public class NestedSkill {
    var id: Int64 = 0
    var name: String = ""
    var profile_id: Int64 = 0
}

@Refine
public class NestedComment {
    var id: Int64 = 0
    var body: String = ""
    var user_id: Int64 = 0
}

// Task 6: 嵌套 ref_to → ref_to fixture 链（NestedCommentPost.author 是 ref_to NestedUserRef，
// NestedUserRef.team 也是 ref_to NestedTeamRef）——覆盖嵌套层 assembleRefTo（在 Array<Any>
// 目标实体上读 fk 批量装配）。
@Refine
public class NestedCommentPost {
    var id: Int64 = 0
    var body: String = ""
    var author_id: Int64 = 0

    @Ref[NestedUserRef, author_id]
    var author: Option<NestedUserRef> = None
}

@Refine
public class NestedUserRef {
    var id: Int64 = 0
    var name: String = ""
    var team_id: Int64 = 0

    @Ref[NestedTeamRef, team_id]
    var team: Option<NestedTeamRef> = None
}

@Refine
public class NestedTeamRef {
    var id: Int64 = 0
    var name: String = ""
}

// R-M10: diamond include 回归 fixture。DiamondPost 声明两个 ref_to 指向同一目标表
// diamondUser（author 用 author_id、editor 用 editor_id），各自带相同的嵌套 has_many
// include（DiamondUser.skills）。author/editor 指向同一个用户时（ref_to identity-map
// 共享同一实例），递归层对共享目标实例只装配一次，skills 不会被 setter .add() 重复
// 追加成两份（修复前对每对 pair 各递归一次）。
@Refine
public class DiamondUser {
    var id: Int64 = 0
    var name: String = ""

    @Rel[has_many, DiamondSkill, user_id]
    var skills: ArrayList<DiamondSkill> = ArrayList<DiamondSkill>()
}

@Refine
public class DiamondSkill {
    var id: Int64 = 0
    var name: String = ""
    var user_id: Int64 = 0
}

@Refine
public class DiamondPost {
    var id: Int64 = 0
    var title: String = ""
    var author_id: Int64 = 0
    var editor_id: Int64 = 0

    @Ref[DiamondUser, author_id]
    var author: Option<DiamondUser> = None

    @Ref[DiamondUser, editor_id]
    var editor: Option<DiamondUser> = None
}

@Refine
public class SoftDeleteParent {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0

    @Rel[has_many, SoftDeleteChild, parent_id]
    var children: ArrayList<SoftDeleteChild> = ArrayList<SoftDeleteChild>()
}

@Refine
public class SoftDeleteChild {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
    var parent_id: Int64 = 0
}

// R-I7: 曾在此处声明 `deleted_at: DateTime` 的软删实体（M9 fixture）。
// 该配置生成的 IS NULL 过滤恒假（INSERT 写入 DateTime.now() 后列永非 NULL），
// 修复后宏层在展开期直接抛编译错误（见 refine_macro.cj R-I7 守卫），因此该 fixture
// 与 DateTimeSoftDeleteTest 一并移除——非 Option DateTime 软删字段不可用（F4 前）。

class HookFlag {
    var called: Bool = false
    public init() {}
}

class TestIdGenerator <: IdGenerator {
    private var counter: Int64 = 0
    public func generate(): String {
        counter = counter + 1
        "uuid-" + counter.toString()
    }
}

class TestInt64IdGenerator <: IdGenerator {
    private var counter: Int64 = 0
    public func generate(): String {
        counter = counter + 1
        counter.toString()
    }
}

class CaptureUpdateResult <: UpdateResult {
    public prop lastInsertId: Int64 { get() { _lastInsertId } }
    public prop rowCount: Int64 { get() { _rowCount } }
    private var _lastInsertId: Int64
    private var _rowCount: Int64
    public init(lastInsertId: Int64, rowCount: Int64) {
        this._lastInsertId = lastInsertId
        this._rowCount = rowCount
    }
}

class CaptureStatement <: SqlStatement {
    public var capturedSql: String = ""
    public var capturedSqlHistory: ArrayList<String> = ArrayList<String>()
    public var capturedParams: Array<Any> = []
    public var mockLastInsertId: Int64 = 0
    public var mockRowCount: Int64 = 0
    public var mockLastInsertIdQueue: ArrayList<Int64> = ArrayList<Int64>()
    public var mockRowCountQueue: ArrayList<Int64> = ArrayList<Int64>()
    public var queryResult: QueryResult = MockQueryResult()
    public var queryResultQueue: ArrayList<QueryResult> = ArrayList<QueryResult>()
    public var capturedSetValues: ArrayList<Any> = ArrayList<Any>()
    // F4: setNull 记录（Option<DateTime> None 绑 NULL 时断言用）。dispatchSet 调
    // setNull 的路径需要可观测，否则无法断言 INSERT None 确实绑了 NULL。
    public var nullSetCount: Int64 = 0

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { _parameterColumnInfos } }
    private var _parameterColumnInfos: Array<ColumnInfo> = []

    public func query(): QueryResult { dequeueQueryResult() }
    public func query(_params: Array<SqlDbType>): QueryResult { dequeueQueryResult() }

    private func dequeueQueryResult(): QueryResult {
        if (queryResultQueue.size > 0) {
            return queryResultQueue.remove(at: 0)
        }
        queryResult
    }

    public func set<T>(index: Int, value: T): Unit {
        capturedSetValues.add(value)
    }
    public func setNull(index: Int): Unit { nullSetCount++ }
    public func setOption(_key: String, value: String): Unit {}
    public func update(): UpdateResult { CaptureUpdateResult(dequeueLastInsertId(), dequeueRowCount()) }
    public func update(_params: Array<SqlDbType>): UpdateResult { CaptureUpdateResult(dequeueLastInsertId(), dequeueRowCount()) }

    private func dequeueLastInsertId(): Int64 {
        if (mockLastInsertIdQueue.size > 0) { return mockLastInsertIdQueue.remove(at: 0) }
        mockLastInsertId
    }

    private func dequeueRowCount(): Int64 {
        if (mockRowCountQueue.size > 0) { return mockRowCountQueue.remove(at: 0) }
        mockRowCount
    }
}

// 故意返回错误的额外参数个数（声明 2 个但 SQL 实际不需要），
// 验证宏层按方言返回的 extraParamCount 生成的守卫断言能在执行前拦截。
// 用 2 而非 1：Post 当前无 updated_at 时宏层追加 0 个额外参数（2 != 0 抛错）；
// 若未来 Post 增加 updated_at，宏层会追加 1 个（2 != 1 仍抛错），
// 而用 1 则会被 1 == 1 放过，测试会静默失效。
class MismatchCountDialect <: Dialect {
    public func name(): String { "mismatch-count" }
    public func render(stmt: Statement): (String, Array<Any>) { ("", []) }
    public func quoteIdentifier(name: String): String { "\"" + name + "\"" }
    public func hasUpsertSupport(): Bool { true }
    public func upsertSQL(table: String, _columns: Array<String>, _conflictColumns: Array<String>, _auditCreateCols: Array<String>, _auditUpdateCols: Array<String>, _versionCol: String): (String, Int64) {
        ("INSERT INTO " + table + " VALUES (?)", 2)
    }
    public func dataTypeOf(st: StorageType): String { "TEXT" }
    public func hasReturningSupport(): Bool { false }
    public func hasJSONSupport(): Bool { false }
    public func hasIsolationSupport(): Bool { false }
    public func migrator(db: DB): Migrator { SQLiteMigrator(db) }
    public func initialize(db: DB): Unit {}
    public func defaultValueOf(st: StorageType): String { "" }
}

// 声明不支持 upsert 的方言，验证宏层能力探测守卫（SQLite 现已支持，需独立 mock 才能覆盖该分支）
class NoUpsertDialect <: Dialect {
    public func name(): String { "no-upsert" }
    public func render(stmt: Statement): (String, Array<Any>) { ("", []) }
    public func quoteIdentifier(name: String): String { "\"" + name + "\"" }
    public func hasUpsertSupport(): Bool { false }
    public func upsertSQL(table: String, _columns: Array<String>, _conflictColumns: Array<String>, _auditCreateCols: Array<String>, _auditUpdateCols: Array<String>, _versionCol: String): (String, Int64) { ("", 0) }
    public func dataTypeOf(st: StorageType): String { "TEXT" }
    public func hasReturningSupport(): Bool { false }
    public func hasJSONSupport(): Bool { false }
    public func hasIsolationSupport(): Bool { false }
    public func migrator(db: DB): Migrator { SQLiteMigrator(db) }
    public func initialize(db: DB): Unit {}
    public func defaultValueOf(st: StorageType): String { "" }
}

class CaptureConnection <: Connection {
    public var stmt: CaptureStatement = CaptureStatement()

    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop state: ConnectionState { get() { ConnectionState.Connected } }
    public func createTransaction(): Transaction { MockTransaction() }
    public func getMetaData(): HashMap<String, String> { HashMap<String, String>() }
    public func prepareStatement(sql: String): SqlStatement {
        stmt.capturedSql = sql
        stmt.capturedSqlHistory.add(sql)
        stmt
    }
}

// 共享测试助手：CaptureConnection + 指定方言 Tx（WritePathDialectQuotingTest 的
// 私有 txWith 语义相同，多个测试类需要时提为顶层函数）。Tx 经 ref 绑定 Refine
// 获取方言（DB 收敛后 Session/Tx 不再直接持有 dialect）。
func makeTestTx(dialect: Dialect): (CaptureConnection, Tx) {
    let conn = CaptureConnection()
    let rf = Refine(MockDatasource(), dialect, 0)
    let tx = Tx(conn, rf, 0)
    tx.begin()
    (conn, tx)
}

class RowQueryResult <: QueryResult {
    private var value: Any
    private var consumed: Bool = false
    public init(value: Any) { this.value = value }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public prop columnInfos: Array<ColumnInfo> { get() { _columnInfos } }
    private var _columnInfos: Array<ColumnInfo> = []
    public func next(): Bool {
        if (!consumed) { consumed = true; return true }
        false
    }
    public func next(_values: Array<SqlDbType>): Bool { false }
    public func get<T>(index: Int): T {
        match (value) { case v: T => v; case _ => throw Exception("type mismatch") }
    }
    public func getOrNull<T>(index: Int): ?T { None }
}

@Test
public class MacroSaveTest {
    @TestCase
    public func testTxSavePost(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p = Post()
        p.title = "Test Title"
        p.content = "Test Content"
        tx.save(p)

        @Expect(conn.stmt.capturedSql, "INSERT INTO \"post\" (\"title\", \"content\") VALUES (?, ?)")
    }

    @TestCase
    public func testTxSaveUser(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let u = User()
        u.name = "Alice"
        u.email = "alice@test.com"
        tx.save(u)

        @Expect(conn.stmt.capturedSql, "INSERT INTO \"user\" (\"name\", \"email\") VALUES (?, ?)")
    }

    @TestCase
    public func testTxUpdatePost(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "Updated Title"
        p.content = "Updated Content"
        tx.update(p)

        @Expect(conn.stmt.capturedSql, "UPDATE \"post\" SET \"title\" = ?, \"content\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testTxDeletePost(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p = Post()
        p.id = 1
        tx.delete(p)

        @Expect(conn.stmt.capturedSql, "DELETE FROM \"post\" WHERE \"id\" = ?")
    }

    @TestCase
    public func testTxSaveFiresTxBeforeCreate(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxBeforeCreate) { scope: Scope<Post> =>
            flag.called = true
            if (scope.db.isSome()) { flag.called = true }
        }

        let p = Post()
        p.title = "Hook Test"
        p.content = "Testing hooks"
        tx.save(p)

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxSaveDoesNotFireAfterFind(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let afterFindFlag = HookFlag()
        rf.hook<Post>("Post", HookKind.AfterFind) { scope: Scope<Post> =>
            afterFindFlag.called = true
        }

        let p = Post()
        p.title = "Kind Separation"
        tx.save(p)

        @Expect(afterFindFlag.called, false)
    }

    // ─── Batch Save Tests ────────────────────────────────

    @TestCase
    public func testTxBatchSavePost(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p1 = Post()
        p1.title = "Title 1"
        p1.content = "Content 1"
        let p2 = Post()
        p2.title = "Title 2"
        p2.content = "Content 2"

        tx.batchSave([p1, p2])

        @Expect(conn.stmt.capturedSql, "INSERT INTO \"post\" (\"title\", \"content\") VALUES (?, ?), (?, ?)")
    }

    @TestCase
    public func testTxBatchSaveUser(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let u1 = User()
        u1.name = "Alice"
        u1.email = "alice@test.com"
        let u2 = User()
        u2.name = "Bob"
        u2.email = "bob@test.com"

        tx.batchSave([u1, u2])

        @Expect(conn.stmt.capturedSql, "INSERT INTO \"user\" (\"name\", \"email\") VALUES (?, ?), (?, ?)")
    }

    @TestCase
    public func testTxBatchSaveFiresTxBeforeCreate(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxBeforeCreate) { scope: Scope<Post> =>
            flag.called = true
        }

        let p1 = Post(); p1.title = "A"
        let p2 = Post(); p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxBatchSaveFiresTxAfterCreate(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxAfterCreate) { scope: Scope<Post> =>
            flag.called = true
        }

        let p1 = Post(); p1.title = "A"
        let p2 = Post(); p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxBatchSaveDoesNotSetAutoIds(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 100
        conn.stmt.mockRowCount = 2
        let tx = sqliteTx(conn)
        tx.begin()

        let p1 = Post(); p1.title = "A"; p1.content = "B"
        let p2 = Post(); p2.title = "C"; p2.content = "D"
        tx.batchSave([p1, p2])

        @Expect(p1.id, 0)
        @Expect(p2.id, 0)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"post\" (\"title\", \"content\") VALUES (?, ?), (?, ?)")
    }

    @TestCase
    public func testTxBatchSaveEmptyEntities(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        tx.batchSave(ArrayList<Post>().toArray())

        @Expect(conn.stmt.capturedSql, "")
    }

    // ─── UUID / String Id Tests ────────────────────────

    @TestCase
    public func testTxSaveUuidPostIncludesIdInInsert(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = UuidPost()
        p.title = "Test"
        p.content = "Content"
        tx.save(p)

        @Expect(p.id != "", true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"uuidPost\" (\"id\", \"title\", \"content\")"), true)
        @Expect(conn.stmt.capturedSql.contains("VALUES (?, ?, ?)"), true)
    }

    @TestCase
    public func testTxSaveUuidPostKeepsCustomId(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = UuidPost()
        p.id = "my-custom-id"
        p.title = "Test"
        p.content = "X"
        tx.save(p)

        @Expect(p.id, "my-custom-id")
    }

    @TestCase
    public func testTxBatchSaveUuidPost(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p1 = UuidPost(); p1.title = "A"; p1.content = "B"
        let p2 = UuidPost(); p2.title = "C"; p2.content = "D"
        tx.batchSave([p1, p2])

        @Expect(p1.id != "", true)
        @Expect(p2.id != "", true)
        @Expect(p1.id != p2.id, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"uuidPost\" (\"id\", \"title\", \"content\") VALUES (?, ?, ?), (?, ?, ?)"), true)
    }

    @TestCase
    public func testTxSaveStringKeyEntityAutoGen(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let e = StringKeyEntity()
        e.name = "abc"
        tx.save(e)

        @Expect(e.key != "", true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"stringKeyEntity\" (\"key\", \"name\")"), true)
    }

    @TestCase
    public func testTxBatchSaveStringKeyEntityAutoGen(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let e1 = StringKeyEntity(); e1.name = "a"
        let e2 = StringKeyEntity(); e2.name = "b"
        tx.batchSave([e1, e2])

        @Expect(e1.key != "", true)
        @Expect(e2.key != "", true)
        @Expect(e1.key != e2.key, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"stringKeyEntity\" (\"key\", \"name\")"), true)
    }

    @TestCase
    public func testTxSaveCustomAutoPkEntity(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let e = CustomAutoPkEntity()
        e.label = "x"
        tx.save(e)

        @Expect(e.uid, 42)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"customAutoPkEntity\" (\"label\")"), true)
    }

    // ─── @Id / Compound Key Tests ──────────────────────

    @TestCase
    public func testTxSaveManualIdPostIncludesId(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p = ManualIdPost()
        p.id = 42
        p.title = "Manual"
        tx.save(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"manualIdPost\" (\"id\", \"title\")"), true)
    }

    @TestCase
    public func testTxSaveManualIntPkAutoGen(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestInt64IdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = ManualIdPost()
        p.title = "AutoGen"
        tx.save(p)

        @Expect(p.id != 0, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"manualIdPost\" (\"id\", \"title\")"), true)
    }

    @TestCase
    public func testTxBatchSaveManualIntPkAutoGen(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestInt64IdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p1 = ManualIdPost(); p1.title = "A"
        let p2 = ManualIdPost(); p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(p1.id != 0, true)
        @Expect(p2.id != 0, true)
        @Expect(p1.id != p2.id, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"manualIdPost\" (\"id\", \"title\")"), true)
    }

    @TestCase
    public func testTxSaveManualIntPkKeepsCustomId(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        rf.setIdGenerator(TestInt64IdGenerator())
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = ManualIdPost()
        p.id = 42
        p.title = "Custom"
        tx.save(p)

        @Expect(p.id, 42)
    }

    @TestCase
    public func testTxUpdateManualIdPost(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p = ManualIdPost()
        p.id = 1
        p.title = "Updated"
        tx.update(p)

        @Expect(conn.stmt.capturedSql.contains("UPDATE \"manualIdPost\" SET"), true)
        @Expect(conn.stmt.capturedSql.contains("WHERE \"id\" = ?"), true)
    }

    @TestCase
    public func testTxDeleteManualIdPost(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p = ManualIdPost()
        p.id = 1
        tx.delete(p)

        @Expect(conn.stmt.capturedSql.contains("DELETE FROM \"manualIdPost\""), true)
        @Expect(conn.stmt.capturedSql.contains("WHERE \"id\" = ?"), true)
    }

    @TestCase
    public func testTxSaveOrderTagCompoundPk(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let ot = OrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        tx.save(ot)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"orderTag\" (\"order_id\", \"tag_id\")"), true)
        @Expect(conn.stmt.capturedSql.contains("VALUES (?, ?)"), true)
    }

    @TestCase
    public func testTxUpdateOrderTagCompoundPk(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let ot = OrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        tx.update(ot)

        @Expect(conn.stmt.capturedSql.contains("WHERE \"order_id\" = ? AND \"tag_id\" = ?"), true)
    }

    @TestCase
    public func testTxDeleteOrderTagCompoundPk(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let ot = OrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        tx.delete(ot)

        @Expect(conn.stmt.capturedSql.contains("WHERE \"order_id\" = ? AND \"tag_id\" = ?"), true)
    }

    // ─── Upsert ──────────────────────────────────────

    @TestCase
    public func testTxUpsertMySQL(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        let tx = Tx(conn, rf, 1)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        tx.upsert(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `post` (`id`, `title`, `content`)"), true)
        @Expect(conn.stmt.capturedSql.contains("ON DUPLICATE KEY UPDATE"), true)
        // R-M19: 引用新行值改用行别名 new.col（VALUES(col) 已废弃）
        @Expect(conn.stmt.capturedSql.contains("`title` = new.`title`"), true)
        @Expect(conn.stmt.capturedSql.contains("VALUES(`title`)"), false)
    }

    @TestCase
    public func testTxUpsertPostgres(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), PostgreSQLDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        tx.upsert(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"post\" (\"id\", \"title\", \"content\")"), true)
        @Expect(conn.stmt.capturedSql.contains("ON CONFLICT (\"id\") DO UPDATE SET"), true)
        @Expect(conn.stmt.capturedSql.contains("\"title\" = EXCLUDED.\"title\""), true)
    }

    @TestCase
    public func testTxUpsertUnsupportedDialect(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), NoUpsertDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "T"
        try {
            tx.upsert(p)
            @Fail("expected unsupported dialect exception")
        } catch (_: Exception) {
            @Expect(conn.stmt.capturedSql, "")
        }
    }

    @TestCase
    public func testTxUpsertExtraParamCountMismatchThrows(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MismatchCountDialect(), 1)
        let tx = Tx(conn, rf, 1)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        try {
            tx.upsert(p)
            @Fail("expected extra param count mismatch exception")
        } catch (e: Exception) {
            @Expect(e.message.contains("extra param count mismatch"), true)
            @Expect(conn.stmt.capturedSql, "")
        }
    }

    @TestCase
    public func testTxUpsertDBPathMySQL(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(MockDatasource(), MySQLDialect(), 1)
        let tx = Tx(conn, rf, 1)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        tx.upsert(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `post` (`id`, `title`, `content`)"), true)
        @Expect(conn.stmt.capturedSql.contains("ON DUPLICATE KEY UPDATE"), true)
    }

    @TestCase
    public func testTxUpsertDBPathPostgres(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(MockDatasource(), PostgreSQLDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        tx.upsert(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"post\" (\"id\", \"title\", \"content\")"), true)
        @Expect(conn.stmt.capturedSql.contains("ON CONFLICT (\"id\") DO UPDATE SET"), true)
    }

    @TestCase
    public func testTxSaveDBPathPostgresReturning(): Unit {
        let conn = CaptureConnection()
        conn.stmt.queryResult = RowQueryResult(7)
        let rf = Refine(MockDatasource(), PostgreSQLDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = PgPost()
        p.title = "T"
        p.content = "C"
        tx.save(p)

        @Expect(conn.stmt.capturedSql.contains("RETURNING"), true)
        @Expect(p.id, 7)
    }

    @TestCase
    public func testTxUpsertDBPathSQLite(): Unit {
        // 本项目无真实 SQLite 驱动，此处用 CaptureConnection（mock）仅验证宏层生成的 upsert SQL
        let conn = CaptureConnection()
        let rf = Refine(MockDatasource(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = Post()
        p.id = 1
        p.title = "T"
        p.content = "C"
        tx.upsert(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"post\" (\"id\", \"title\", \"content\")"), true)
        @Expect(conn.stmt.capturedSql.contains("ON CONFLICT (\"id\") DO UPDATE SET"), true)
    }

    @TestCase
    public func testTxSaveDBPathSQLite(): Unit {
        // 本项目无真实 SQLite 驱动，此处用 CaptureConnection（mock）仅验证宏层生成的 save SQL 与
        // lastInsertId 回填路径（SQLite hasReturningSupport=false，走 execute/lastInsertId）
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 7
        let rf = Refine(MockDatasource(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = Post()
        p.title = "T"
        p.content = "C"
        tx.save(p)

        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"post\" (\"title\", \"content\") VALUES (?, ?)"), true)
        @Expect(p.id, 7)
    }

    // ─── Batch Update ─────────────────────────────────

    @TestCase
    public func testTxBatchUpdatePost(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p1 = Post()
        p1.id = 1
        p1.title = "A"
        p1.content = "X"
        let p2 = Post()
        p2.id = 2
        p2.title = "B"
        p2.content = "Y"
        tx.batchUpdate([p1, p2])

        @Expect(conn.stmt.capturedSql.contains("UPDATE \"post\" SET \"title\" = CASE \"id\" WHEN ? THEN ? WHEN ? THEN ? END, \"content\" = CASE \"id\" WHEN ? THEN ? WHEN ? THEN ? END WHERE \"id\" IN (?, ?)"), true)
    }

    @TestCase
    public func testTxBatchUpdateEmpty(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        tx.batchUpdate(ArrayList<Post>().toArray())

        @Expect(conn.stmt.capturedSql, "")
    }

    @TestCase
    public func testTxBatchUpdateFiresHooks(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxBeforeUpdate) { scope: Scope<Post> =>
            flag.called = true
        }

        let p1 = Post(); p1.id = 1; p1.title = "A"
        let p2 = Post(); p2.id = 2; p2.title = "B"
        tx.batchUpdate([p1, p2])

        @Expect(flag.called, true)
    }

    @TestCase
    public func testTxBatchUpdateCompoundPk(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let ot1 = OrderItemTag()
        ot1.order_id = 1
        ot1.item_id = 2
        ot1.quantity = 5
        let ot2 = OrderItemTag()
        ot2.order_id = 3
        ot2.item_id = 4
        ot2.quantity = 6
        tx.batchUpdate([ot1, ot2])

        @Expect(conn.stmt.capturedSql.contains("UPDATE \"orderItemTag\" SET \"quantity\" = CASE WHEN \"order_id\" = ? AND \"item_id\" = ? THEN ? WHEN \"order_id\" = ? AND \"item_id\" = ? THEN ? END WHERE (\"order_id\", \"item_id\") IN ((?, ?), (?, ?))"), true)
    }

    @TestCase
    public func testTxBatchUpdateNoUpdatableColumns(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let ot1 = OrderTag()
        ot1.order_id = 1
        ot1.tag_id = 2
        try {
            tx.batchUpdate([ot1])
            @Fail("expected no updatable columns exception")
        } catch (_: Exception) {
            @Expect(conn.stmt.capturedSql, "")
        }
    }

    @TestCase
    public func testTxUpsertStringPkAutoGen(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        rf.setIdGenerator(TestIdGenerator())
        let tx = Tx(conn, rf, 1)
        tx.begin()

        let e = UuidPost()
        e.title = "T"
        tx.upsert(e)

        @Expect(e.id != "", true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `uuidPost` (`id`, `title`, `content`)"), true)
    }
}

@Test
public class MacroExistingTest {
    @TestCase
    public func testColsStructs(): Unit {
        let postCols = Post.col()
        println("PostCols: id=${postCols.id.name}, title=${postCols.title.name}, content=${postCols.content.name}")
        @Expect(postCols.title.name, "title")
    }

    @TestCase
    public func testQueries(): Unit {
        let _ = Post.query()
        let _ = User.query()
    }

    @TestCase
    public func testRels(): Unit {
        @Expect(PostWithRelRel.author.name, "author")
        @Expect(PostWithRelRel.tags.name, "tags")
    }

    @TestCase
    public func testHookIntegration(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let flag = HookFlag()
        rf.hook<Post>("Post", HookKind.TxBeforeCreate) { scope: Scope<Post> =>
            flag.called = true
        }

        let p2 = Post()
        p2.title = "Hook Integration"
        p2.content = "Triggered via real persistence path"
        tx.save(p2)

        @Expect(flag.called, true)
    }

    @TestCase
    public func testFindAllThrowsWithoutExecutor(): Unit {
        try {
            let _ = Post.findAll(Post.query())
            @Fail("expected QueryException")
        } catch (e: QueryException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testFindOneThrowsWithoutExecutor(): Unit {
        try {
            let _ = Post.findOne(Post.query())
            @Fail("expected QueryException")
        } catch (e: QueryException) {
            @Expect(true, true)
        }
    }

    @TestCase
    public func testGetAuthorRelation(): Unit {
        let p = PostWithRel()
        let author = p.getAuthor()
        @Expect(author.isNone(), true)
    }

    @TestCase
    public func testGetTagsRelation(): Unit {
        let p = PostWithRel()
        let tags = p.getTags()
        @Expect(tags.size, 0)
    }

    @TestCase
    public func testAliasedRendering(): Unit {
        let dialect = SQLiteDialect()
        let stmt = Statement()
        stmt.addClause(SelectClause([Column("id"), Aliased(Column("name"), "user.name")]))
        stmt.addClause(FromClause("users"))
        let (sql, _) = dialect.render(stmt)
        @Expect(sql, "SELECT \"id\", \"name\" AS \"user.name\" FROM \"users\"")
    }

    // batch include Task 3：ref_to include 走批量 IN 装配（主查询 + 批量查询），
    // 主查询不再生成 LEFT JOIN；批量 SQL 为 `SELECT <列> FROM "user" WHERE "id" IN (?)`。
    @TestCase
    public func testIncludeRefToBatchAssembly(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        // 主查询：postWithRel 自身列（user_id=99）
        let mainCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("user_id", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(4, {i => if (i == 0) { 5 } else if (i == 1) { "post" } else if (i == 2) { 99 } else { 0 }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        // 批量查询：user 表 id IN (99)
        let userCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("email", false),
        ]
        let userRow = Array<Any>(3, {i => if (i == 0) { 99 } else if (i == 1) { "Alice" } else { "a@x.com" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(userCols, [userRow]))
        let entities = PostWithRel.findAll(PostWithRel.query()
            .include(PostWithRelRel.author)
            .using(tx))
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("LEFT JOIN"), false)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("LEFT JOIN"), false)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("FROM \"user\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("IN (?)"), true)
        @Expect(entities.size, 1)
        @Expect(entities[0].author.isSome(), true)
        let author = entities[0].author.getOrThrow()
        @Expect(author.id, 99)
        @Expect(author.name, "Alice")
    }

    @TestCase
    public func testGeneratedSchema(): Unit {
        let schema = UserSchema()
        @Expect(schema.tableName(), "user")
        let cols = schema.columns()
        @Expect(cols.size, 3)
        @Expect(cols[0].name, "id")
        @Expect(cols[0].primaryKey, true)
        @Expect(cols[0].autoIncrement, true)
        @Expect(cols[1].name, "name")
    }

    @TestCase
    public func testStringIdSchemaNoAutoIncrement(): Unit {
        let schema = UuidPostSchema()
        let cols = schema.columns()
        @Expect(cols[0].name, "id")
        @Expect(cols[0].primaryKey, true)
        @Expect(cols[0].autoIncrement, false)
    }

    @TestCase
    public func testStringFieldStorageType(): Unit {
        let schema = UuidPostSchema()
        let cols = schema.columns()
        @Expect(cols[0].storageType, StorageType.String)
        @Expect(cols[1].storageType, StorageType.String)
        @Expect(cols[2].storageType, StorageType.String)
    }

    @TestCase
    public func testJunctionSchemaGenerated(): Unit {
        let js = PostWithRel_TagsJunctionSchema()
        @Expect(js.tableName(), "post_tags")
        let cols = js.columns()
        @Expect(cols.size, 2)
        @Expect(cols[0].name, "postWithRel_id")
        @Expect(cols[1].name, "tag_id")
        @Expect(cols[0].storageType, StorageType.Integer)
    }

    // M24: junction 表 (src_id, tgt_id) 构成复合主键——同一关联对天然唯一，防重复关联行
    @TestCase
    public func testJunctionSchemaColumnsAreCompositePk(): Unit {
        let js = PostWithRel_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols[0].primaryKey, true)
        @Expect(cols[1].primaryKey, true)
    }

    @TestCase
    public func testSchemasReturnsMainAndJunction(): Unit {
        let all = PostWithRel.schemas()
        @Expect(all.size, 2)
        @Expect(all[0].tableName(), "postWithRel")
        @Expect(all[1].tableName(), "post_tags")
    }
}

@Refine
public class Document {
    var id: Int64 = 0
    @Field[Text]
    var title: String = ""
}

@Test
public class FieldAnnotationTest {
    @TestCase
    public func testFieldOverrideSchema(): Unit {
        let schema = DocumentSchema()
        let cols = schema.columns()
        @Expect(cols.size, 2)
        @Expect(cols[1].name, "title")
        @Expect(cols[1].storageType, StorageType.Text)
    }
}

// ─── M22: 未知 struct 类型默认映射 StorageType.Json ─────────────────────────
// design §6.3「struct → StorageType.Json」；M22 修复前 typeNameToStorageType 把
// 未知 struct 一律映射为 Text，与 design 不符。注意：宏层 TypeAdapter 读写接线
// （toStored/fromStored）尚未实现，本项只修正 schema 默认推断（见 audit 备注）。
public struct Profile {
    public var bio: String = ""
    public var avatarUrl: String = ""
    public init() {}
    public init(bio: String, avatarUrl: String) {
        this.bio = bio
        this.avatarUrl = avatarUrl
    }
}

@Refine
public class ProfileDoc {
    var id: Int64 = 0
    var title: String = ""
    var profile: Profile = Profile()
}

@Test
public class UnknownTypeSchemaTest {
    @TestCase
    public func testUnknownStructMapsToJson(): Unit {
        let schema = ProfileDocSchema()
        let cols = schema.columns()
        @Expect(cols.size, 3)
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "title")
        @Expect(cols[2].name, "profile")
        @Expect(cols[2].storageType, StorageType.Json)
    }

    @TestCase
    public func testUnknownStructColumnNamesIncludeStruct(): Unit {
        let cols = ProfileDocColumnNames()
        @Expect(cols.size, 3)
        @Expect(cols[2].name, "profile")
    }
}

// ─── Soft Delete Entity ────────────────────────────────

@Refine
public class SoftUser {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
}

@Refine
@HardDelete
class HardUser {
    var id: Int64 = 0
    var name: String = ""
    @Field[Integer]
    var deleted_at: Int64 = 0
}

// F4 fixture：Option<DateTime> 可空软删字段。软删语义 = 未删行 deleted_at 为 NULL
//（INSERT None 绑 NULL），软删写 DateTime.now() 时间戳（配合 IS NULL 过滤）。
// 修复前 isRelationField 把 Option<DateTime> 当关系字段静默跳过（schema/insert/
// select/mapper 全不识别）且 deletedAtIsDateTime=false（类型字符串带空格）——
// 生成无意义的 `deleted_at = 0` 过滤，字段不可达。
@Refine
public class SoftOptUser {
    var id: Int64 = 0
    var name: String = ""
    var deleted_at: Option<DateTime> = None
}

@Refine
@HardDelete
public class HardOptUser {
    var id: Int64 = 0
    var name: String = ""
    var deleted_at: Option<DateTime> = None
}

@Test
public class SoftDeleteTest {
    @TestCase
    public func testTxDeleteIsUpdateForSoftDelete(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = SoftUser()
        u.id = 1
        u.name = "test"
        tx.delete(u)
        @Expect(conn.stmt.capturedSql.contains("UPDATE"), true)
        @Expect(conn.stmt.capturedSql.contains("deleted_at"), true)
        @Expect(conn.stmt.capturedSql.contains("softUser"), true)
    }

    @TestCase
    public func testTxPhysicalDeleteIsDeleteForSoftDelete(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = SoftUser()
        u.id = 1
        u.name = "test"
        tx.physicalDelete(u)
        @Expect(conn.stmt.capturedSql.contains("DELETE"), true)
        @Expect(conn.stmt.capturedSql.contains("softUser"), true)
    }

    @TestCase
    public func testTxDeleteIsDeleteForHardDeleted(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = HardUser()
        u.id = 1
        u.name = "test"
        tx.delete(u)
        @Expect(conn.stmt.capturedSql.contains("DELETE"), true)
        @Expect(conn.stmt.capturedSql.contains("hardUser"), true)
    }

    @TestCase
    public func testSoftDeleteQueryAddsFilter(): Unit {
        let q = SoftUser.query()
        var hasDeletedAtFilter = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.WhereClause(predicates) =>
                    for (p in predicates) {
                        match (p) {
                            case Expr.Binary(Expr.Column(name), _, _) =>
                                if (name == "deleted_at") { hasDeletedAtFilter = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(hasDeletedAtFilter, true)
    }

    @TestCase
    public func testHardDeleteQueryNoFilter(): Unit {
        let q = HardUser.query()
        var hasDeletedAtFilter = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.WhereClause(predicates) =>
                    for (p in predicates) {
                        match (p) {
                            case Expr.Binary(Expr.Column(name), _, _) =>
                                if (name == "deleted_at") { hasDeletedAtFilter = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(hasDeletedAtFilter, false)
    }
}

// R-I7: DateTime 版 deleted_at 的软删除行为测试已移除——非 Option DateTime 软删字段
// 现在由宏层展开期守卫直接抛编译错误（恒假 IS NULL 过滤已不可能生成，见
// refine_macro.cj R-I7 守卫 + docs/audit F4）。Int64 deleted_at 路径仍由上方
// SoftDeleteTest 覆盖。Option<DateTime> 可空软删字段支持见 F4。

// ─── F4: Option<DateTime> 可空软删字段 ───────────────────
// 完整链路覆盖：schema nullable/Timestamp → query IS NULL 过滤 → INSERT None 绑 NULL /
// Some 绑 DateTime → 软删 UPDATE 写 DateTime.now() → rowMapper NULL/有值读取 →
// batchSave/batchUpdate/upsert 的 Option 绑定。
@Test
public class OptionDateTimeSoftDeleteTest {
    @TestCase
    public func testSchemaNullableTimestampColumn(): Unit {
        let cols = SoftOptUserSchema().columns()
        @Expect(cols.size, 3)
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "name")
        @Expect(cols[2].name, "deleted_at")
        @Expect(cols[2].storageType, StorageType.Timestamp)
        @Expect(cols[2].nullable, true)
    }

    @TestCase
    public func testColumnNamesIncludeDeletedAt(): Unit {
        let cols = SoftOptUserColumnNames()
        @Expect(cols.size, 3)
        @Expect(cols[2].name, "deleted_at")
    }

    @TestCase
    public func testSoftDeleteQueryAddsIsNullFilter(): Unit {
        let q = SoftOptUser.query()
        var hasIsNullFilter = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.WhereClause(predicates) =>
                    for (p in predicates) {
                        match (p) {
                            case Expr.Unary(UnaryOp.IsNull, Expr.Column(name)) =>
                                if (name == "deleted_at") { hasIsNullFilter = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(hasIsNullFilter, true)
    }

    @TestCase
    public func testHardDeleteQueryNoIsNullFilter(): Unit {
        let q = HardOptUser.query()
        var hasDeletedAtFilter = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.WhereClause(predicates) =>
                    for (p in predicates) {
                        match (p) {
                            case Expr.Unary(UnaryOp.IsNull, Expr.Column(name)) =>
                                if (name == "deleted_at") { hasDeletedAtFilter = true }
                            case Expr.Binary(Expr.Column(name), _, _) =>
                                if (name == "deleted_at") { hasDeletedAtFilter = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(hasDeletedAtFilter, false)
    }

    @TestCase
    public func testSaveBindsNullForNoneDeletedAt(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = SoftOptUser()
        u.name = "alice"
        tx.save(u)
        @Expect(conn.stmt.capturedSql.contains("\"deleted_at\""), true)
        @Expect(conn.stmt.nullSetCount, 1)
        @Expect(conn.stmt.capturedSetValues.size, 1)
    }

    @TestCase
    public func testSaveBindsDateTimeForSomeDeletedAt(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = SoftOptUser()
        u.name = "bob"
        let dt = DateTime.now()
        u.deleted_at = Some(dt)
        tx.save(u)
        @Expect(conn.stmt.capturedSql.contains("\"deleted_at\""), true)
        @Expect(conn.stmt.nullSetCount, 0)
        @Expect(conn.stmt.capturedSetValues.size, 2)
        match (conn.stmt.capturedSetValues[1]) {
            case v: DateTime => @Expect(v == dt, true)
            case _ => @Fail("expected DateTime param for Some deleted_at")
        }
    }

    @TestCase
    public func testSoftDeleteWritesDateTimeParam(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u = SoftOptUser()
        u.id = 1
        tx.delete(u)
        @Expect(conn.stmt.capturedSql, "UPDATE \"softOptUser\" SET \"deleted_at\" = ? WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSetValues.size, 2)
        match (conn.stmt.capturedSetValues[0]) {
            case v: DateTime => @Expect(true, true)
            case _ => @Fail("expected DateTime soft-delete param")
        }
    }

    @TestCase
    public func testRowMapperReadsNullDeletedAtAsNone(): Unit {
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("deleted_at", true),
        ]
        // 模拟 NULL 列：getOrNull<DateTime> 对非 DateTime 占位返回 None（与 mapper_test 语义一致）
        let row = Array<Any>(3, { i => if (i == 0) { 1 } else if (i == 1) { "alice" } else { "null-placeholder" } })
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let e = SoftOptUserRowMapper(result, buildColumnMap(cols, 0))
        @Expect(e.id, 1)
        @Expect(e.name, "alice")
        @Expect(e.deleted_at.isNone(), true)
    }

    @TestCase
    public func testRowMapperReadsValueDeletedAtAsSome(): Unit {
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("deleted_at", true),
        ]
        let dt = DateTime.now()
        let row = Array<Any>(3, { i => if (i == 0) { 1 } else if (i == 1) { "alice" } else { dt } })
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let e = SoftOptUserRowMapper(result, buildColumnMap(cols, 0))
        @Expect(e.id, 1)
        @Expect(e.name, "alice")
        @Expect(e.deleted_at.isSome(), true)
        @Expect(e.deleted_at.getOrThrow() == dt, true)
    }

    @TestCase
    public func testBatchSaveBindsOptionParams(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u1 = SoftOptUser()
        u1.name = "a"
        let u2 = SoftOptUser()
        u2.name = "b"
        u2.deleted_at = Some(DateTime.now())
        tx.batchSave([u1, u2])
        @Expect(conn.stmt.capturedSql.contains("\"deleted_at\""), true)
        // 4 个 SQL 参数 = [name_a, NULL, name_b, Some(dt)]；set 记录 3 个（None 走 setNull）
        @Expect(conn.stmt.capturedSetValues.size, 3)
        @Expect(conn.stmt.nullSetCount, 1)
        var hasDateTime = false
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: DateTime => hasDateTime = true; case _ => () }
        }
        @Expect(hasDateTime, true)
    }

    @TestCase
    public func testBatchUpdateBindsOptionParams(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u1 = SoftOptUser()
        u1.id = 1
        u1.name = "a"
        u1.deleted_at = Some(DateTime.now())
        let u2 = SoftOptUser()
        u2.id = 2
        u2.name = "b"
        tx.batchUpdate([u1, u2])
        @Expect(conn.stmt.capturedSql.contains("\"deleted_at\" = CASE"), true)
        @Expect(conn.stmt.nullSetCount, 1)
        var hasDateTime = false
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: DateTime => hasDateTime = true; case _ => () }
        }
        @Expect(hasDateTime, true)
    }

    // F4: PG 批量更新对 Option<DateTime> 列追加 ::TIMESTAMP 转换——pgCastTypeOf 必须解包
    // Option（Option<DateTime> → TIMESTAMP，修复前落 TEXT 兜底 `::TEXT`，CASE 值类型不匹配）。
    @TestCase
    public func testBatchUpdatePostgresCastTimestampForOptionDeletedAt(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let u1 = SoftOptUser()
        u1.id = 1
        u1.name = "a"
        u1.deleted_at = Some(DateTime.now())
        let u2 = SoftOptUser()
        u2.id = 2
        u2.name = "b"
        tx.batchUpdate([u1, u2])
        @Expect(conn.stmt.capturedSql.contains("\"deleted_at\" = CASE \"id\" WHEN ? THEN ?::TIMESTAMP WHEN ? THEN ?::TIMESTAMP END"), true)
        // name 列仍是 ::TEXT（String 正常映射），deleted_at 单独用 ::TIMESTAMP（Option 解包）
        @Expect(conn.stmt.capturedSql.contains("\"name\" = CASE \"id\" WHEN ? THEN ?::TEXT WHEN ? THEN ?::TEXT END"), true)
    }

    @TestCase
    public func testUpsertBindsOptionParams(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(MockDatasource(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()
        let u = SoftOptUser()
        u.id = 1
        u.name = "n"
        u.deleted_at = Some(DateTime.now())
        tx.upsert(u)
        @Expect(conn.stmt.capturedSql.contains("\"deleted_at\""), true)
        @Expect(conn.stmt.nullSetCount, 0)
        var hasDateTime = false
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: DateTime => hasDateTime = true; case _ => () }
        }
        @Expect(hasDateTime, true)
    }
}

// ─── Decimal 字段端到端 fixture ─────────────────────────
// Decimal 非可空字段 + Option<Decimal> 可空字段（F4 同构扩展）。修复前：
// typeNameToStorageType("Decimal") 落 Json 兜底（schema 建 JSON 列 + M22 warning 误报）、
// dispatchSet 无 Decimal 分支（写路径抛 RefineException）、Option<Decimal> 被
// isRelationField 当关系字段跳过（schema/insert/select/mapper 全不识别）。
// 表名固定全小写（与 PG 写路径未加引号折叠一致，参考 PgPost）。
@Refine
@Table["decimalproduct"]
public class DecimalProduct {
    var id: Int64 = 0
    var name: String = ""
    var price: Decimal = Decimal.parse("0")
}

@Refine
@Table["decimaldiscount"]
public class DecimalDiscount {
    var id: Int64 = 0
    var name: String = ""
    var discount: Option<Decimal> = None
}

// @Field[Text] 覆盖 Decimal → 显式存 Text（用户知情，跳过 Decimal 语义）——回归
@Refine
@Table["decimaloverride"]
public class DecimalTextOverride {
    var id: Int64 = 0
    var name: String = ""
    @Field[Text]
    var price: Decimal = Decimal.parse("0")
}

// ─── Decimal 字段端到端测试 ─────────────────────────────
// 覆盖：schema storageType=Decimal + nullable 按 Option 与否、query select 含该列
//（无 Json warning）、INSERT 绑定 Decimal/Option(None→setNull, Some→set<Decimal>)、
// UPDATE、rowMapper 读回（get<Decimal>/getOrNull<Decimal>）、批量 save/update/upsert
// 绑定、PG 批量更新 ::NUMERIC 转换、@Field[Text] 覆盖回归。
@Test
public class DecimalFieldTest {
    @TestCase
    public func testSchemaDecimalStorageType(): Unit {
        let cols = DecimalProductSchema().columns()
        @Expect(cols.size, 3)
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "name")
        @Expect(cols[2].name, "price")
        @Expect(cols[2].storageType, StorageType.Decimal)
        @Expect(cols[2].nullable, false)
    }

    @TestCase
    public func testSchemaOptionDecimalNullable(): Unit {
        let cols = DecimalDiscountSchema().columns()
        @Expect(cols.size, 3)
        @Expect(cols[2].name, "discount")
        @Expect(cols[2].storageType, StorageType.Decimal)
        @Expect(cols[2].nullable, true)
    }

    @TestCase
    public func testColumnNamesIncludeDecimalFields(): Unit {
        let cols = DecimalProductColumnNames()
        @Expect(cols.size, 3)
        @Expect(cols[2].name, "price")
    }

    // Decimal 不再是 Json 兜底 → M22 不再误报；query() 的 select 列表必须含 price 列
    @TestCase
    public func testQuerySelectIncludesDecimalColumn(): Unit {
        let q = DecimalProduct.query()
        var hasPrice = false
        for (c in q.stmt.clauses) {
            match (c) {
                case Clause.SelectClause(cols) =>
                    for (e in cols) {
                        match (e) {
                            case Expr.Column(name) => if (name == "price") { hasPrice = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(hasPrice, true)
    }

    @TestCase
    public func testSaveBindsDecimalParam(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = DecimalProduct()
        p.name = "p1"
        p.price = Decimal.parse("12345.6789")
        tx.save(p)
        @Expect(conn.stmt.capturedSql.contains("\"price\""), true)
        @Expect(conn.stmt.capturedSetValues.size, 2)
        match (conn.stmt.capturedSetValues[1]) {
            case v: Decimal => @Expect(v == Decimal.parse("12345.6789"), true)
            case _ => @Fail("expected Decimal param for price")
        }
    }

    @TestCase
    public func testSaveBindsNullForNoneDiscount(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let d = DecimalDiscount()
        d.name = "d1"
        tx.save(d)
        @Expect(conn.stmt.capturedSql.contains("\"discount\""), true)
        @Expect(conn.stmt.nullSetCount, 1)
        @Expect(conn.stmt.capturedSetValues.size, 1)
    }

    @TestCase
    public func testSaveBindsDecimalForSomeDiscount(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let d = DecimalDiscount()
        d.name = "d2"
        d.discount = Some(Decimal.parse("9.5"))
        tx.save(d)
        @Expect(conn.stmt.capturedSql.contains("\"discount\""), true)
        @Expect(conn.stmt.nullSetCount, 0)
        @Expect(conn.stmt.capturedSetValues.size, 2)
        match (conn.stmt.capturedSetValues[1]) {
            case v: Decimal => @Expect(v == Decimal.parse("9.5"), true)
            case _ => @Fail("expected Decimal param for Some discount")
        }
    }

    @TestCase
    public func testUpdateIncludesDecimalColumn(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = DecimalProduct()
        p.id = 1
        p.name = "p1"
        p.price = Decimal.parse("88.8")
        tx.update(p)
        @Expect(conn.stmt.capturedSql.contains("\"price\" = ?"), true)
        @Expect(conn.stmt.capturedSetValues.size, 3)
        var hasDecimal = false
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: Decimal => hasDecimal = true; case _ => () }
        }
        @Expect(hasDecimal, true)
    }

    @TestCase
    public func testRowMapperReadsDecimalValue(): Unit {
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("price", false),
        ]
        let price = Decimal.parse("12345.6789")
        let row = Array<Any>(3, { i => if (i == 0) { 1 } else if (i == 1) { "p1" } else { price } })
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let e = DecimalProductRowMapper(result, buildColumnMap(cols, 0))
        @Expect(e.id, 1)
        @Expect(e.name, "p1")
        @Expect(e.price == price, true)
    }

    @TestCase
    public func testRowMapperReadsNullDiscountAsNone(): Unit {
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("discount", true),
        ]
        let row = Array<Any>(3, { i => if (i == 0) { 1 } else if (i == 1) { "d1" } else { "null-placeholder" } })
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let e = DecimalDiscountRowMapper(result, buildColumnMap(cols, 0))
        @Expect(e.id, 1)
        @Expect(e.name, "d1")
        @Expect(e.discount.isNone(), true)
    }

    @TestCase
    public func testRowMapperReadsSomeDiscountAsSome(): Unit {
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("discount", true),
        ]
        let discount = Decimal.parse("9.5")
        let row = Array<Any>(3, { i => if (i == 0) { 1 } else if (i == 1) { "d1" } else { discount } })
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let e = DecimalDiscountRowMapper(result, buildColumnMap(cols, 0))
        @Expect(e.id, 1)
        @Expect(e.name, "d1")
        @Expect(e.discount.isSome(), true)
        @Expect(e.discount.getOrThrow() == discount, true)
    }

    @TestCase
    public func testBatchSaveBindsDecimalParams(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p1 = DecimalProduct()
        p1.name = "a"
        p1.price = Decimal.parse("1.1")
        let p2 = DecimalProduct()
        p2.name = "b"
        p2.price = Decimal.parse("2.2")
        tx.batchSave([p1, p2])
        @Expect(conn.stmt.capturedSql.contains("\"price\""), true)
        @Expect(conn.stmt.capturedSetValues.size, 4)
        var decimalCount = 0
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: Decimal => decimalCount++; case _ => () }
        }
        @Expect(decimalCount, 2)
    }

    @TestCase
    public func testBatchSaveBindsOptionDecimalParams(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let d1 = DecimalDiscount()
        d1.name = "a"
        let d2 = DecimalDiscount()
        d2.name = "b"
        d2.discount = Some(Decimal.parse("5.5"))
        tx.batchSave([d1, d2])
        @Expect(conn.stmt.capturedSql.contains("\"discount\""), true)
        // 4 个 SQL 参数 = [name_a, NULL, name_b, Some(5.5)]；set 记录 3 个（None 走 setNull）
        @Expect(conn.stmt.capturedSetValues.size, 3)
        @Expect(conn.stmt.nullSetCount, 1)
        var hasDecimal = false
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: Decimal => hasDecimal = true; case _ => () }
        }
        @Expect(hasDecimal, true)
    }

    @TestCase
    public func testBatchUpdateBindsDecimalParams(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let p1 = DecimalProduct()
        p1.id = 1
        p1.name = "a"
        p1.price = Decimal.parse("3.3")
        let p2 = DecimalProduct()
        p2.id = 2
        p2.name = "b"
        p2.price = Decimal.parse("4.4")
        tx.batchUpdate([p1, p2])
        @Expect(conn.stmt.capturedSql.contains("\"price\" = CASE"), true)
        var decimalCount = 0
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: Decimal => decimalCount++; case _ => () }
        }
        @Expect(decimalCount, 2)
    }

    // PG 批量更新对 Decimal 列追加 ::NUMERIC 转换（修复前落 TEXT 兜底 `::TEXT`）
    @TestCase
    public func testBatchUpdatePostgresCastNumericForDecimal(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p1 = DecimalProduct()
        p1.id = 1
        p1.name = "a"
        p1.price = Decimal.parse("3.3")
        let p2 = DecimalProduct()
        p2.id = 2
        p2.name = "b"
        p2.price = Decimal.parse("4.4")
        tx.batchUpdate([p1, p2])
        @Expect(conn.stmt.capturedSql.contains("\"price\" = CASE \"id\" WHEN ? THEN ?::NUMERIC WHEN ? THEN ?::NUMERIC END"), true)
        // name 列仍是 ::TEXT（String 正常映射）
        @Expect(conn.stmt.capturedSql.contains("\"name\" = CASE \"id\" WHEN ? THEN ?::TEXT WHEN ? THEN ?::TEXT END"), true)
    }

    @TestCase
    public func testUpsertBindsDecimalParams(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(MockDatasource(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()
        let p = DecimalProduct()
        p.id = 1
        p.name = "n"
        p.price = Decimal.parse("6.6")
        tx.upsert(p)
        @Expect(conn.stmt.capturedSql.contains("\"price\""), true)
        @Expect(conn.stmt.nullSetCount, 0)
        var hasDecimal = false
        for (v in conn.stmt.capturedSetValues) {
            match (v) { case _: Decimal => hasDecimal = true; case _ => () }
        }
        @Expect(hasDecimal, true)
    }

    // @Field[Text] 覆盖：Decimal 字段显式存 Text（不 Decimal）——回归
    @TestCase
    public func testFieldTextOverrideDecimal(): Unit {
        let cols = DecimalTextOverrideSchema().columns()
        @Expect(cols.size, 3)
        @Expect(cols[2].name, "price")
        @Expect(cols[2].storageType, StorageType.Text)
    }
}

// ─── Version + Audit Fields Tests ───────────────────────

@Refine
public class VersionedPost {
    var id: Int64 = 0
    var title: String = ""
    var created_at: DateTime = DateTime.now()
    var updated_at: DateTime = DateTime.now()
    @Version
    var version: Int64 = 0
}

@Refine
public class VersionedEvent {
    @Id[]
    var id: String = ""
    var name: String = ""
    @Version
    var version: Int64 = 0
}

@Refine
public class VersionedOrderTag {
    @Id[]
    var order_id: Int64 = 0
    @Id[]
    var tag_id: Int64 = 0
    var quantity: Int64 = 0
    @Version
    var version: Int64 = 0
}

@Refine
public class VersionedOrder {
    var id: Int64 = 0
    var name: String = ""
    @Version
    var version: Int64 = 0

    @Rel[has_many, VersionedOrderItem, order_id]
    var items: ArrayList<VersionedOrderItem> = ArrayList<VersionedOrderItem>()
}

@Refine
public class VersionedOrderItem {
    var id: Int64 = 0
    var name: String = ""
    @Version
    var version: Int64 = 0
    var order_id: Int64 = 0
}

// I19 回归 fixture：仅 pk + version、无其它可更新列 —— update 时 SET 子句只有
// version 自增一项，验证无前导逗号（修复前生成 `SET , "version" = "version" + 1`）
@Refine
public class VersionedOnly {
    var id: Int64 = 0
    @Version
    var version: Int64 = 0
}

@Test
public class VersionedEntityTest {
    @TestCase
    public func testVersionedPostAuditColumnsStorageType(): Unit {
        let schema = VersionedPostSchema()
        let cols = schema.columns()
        @Expect(cols[2].storageType, StorageType.Timestamp)
        @Expect(cols[3].storageType, StorageType.Timestamp)
    }

    @TestCase
    public func testTxSaveVersionedPostInjectsAuditAndVersion(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let before = DateTime.now()

        let p = VersionedPost()
        p.title = "Audit"
        tx.save(p)

        let after = DateTime.now()
        @Expect(p.version, 1)
        @Expect(p.created_at >= before, true)
        @Expect(p.created_at <= after, true)
        @Expect(p.updated_at >= before, true)
        @Expect(p.updated_at <= after, true)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"versionedPost\" (\"title\", \"created_at\", \"updated_at\", \"version\")"), true)
        @Expect(conn.stmt.capturedSql.contains("VALUES (?, ?, ?, ?)"), true)
    }

    @TestCase
    public func testTxUpdateVersionedPostSuccess(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "Updated"
        p.version = 1
        tx.update(p)

        @Expect(conn.stmt.capturedSql, "UPDATE \"versionedPost\" SET \"title\" = ?, \"created_at\" = ?, \"updated_at\" = ?, \"version\" = \"version\" + 1 WHERE \"id\" = ? AND \"version\" = ?")
        @Expect(p.version, 2)
    }

    @TestCase
    public func testTxUpdateVersionedPostConflictNotFound(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        let tx = sqliteTx(conn)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "Updated"
        p.version = 1
        try {
            tx.update(p)
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.entityType, "VersionedPost")
            @Expect(e.pk, "1")
            @Expect(e.expected, 1)
            @Expect(e.actual, -1)
            @Expect(conn.stmt.capturedSql, "SELECT \"version\" FROM \"versionedPost\" WHERE \"id\" = ?")
        }
    }

    @TestCase
    public func testTxUpdateVersionedPostConflictActualVersion(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        conn.stmt.queryResult = RowQueryResult(5)
        let tx = sqliteTx(conn)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "Updated"
        p.version = 1
        try {
            tx.update(p)
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.actual, 5)
            @Expect(e.expected, 1)
        }
    }

    @TestCase
    public func testTxSaveVersionedEventClientPkInjectsVersion(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let e = VersionedEvent()
        e.id = "evt-1"
        e.name = "E"
        tx.save(e)

        @Expect(e.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"versionedEvent\" (\"id\", \"name\", \"version\")"), true)
    }

    @TestCase
    public func testTxUpdateVersionedEventConflictStringPk(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        let tx = sqliteTx(conn)
        tx.begin()

        let e = VersionedEvent()
        e.id = "evt-1"
        e.version = 1
        try {
            tx.update(e)
            @Fail("expected OptimisticLockException")
        } catch (ex: OptimisticLockException) {
            @Expect(ex.pk, "evt-1")
            @Expect(ex.expected, 1)
            @Expect(ex.actual, -1)
        }
    }

    @TestCase
    public func testTxUpdateVersionedPostWritesVersionInSet(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.version = 3
        tx.update(p)

        let setPart = conn.stmt.capturedSql.split("SET ")[1].split(" WHERE")[0]
        @Expect(setPart.contains("\"version\" = \"version\" + 1"), true)
        @Expect(setPart.contains("created_at"), true)
        @Expect(p.version, 4)
    }

    @TestCase
    public func testTxSaveVersionedOrderTagInjectsVersion(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let ot = VersionedOrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        ot.quantity = 5
        tx.save(ot)

        @Expect(ot.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"versionedOrderTag\" (\"order_id\", \"tag_id\", \"quantity\", \"version\")"), true)
    }

    @TestCase
    public func testTxUpdateVersionedOrderTagCompoundPk(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()

        let ot = VersionedOrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        ot.quantity = 5
        ot.version = 1
        tx.update(ot)

        @Expect(conn.stmt.capturedSql, "UPDATE \"versionedOrderTag\" SET \"quantity\" = ?, \"version\" = \"version\" + 1 WHERE \"order_id\" = ? AND \"tag_id\" = ? AND \"version\" = ?")
        @Expect(ot.version, 2)
    }

    @TestCase
    public func testTxUpdateVersionedOrderTagConflictCompositePk(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 0
        conn.stmt.queryResult = RowQueryResult(3)
        let tx = sqliteTx(conn)
        tx.begin()

        let ot = VersionedOrderTag()
        ot.order_id = 1
        ot.tag_id = 2
        ot.quantity = 5
        ot.version = 1
        try {
            tx.update(ot)
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.pk, "1:2")
            @Expect(e.expected, 1)
            @Expect(e.actual, 3)
        }
    }

    @TestCase
    public func testTxUpdateVersionedPostTwiceNoFalseConflict(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "T"
        p.version = 1
        tx.update(p)
        @Expect(p.version, 2)

        conn.stmt.capturedSetValues.clear()
        conn.stmt.mockRowCount = 1
        tx.update(p)
        @Expect(p.version, 3)

        let lastIdx = conn.stmt.capturedSetValues.size - 1
        var lastParam: Int64 = -1
        match (conn.stmt.capturedSetValues[lastIdx]) {
            case v: Int64 => lastParam = v
            case _ => ()
        }
        @Expect(lastParam, 2)
    }

    @TestCase
    public func testTxUpdateVersionedPostNoOpStillBumpsVersion(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "same"
        p.version = 2
        tx.update(p)

        @Expect(conn.stmt.capturedSql.contains("\"version\" = \"version\" + 1"), true)
        @Expect(p.version, 3)
    }

    // ─── Versioned Batch Operations ─────────────────────

    @TestCase
    public func testTxBatchSaveVersionedPostInjectsAuditAndVersion(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let p1 = VersionedPost()
        p1.title = "A"
        let p2 = VersionedPost()
        p2.title = "B"
        tx.batchSave([p1, p2])

        @Expect(p1.version, 1)
        @Expect(p2.version, 1)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"versionedPost\" (\"title\", \"created_at\", \"updated_at\", \"version\") VALUES (?, ?, ?, ?), (?, ?, ?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 8)
    }

    @TestCase
    public func testTxBatchSaveVersionedEventClientPkInjectsVersion(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let e1 = VersionedEvent()
        e1.id = "evt-1"
        e1.name = "E1"
        let e2 = VersionedEvent()
        e2.id = "evt-2"
        e2.name = "E2"
        tx.batchSave([e1, e2])

        @Expect(e1.version, 1)
        @Expect(e2.version, 1)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"versionedEvent\" (\"id\", \"name\", \"version\") VALUES (?, ?, ?), (?, ?, ?)")
    }

    @TestCase
    public func testTxBatchSaveVersionedOrderTagInjectsVersion(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()

        let ot1 = VersionedOrderTag()
        ot1.order_id = 1
        ot1.tag_id = 2
        ot1.quantity = 5
        let ot2 = VersionedOrderTag()
        ot2.order_id = 3
        ot2.tag_id = 4
        ot2.quantity = 6
        tx.batchSave([ot1, ot2])

        @Expect(ot1.version, 1)
        @Expect(ot2.version, 1)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"versionedOrderTag\" (\"order_id\", \"tag_id\", \"quantity\", \"version\") VALUES (?, ?, ?, ?), (?, ?, ?, ?)")
    }

    @TestCase
    public func testTxBatchUpdateVersionedPostVersionCaseAndRefresh(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 2
        let tx = sqliteTx(conn)
        tx.begin()

        let p1 = VersionedPost()
        p1.id = 1
        p1.title = "A1"
        p1.version = 1
        let p2 = VersionedPost()
        p2.id = 2
        p2.title = "A2"
        p2.version = 3
        tx.batchUpdate([p1, p2])

        @Expect(conn.stmt.capturedSql, "UPDATE \"versionedPost\" SET \"title\" = CASE \"id\" WHEN ? THEN ? WHEN ? THEN ? END, \"created_at\" = CASE \"id\" WHEN ? THEN ? WHEN ? THEN ? END, \"version\" = CASE \"id\" WHEN ? THEN ? WHEN ? THEN ? END, \"updated_at\" = CASE \"id\" WHEN ? THEN ? WHEN ? THEN ? END WHERE \"id\" IN (?, ?)")
        @Expect(conn.stmt.capturedSql.contains("\"version\" = CASE"), true)
        @Expect(conn.stmt.capturedSql.contains("\"updated_at\" = CASE"), true)
        @Expect(p1.version, 2)
        @Expect(p2.version, 4)
        @Expect(containsInt(conn.stmt.capturedSetValues, 2), true)
        @Expect(containsInt(conn.stmt.capturedSetValues, 4), true)
    }

    @TestCase
    public func testTxBatchUpdateVersionedPostConflict(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()

        let p1 = VersionedPost()
        p1.id = 1
        p1.title = "A"
        p1.version = 1
        let p2 = VersionedPost()
        p2.id = 2
        p2.title = "B"
        p2.version = 1
        try {
            tx.batchUpdate([p1, p2])
            @Fail("expected OptimisticLockException")
        } catch (e: OptimisticLockException) {
            @Expect(e.entityType, "VersionedPost")
            @Expect(e.pk, "batch")
            @Expect(e.expected, 0)
            @Expect(e.actual, -1)
        }
        @Expect(p1.version, 1)
        @Expect(p2.version, 1)
    }

    @TestCase
    public func testTxBatchUpdateVersionedOrderTagVersionCase(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 2
        let tx = sqliteTx(conn)
        tx.begin()

        let ot1 = VersionedOrderTag()
        ot1.order_id = 1
        ot1.tag_id = 2
        ot1.quantity = 5
        ot1.version = 1
        let ot2 = VersionedOrderTag()
        ot2.order_id = 3
        ot2.tag_id = 4
        ot2.quantity = 6
        ot2.version = 2
        tx.batchUpdate([ot1, ot2])

        @Expect(conn.stmt.capturedSql.contains("\"version\" = CASE WHEN \"order_id\" = ? AND \"tag_id\" = ? THEN ? WHEN \"order_id\" = ? AND \"tag_id\" = ? THEN ? END"), true)
        @Expect(ot1.version, 2)
        @Expect(ot2.version, 3)
        @Expect(containsInt(conn.stmt.capturedSetValues, 2), true)
        @Expect(containsInt(conn.stmt.capturedSetValues, 3), true)
    }

    @TestCase
    public func testTxUpsertVersionedPostMySQL(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        let tx = Tx(conn, rf, 1)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "T"
        tx.upsert(p)

        @Expect(p.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `versionedPost` (`id`, `title`, `created_at`, `updated_at`, `version`)"), true)
        @Expect(conn.stmt.capturedSql.contains("ON DUPLICATE KEY UPDATE"), true)
        // R-M19: 行别名 AS new 下 version 自增 RHS 须表限定（裸列名与新行歧义）
        @Expect(conn.stmt.capturedSql.contains("`version` = `versionedPost`.`version` + 1"), true)
        @Expect(conn.stmt.capturedSql.contains("`version` = `version` + 1"), false)
        @Expect(conn.stmt.capturedSql.contains("`updated_at` = ?"), true)
        @Expect(conn.stmt.capturedSql.contains("`created_at` = VALUES(`created_at`)"), false)
        @Expect(conn.stmt.capturedSetValues.size, 6)
    }

    @TestCase
    public func testTxUpsertVersionedPostPostgres(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), PostgreSQLDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "T"
        tx.upsert(p)

        @Expect(p.version, 1)
        // I2：PG 不再强制小写，驼峰表名 versionedPost 原样保留（此前被 toAsciiLower 折叠为 versionedpost）
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"versionedPost\" (\"id\", \"title\", \"created_at\", \"updated_at\", \"version\")"), true)
        @Expect(conn.stmt.capturedSql.contains("ON CONFLICT (\"id\") DO UPDATE SET"), true)
        // R-C1：PG 的 DO UPDATE SET 目标列不允许 table.col 限定，LHS 必须裸列名、RHS 表限定
        @Expect(conn.stmt.capturedSql.contains("\"version\" = \"versionedPost\".\"version\" + 1"), true)
        @Expect(conn.stmt.capturedSql.contains("\"updated_at\" = EXCLUDED.\"updated_at\""), true)
        @Expect(conn.stmt.capturedSql.contains("\"created_at\" = EXCLUDED.\"created_at\""), false)
        @Expect(conn.stmt.capturedSetValues.size, 5)
    }

    @TestCase
    public func testTxUpsertVersionedPostSQLite(): Unit {
        // 本项目无真实 SQLite 驱动，此处用 CaptureConnection（mock）仅验证宏层生成的
        // SQLite versioned upsert SQL（version 冲突自增 + excluded 引用 + extraParamCount=0）
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()

        let p = VersionedPost()
        p.id = 1
        p.title = "T"
        tx.upsert(p)

        @Expect(p.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"versionedPost\" (\"id\", \"title\", \"created_at\", \"updated_at\", \"version\")"), true)
        @Expect(conn.stmt.capturedSql.contains("ON CONFLICT (\"id\") DO UPDATE SET"), true)
        @Expect(conn.stmt.capturedSql.contains("\"version\" = \"version\" + 1"), true)
        @Expect(conn.stmt.capturedSql.contains("\"updated_at\" = excluded.\"updated_at\""), true)
        @Expect(conn.stmt.capturedSql.contains("\"created_at\" = excluded.\"created_at\""), false)
        @Expect(conn.stmt.capturedSetValues.size, 5)
    }

    @TestCase
    public func testTxUpsertVersionedEventMySQL(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), MySQLDialect(), 1)
        let tx = Tx(conn, rf, 1)
        tx.begin()

        let e = VersionedEvent()
        e.id = "evt-1"
        e.name = "E"
        tx.upsert(e)

        @Expect(e.version, 1)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO `versionedEvent` (`id`, `name`, `version`)"), true)
        // R-M19: 行别名 AS new 下 version 自增 RHS 须表限定（裸列名与新行歧义）
        @Expect(conn.stmt.capturedSql.contains("`version` = `versionedEvent`.`version` + 1"), true)
        @Expect(conn.stmt.capturedSql.contains("`version` = `version` + 1"), false)
    }
}

@Test
public class RelationFieldRewriteTest {
    @TestCase
    public func testModifiedFlagsInitiallyFalse(): Unit {
        let p = PostWithRel()
        @Expect(p._authorModified, false)
        @Expect(p._tagsModified, false)
        @Expect(p._commentsModified, false)
    }

    @TestCase
    public func testSetterSetsModifiedFlag(): Unit {
        let p = PostWithRel()
        p.author = Some(User())
        @Expect(p._authorModified, true)

        let p2 = PostWithRel()
        p2.tags = ArrayList<Tag>()
        @Expect(p2._tagsModified, true)

        let p3 = PostWithRel()
        p3.comments = ArrayList<Comment>()
        @Expect(p3._commentsModified, true)
    }

    @TestCase
    public func testRelationPropValueRoundtrip(): Unit {
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p.author = Some(u)
        @Expect(p.author.getOrThrow().id, 42)

        let c = Comment()
        c.id = 7
        p.comments.add(c)
        @Expect(p.comments.size, 1)
        @Expect(p.comments[0].id, 7)
    }

    @TestCase
    public func testScalarFieldsUntouched(): Unit {
        let p = PostWithRel()
        p.title = "hello"
        @Expect(p.title, "hello")
    }

    @TestCase
    public func testRowMapperIncludeDoesNotSetModified(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("title", false)
        let col3: ColumnInfo = MapperMockColumnInfo("user_id", false)
        let col4: ColumnInfo = MapperMockColumnInfo("post_id", false)
        let col5: ColumnInfo = MapperMockColumnInfo("author.id", false)
        let cols: Array<ColumnInfo> = [col1, col2, col3, col4, col5]
        let row = Array<Any>(5, {i => if (i == 0) { 42 } else if (i == 1) { "hello" } else if (i == 2) { 7 } else if (i == 3) { 8 } else { 99 }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let e = PostWithRelRowMapper(result, cm)
        @Expect(e._authorModified, false)
        @Expect(e.author.getOrThrow().id, 99)
    }

    @TestCase
    public func testRelClassIncludeSetterDoesNotSetModified(): Unit {
        let p = PostWithRel()
        let u = User()
        u.id = 55
        PostWithRelRel.authorSetter(p, u)
        @Expect(p._authorModified, false)
        @Expect(p.author.getOrThrow().id, 55)
    }

    @TestCase
    public func testRelClassRefManySetterDoesNotSetModified(): Unit {
        let p = PostWithRel()
        let t = Tag()
        t.id = 7
        PostWithRelRel.tagsSetter(p, t)
        @Expect(p._tagsModified, false)
        @Expect(p.tags.size, 1)
        @Expect(p.tags[0].id, 7)
    }
}

@Test
public class CascadeTraversalTest {
    @TestCase
    public func testCascadePreSaveRefToBackfillsFk(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p.author = Some(u)
        let r = p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 42)
        @Expect(refEq(r, p), true)
    }

    @TestCase
    public func testCascadePreSaveRefToZeroIdClearsFk(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let u = User()
        p.author = Some(u)
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 0)
    }

    @TestCase
    public func testCascadePreSaveRefToNoneClearsFk(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.user_id = 7
        p.author = None
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 0)
    }

    @TestCase
    public func testCascadePreSaveSkipsWhenNotModified(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p._author = Some(u)
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 0)
    }

    @TestCase
    public func testCascadePreSaveStringFkBackfills(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let c = UuidRefComment()
        let u = UuidPost()
        u.id = "uuid-1"
        c.post = Some(u)
        c.cascadePreSave(tx, ArrayList<Object>())
        @Expect(c.post_id, "uuid-1")
    }

    @TestCase
    public func testCascadePreSaveStringFkClears(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let c = UuidRefComment()
        c.post_id = "old"
        c.post = Some(UuidPost())
        c.cascadePreSave(tx, ArrayList<Object>())
        @Expect(c.post_id, "")
    }

    @TestCase
    public func testCascadePreSaveStringFkNoneClears(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let c = UuidRefComment()
        c.post_id = "old"
        c.post = None
        c.cascadePreSave(tx, ArrayList<Object>())
        @Expect(c.post_id, "")
    }

    @TestCase
    public func testCascadePostSaveHasManyNewChildSaves(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(c.post_id, 5)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testCascadePostSaveHasManyExistingChildUpdates(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.id = 9
        c.body = "hi"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(c.post_id, 5)
        @Expect(conn.stmt.capturedSql, "UPDATE \"comment\" SET \"body\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testCascadePostSaveHasManyNotModifiedSkips(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.body = "x"
        p.comments.add(c)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(c.post_id, 0)
    }

    @TestCase
    public func testCascadePostSaveHasOneSavesChild(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = UserWithRel()
        u.id = 3
        let pr = ProfileWithRel()
        pr.bio = "bio"
        u.profile = Some(pr)
        u.cascadePostSave(tx, ArrayList<Object>())
        @Expect(pr.user_id, 3)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"profileWithRel\" (\"bio\", \"user_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testCascadePostSaveRefManyRebuilds(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        let list = ArrayList<Tag>()
        list.add(t1)
        list.add(t2)
        p.tags = list
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testCascadePostSaveRefManyNotModifiedSkips(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let t = Tag()
        t.id = 7
        p.tags.add(t)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    @TestCase
    public func testCascadePostSaveVisitedSkipsDuplicates(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.body = "x"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        let visited = ArrayList<Object>()
        visited.add(p)
        p.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(c.post_id, 0)
    }

    @TestCase
    public func testCascadePostSaveSkipsVisitedChild(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        c.body = "x"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        let visited = ArrayList<Object>()
        visited.add(c)
        p.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(c.post_id, 5)
    }

    @TestCase
    public func testCascadePostSaveHasOneSkipsVisitedChild(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = UserWithRel()
        u.id = 3
        let pr = ProfileWithRel()
        pr.bio = "b"
        u.profile = Some(pr)
        let visited = ArrayList<Object>()
        visited.add(pr)
        u.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
        @Expect(pr.user_id, 3)
    }

    @TestCase
    public func testCascadePreSaveRefToResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let u = User()
        u.id = 42
        p.author = Some(u)
        @Expect(p._authorModified, true)
        p.cascadePreSave(tx, ArrayList<Object>())
        @Expect(p.user_id, 42)
        @Expect(p._authorModified, false)
    }

    @TestCase
    public func testCascadePostSaveHasManyResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let c = Comment()
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        @Expect(p._commentsModified, true)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(c.post_id, 5)
        @Expect(p._commentsModified, false)
    }

    @TestCase
    public func testCascadePostSaveHasOneResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = UserWithRel()
        u.id = 3
        let pr = ProfileWithRel()
        pr.bio = "bio"
        u.profile = Some(pr)
        @Expect(u._profileModified, true)
        u.cascadePostSave(tx, ArrayList<Object>())
        @Expect(pr.user_id, 3)
        @Expect(u._profileModified, false)
    }

    @TestCase
    public func testCascadePostSaveRefManyResetsMarker(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let t1 = Tag()
        t1.id = 7
        let list = ArrayList<Tag>()
        list.add(t1)
        p.tags = list
        @Expect(p._tagsModified, true)
        p.cascadePostSave(tx, ArrayList<Object>())
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(p._tagsModified, false)
    }

    @TestCase
    public func testCascadeCycleSaveNoDuplicateInsert(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let a = CategoryWithRel()
        a.id = 1
        let b = CategoryWithRel()
        let la = ArrayList<CategoryWithRel>()
        la.add(b)
        a.children = la
        let lb = ArrayList<CategoryWithRel>()
        lb.add(a)
        b.children = lb
        let visited = ArrayList<Object>()
        a.cascadePostSave(tx, visited)
        b.cascadePostSave(tx, visited)
        a.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 1)
    }

    @TestCase
    public func testCascadeDiamondSaveNoDuplicateSharedChild(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = CategoryWithRel()
        p.id = 1
        let c1 = CategoryWithRel()
        let c2 = CategoryWithRel()
        let d = CategoryWithRel()
        let lp = ArrayList<CategoryWithRel>()
        lp.add(c1)
        lp.add(c2)
        p.children = lp
        let l1 = ArrayList<CategoryWithRel>()
        l1.add(d)
        c1.children = l1
        let l2 = ArrayList<CategoryWithRel>()
        l2.add(d)
        c2.children = l2
        let visited = ArrayList<Object>()
        p.cascadePostSave(tx, visited)
        c1.cascadePostSave(tx, visited)
        d.cascadePostSave(tx, visited)
        c2.cascadePostSave(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testCascadeDeleteChildrenThenJunction(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("body", false), MapperMockColumnInfo("post_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "hi" } else { 5 }})])
        p.cascadeDelete(tx, HashSet<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"comment\" WHERE \"post_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"comment\" WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 9)
    }

    @TestCase
    public func testCascadeDeleteHasOneViaQuery(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let u = UserWithRel()
        u.id = 3
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("bio", false), MapperMockColumnInfo("user_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 7 } else if (i == 1) { "b" } else { 3 }})])
        u.cascadeDelete(tx, HashSet<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"profileWithRel\" WHERE \"user_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"profileWithRel\" WHERE \"id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 3)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
    }

    @TestCase
    public func testCascadeDeleteRecursiveGrandchildren(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("parent_id", false)]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "c" } else { 5 }})]))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 12 } else if (i == 1) { "g" } else { 9 }})]))
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, []))
        let root = CategoryWithRel()
        root.id = 5
        root.cascadeDelete(tx, HashSet<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 5)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"categoryWithRel\" WHERE \"parent_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "SELECT * FROM \"categoryWithRel\" WHERE \"parent_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "SELECT * FROM \"categoryWithRel\" WHERE \"parent_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[3], "DELETE FROM \"categoryWithRel\" WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[4], "DELETE FROM \"categoryWithRel\" WHERE \"id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 12)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 9)
    }

    @TestCase
    public func testCascadeDeleteDbCycleTerminates(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("parent_id", false)]
        // DB 常驻环：A(id=5) → B(id=9) → A'(id=5) → ... 每次 loadX 都新建实体实例，
        // 对象引用（refEq）永远匹配不上，必须靠 (type,id) 键终止递归
        let bRow = Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "b" } else { 5 }})
        let aRow = Array<Any>(3, {i => if (i == 0) { 5 } else if (i == 1) { "a" } else { 9 }})
        for (i in 0..6) {
            let row = if (i % 2 == 0) { bRow } else { aRow }
            conn.stmt.queryResultQueue.add(MapperMockQueryResult(cols, [row]))
        }
        let root = CategoryWithRel()
        root.id = 5
        root.cascadeDelete(tx, HashSet<String>())
        // 环在第二层被 "CategoryWithRel:5" 键命中即返回，且 deleteCascade 操作层守卫阻止对
        // A'(id=5)（与 root 同 (type,id) 的副本行）重复 DELETE：仅 2 次 SELECT + 1 次 DELETE(B)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"categoryWithRel\" WHERE \"parent_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "SELECT * FROM \"categoryWithRel\" WHERE \"parent_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM \"categoryWithRel\" WHERE \"id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 9)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 9)
    }

    @TestCase
    public func testCascadeDeleteVisitedSkipsAlreadySeen(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let visited = HashSet<String>()
        visited.add("PostWithRel:5")
        p.cascadeDelete(tx, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    @TestCase
    public func testCascadeDeleteRefToNotProcessed(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let c = UuidRefComment()
        c.id = 3
        let u = UuidPost()
        u.id = "uuid-1"
        c.post = Some(u)
        c.cascadeDelete(tx, HashSet<String>())
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    // ─── F2(b): 复合主键级联删除 ───────────────────────────

    @TestCase
    public func testCascadeDeleteCompositePkKeyFormat(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let item = OrderLineItem()
        item.tenant_id = 7
        item.line_no = 3
        let visited = HashSet<String>()
        item.cascadeDelete(tx, visited)
        // 键必须是 "<Class>:<pk1>:<pk2>" 冒号拼接（pk 字段顺序 = 声明顺序）
        @Expect(visited.contains("OrderLineItem:7:3"), true)
        @Expect(visited.size, 1)
    }

    @TestCase
    public func testCascadeDeleteCompositePkSkipsAlreadySeen(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let item = OrderLineItem()
        item.tenant_id = 7
        item.line_no = 3
        let visited = HashSet<String>()
        visited.add("OrderLineItem:7:3")
        item.cascadeDelete(tx, visited)
        // 已在 visited 中的 (type, pk) 键直接短路，不产生任何 SQL
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }

    @TestCase
    public func testCascadeDeleteCompositePkNoDuplicateDelete(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        // 同一复合主键实体经两次 deleteCascade 调用（模拟环/菱形里被两条路径命中），
        // 第二次必须被 visited 键守卫短路，DELETE 只执行一次
        let item = OrderLineItem()
        item.tenant_id = 7
        item.line_no = 3
        let visited = HashSet<String>()
        tx.deleteCascade(item, visited)
        tx.deleteCascade(item, visited)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "DELETE FROM \"orderLineItem\" WHERE \"tenant_id\" = ? AND \"line_no\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 3)
        @Expect(visited.contains("OrderLineItem:7:3"), true)
    }

    @TestCase
    public func testCascadeDeleteCompositePkChildrenViaParent(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let order = OrderWithRel()
        order.id = 5
        // 子对象（复合主键 OrderLineItem）由 loadX(tx) 从库加载：tenant_id/line_no/sku/order_id
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("tenant_id", false),
            MapperMockColumnInfo("line_no", false),
            MapperMockColumnInfo("sku", false),
            MapperMockColumnInfo("order_id", false),
        ]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(4, {i => if (i == 0) { 7 } else if (i == 1) { 3 } else if (i == 2) { "sku-a" } else { 5 }})])
        let visited = HashSet<String>()
        order.cascadeDelete(tx, visited)
        // 父 cascadeDelete：SELECT 子对象 → 对每个子对象 tx.deleteCascade（DELETE）
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"orderLineItem\" WHERE \"order_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"orderLineItem\" WHERE \"tenant_id\" = ? AND \"line_no\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 3)
        @Expect(visited.contains("OrderLineItem:7:3"), true)
    }

    @TestCase
    public func testRowMapperIncludeStringPkRefTo(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("body", false)
        let col3: ColumnInfo = MapperMockColumnInfo("post_id", false)
        let col4: ColumnInfo = MapperMockColumnInfo("post.id", false)
        let cols: Array<ColumnInfo> = [col1, col2, col3, col4]
        let row = Array<Any>(4, {i => if (i == 0) { 1 } else if (i == 1) { "hello" } else if (i == 2) { "uuid-9" } else { "uuid-99" }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let e = UuidRefCommentRowMapper(result, cm)
        @Expect(e.post_id, "uuid-9")
        @Expect(e.post.getOrThrow().id, "uuid-99")
    }
}

@Test
public class UnderscoreFieldEntityTest {
    @TestCase
    public func testUnderscoreFieldInCols(): Unit {
        let cols = UnderscoreFieldEntity.col()
        @Expect(cols._note.name, "_note")
        @Expect(cols.id.name, "id")
    }

    @TestCase
    public func testUnderscoreFieldInColumnNames(): Unit {
        let names = UnderscoreFieldEntityColumnNames()
        var found = false
        for (c in names) {
            if (c.name == "_note") { found = true }
        }
        @Expect(found, true)
        @Expect(names.size, 2)
    }

    @TestCase
    public func testUnderscoreFieldMappedByRowMapper(): Unit {
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("_note", false)
        let row = Array<Any>(2, {i => if (i == 0) { 42 } else { "internal" }})
        let result = MapperMockQueryResult([col1, col2], [row])
        result.next()
        let cm = buildColumnMap([col1, col2])
        let e = UnderscoreFieldEntityRowMapper(result, cm)
        @Expect(e.id, 42)
        @Expect(e._note, "internal")
    }
}

@Test
public class RefManyRelationApiTest {
    @TestCase
    public func testAppendTagsSingle(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        t.id = 7
        let r = p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
        r.clearTags(tx)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
    }

    @TestCase
    public func testAppendTagsArray(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        p.appendTags(tx, [t1, t2])
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 4)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 8)
    }

    @TestCase
    public func testReplaceTags(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        p.replaceTags(tx, [t1, t2])
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSetValues.size, 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 8)
    }

    @TestCase
    public func testDeleteTagsSingle(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        t.id = 7
        p.deleteTags(tx, t)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ? AND \"tag_id\" = ?")
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
    }

    @TestCase
    public func testDeleteTagsArray(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        p.deleteTags(tx, [t1, t2])
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ? AND \"tag_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ? AND \"tag_id\" = ?")
        @Expect(conn.stmt.capturedSetValues.size, 4)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 7)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 8)
    }

    @TestCase
    public func testClearTags(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        p.clearTags(tx)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(conn.stmt.capturedSetValues.size, 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
    }

    @TestCase
    public func testCountTags(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let col: ColumnInfo = MapperMockColumnInfo("COUNT(*)", false)
        conn.stmt.queryResult = MapperMockQueryResult([col], [Array<Any>(1, {i => 5})])
        let n = p.countTags(tx)
        @Expect(n, 5)
        @Expect(conn.stmt.capturedSql, "SELECT COUNT(*) FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(conn.stmt.capturedSetValues.size, 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
    }

    @TestCase
    public func testAppendTagsUnsavedThrows(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        try {
            p.appendTags(tx, t)
            @Fail("expected exception for unsaved target")
        } catch (e: Exception) {
            @Expect(e.message, "ref_many tags: target Tag has empty id, save it first")
        }
    }

    @TestCase
    public func testDeleteTagsUnsavedThrows(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 42
        let t = Tag()
        try {
            p.deleteTags(tx, t)
            @Fail("expected exception for unsaved target")
        } catch (e: Exception) {
            @Expect(e.message, "ref_many tags: target Tag has empty id, save it first")
        }
    }
}

@Test
public class RefManyTableOverrideTest {
    @TestCase
    public func testJunctionSchemaColumnsUseLowerTargetName(): Unit {
        let js = CustomTagPost_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols.size, 2)
        @Expect(cols[0].name, "custom_tag_posts_id")
        @Expect(cols[1].name, "customTag_id")
    }

    @TestCase
    public func testAppendTagsUsesJunctionColumnNames(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = CustomTagPost()
        p.id = 42
        let t = CustomTag()
        t.id = 7
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"custom_post_tags\" (\"custom_tag_posts_id\", \"customTag_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testDeleteTagsUsesJunctionColumnNames(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = CustomTagPost()
        p.id = 42
        let t = CustomTag()
        t.id = 7
        p.deleteTags(tx, t)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"custom_post_tags\" WHERE \"custom_tag_posts_id\" = ? AND \"customTag_id\" = ?")
    }

    @TestCase
    public func testLoadTagsUsesJunctionColumnNames(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = CustomTagPost()
        p.id = 42
        p.loadTags(tx)
        @Expect(conn.stmt.capturedSql.contains("\"custom_post_tags\".\"customTag_id\""), true)
        @Expect(conn.stmt.capturedSql.contains("\"custom_post_tags\".\"custom_tags_id\""), false)
        @Expect(conn.stmt.capturedSql.contains("\"custom_post_tags\".\"custom_tag_posts_id\""), true)
    }

    // ─── F1: junction schema 列类型跟随源/目标主键类型 ─────────────
    // 源列类型 = 本类主键类型（宏层可内省）；目标列类型 = 目标类主键类型。
    // 目标类 String-pk 时宏层无法跨类内省，保持 Integer（见任务 F1 决策注释）。

    @TestCase
    public func testJunctionSourceColIntegerWhenSourcePkInt64(): Unit {
        // CustomTagPost 主键 Int64 → 源列 Integer；CustomTag 主键 Int64 → 目标列 Integer
        let js = CustomTagPost_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols[0].storageType, StorageType.Integer)
        @Expect(cols[1].storageType, StorageType.Integer)
    }

    @TestCase
    public func testJunctionSourceColStringWhenSourcePkString(): Unit {
        // StringKeyPost 主键 String → 源列 String；目标 Tag 主键 Int64 → 目标列 Integer
        let js = StringKeyPost_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols[0].name, "stringKeyPost_id")
        @Expect(cols[0].storageType, StorageType.String)
        @Expect(cols[1].name, "tag_id")
        @Expect(cols[1].storageType, StorageType.Integer)
    }

    @TestCase
    public func testJunctionSourceColStringWhenUuidSourcePkString(): Unit {
        // UuidKeyTagPost 主键 String → 源列 String；目标 UuidTag 亦 String-pk，
        // F1 起目标列类型运行时从目标实体 Schema 读取 → 应为 String（此前硬编码 Integer）
        let js = UuidKeyTagPost_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols[0].name, "uuidKeyTagPost_id")
        @Expect(cols[0].storageType, StorageType.String)
        @Expect(cols[1].name, "uuidTag_id")
        @Expect(cols[1].storageType, StorageType.String)
    }

    // F1 回归：Bool storageOverride 主键的 junction 源列应为 StorageType.`Bool`
    //（Bool 是仓颉关键字，宏层须转义为反引号形式，否则生成裸 StorageType.Bool 编译失败）
    @TestCase
    public func testJunctionSourceColBoolEscaped(): Unit {
        let mainSchema = BoolPkPostSchema()
        let mainCols = mainSchema.columns()
        @Expect(mainCols.size, 2)
        @Expect(mainCols[0].name, "id")
        @Expect(mainCols[0].storageType, StorageType.`Bool`)
        let js = BoolPkPost_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols.size, 2)
        @Expect(cols[0].name, "boolPkPost_id")
        @Expect(cols[0].storageType, StorageType.`Bool`)
        @Expect(cols[1].name, "tag_id")
        @Expect(cols[1].storageType, StorageType.Integer)
    }
}

@Test
public class RefManyStringPkTargetTest {
    @TestCase
    public func testAppendUnsavedStringPkTargetThrows(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        try {
            p.appendTags(tx, t)
            @Fail("expected exception for unsaved String-pk target")
        } catch (e: Exception) {
            @Expect(e.message.contains("has empty id"), true)
        }
    }

    @TestCase
    public func testDeleteUnsavedStringPkTargetThrows(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        try {
            p.deleteTags(tx, t)
            @Fail("expected exception for unsaved String-pk target")
        } catch (e: Exception) {
            @Expect(e.message.contains("has empty id"), true)
        }
    }

    @TestCase
    public func testAppendSavedStringPkTargetSucceeds(): Unit {
        // F1: junction 目标列类型运行时从目标实体 Schema 读取（UuidTag String-pk →
        // String 列），append 不再抛 R-I9 RefineException，String id 正常绑进 junction 表。
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        t.id = "uuid-tag-1"
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"uuid_tag_post_tags\""), true)
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedString(conn.stmt.capturedSetValues, 1), "uuid-tag-1")
    }

    @TestCase
    public func testDeleteSavedStringPkTargetSucceeds(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        t.id = "uuid-tag-1"
        p.deleteTags(tx, t)
        @Expect(conn.stmt.capturedSql.contains("DELETE FROM \"uuid_tag_post_tags\""), true)
        @Expect(conn.stmt.capturedSetValues.size, 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 42)
        @Expect(capturedString(conn.stmt.capturedSetValues, 1), "uuid-tag-1")
    }

    @TestCase
    public func testReplaceStringPkTargetSucceeds(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = UuidTagPost()
        p.id = 42
        let t = UuidTag()
        t.id = "uuid-tag-1"
        let arr = [t]
        p.replaceTags(tx, arr)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("DELETE FROM \"uuid_tag_post_tags\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("INSERT INTO \"uuid_tag_post_tags\""), true)
    }
}

// F1: String-pk 源（UuidKeyTagPost）+ String-pk 目标（UuidTag）ref_many 完整生命周期。
// 修复前 R-I9 守卫在 append 时抛 RefineException，String-pk 目标功能不可用；F1 移除守卫后
// append/count/load/clear/delete 全部走正常路径（mock 层断言 SQL 与绑定值）。
@Test
public class RefManyStringPkBothEndsTest {
    @TestCase
    public func testStringPkBothEndsLifecycle(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = UuidKeyTagPost()
        p.id = "p-1"
        let t1 = UuidTag(); t1.id = "t-1"; t1.name = "n1"
        let t2 = UuidTag(); t2.id = "t-2"; t2.name = "n2"

        // append 两个目标：源 String id 与目标 String id 分别绑定
        p.appendTags(tx, [t1, t2])
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0].contains("INSERT INTO \"uuid_key_tag_post_tags\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("INSERT INTO \"uuid_key_tag_post_tags\""), true)
        @Expect(conn.stmt.capturedSetValues.size, 4)
        @Expect(capturedString(conn.stmt.capturedSetValues, 0), "p-1")
        @Expect(capturedString(conn.stmt.capturedSetValues, 1), "t-1")
        @Expect(capturedString(conn.stmt.capturedSetValues, 2), "p-1")
        @Expect(capturedString(conn.stmt.capturedSetValues, 3), "t-2")

        // count 不抛
        conn.stmt.queryResult = MapperMockQueryResult(
            [MapperMockColumnInfo("COUNT(*)", false)], [Array<Any>(1, {i => 2})])
        @Expect(p.countTags(tx), 2)

        // load 空结果不抛（返回空列表）
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(
            [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false)], []))
        let loaded = p.loadTags(tx)
        @Expect(loaded.size, 0)

        // delete 单目标不抛
        p.deleteTags(tx, t1)
        @Expect(conn.stmt.capturedSql.contains("DELETE FROM \"uuid_key_tag_post_tags\""), true)

        // clear 不抛
        p.clearTags(tx)
        @Expect(conn.stmt.capturedSql.contains("DELETE FROM \"uuid_key_tag_post_tags\""), true)
    }
}

// F1: Bool-pk 目标 junction 目标列运行时读到 StorageType.`Bool`（storageOverride 生效），
// 验证 Bool 关键字在运行时推断路径的转义与赋值（此前目标列硬编码 Integer）。
@Test
public class RefManyBoolPkTargetTest {
    @TestCase
    public func testJunctionTargetColBoolWhenTargetPkBool(): Unit {
        let js = BoolPkTagPost_TagsJunctionSchema()
        let cols = js.columns()
        @Expect(cols.size, 2)
        @Expect(cols[0].name, "boolPkTagPost_id")
        @Expect(cols[0].storageType, StorageType.Integer)
        @Expect(cols[1].name, "boolPkTag_id")
        @Expect(cols[1].storageType, StorageType.`Bool`)
    }
}

// R-I8: Array<UInt8> 字段实体——Bytes 存储（非 ref_many）。
// 修复前 detectRelations 把 Array<UInt8> 当 ref_many（RefMany<UInt8> 引用不存在的
// UInt8Schema），Bytes 字段不可达。现在 Array<UInt8> 走 isRelationField 白名单排除，
// 按普通标量字段处理：schema 列 Bytes + 写路径绑定 Array<UInt8> + 读路径 get<Array<UInt8>>。
@Test
public class ByteBlobFieldTest {
    @TestCase
    public func testSchemaMapsDataToBytes(): Unit {
        let cols = ByteBlobEntitySchema().columns()
        @Expect(cols.size, 3)
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "name")
        @Expect(cols[2].name, "data")
        @Expect(cols[2].storageType, StorageType.Bytes)
    }

    @TestCase
    public func testColumnNamesIncludeData(): Unit {
        let cols = ByteBlobEntityColumnNames()
        @Expect(cols.size, 3)
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "name")
        @Expect(cols[2].name, "data")
    }

    @TestCase
    public func testSaveBindsArrayUInt8(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let e = ByteBlobEntity()
        e.name = "blob"
        e.data = [1, 2, 3, 254, 255]
        tx.save(e)
        @Expect(conn.stmt.capturedSql.contains("\"data\""), true)
        @Expect(conn.stmt.capturedSetValues.size, 2)
        match (conn.stmt.capturedSetValues[1]) {
            case v: Array<UInt8> =>
                @Expect(v.size, 5)
                @Expect(v[0], 1)
                @Expect(v[3], 254)
                @Expect(v[4], 255)
            case _ => @Fail("expected Array<UInt8> param for data field")
        }
    }

    @TestCase
    public func testRowMapperReadsArrayUInt8(): Unit {
        let cols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("name", false),
            MapperMockColumnInfo("data", false),
        ]
        let blob: Array<UInt8> = [9, 8, 7, 6]
        let row = Array<Any>(3, { i => if (i == 0) { 1 } else if (i == 1) { "payload" } else { blob } })
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let e = ByteBlobEntityRowMapper(result, buildColumnMap(cols, 0))
        @Expect(e.id, 1)
        @Expect(e.name, "payload")
        @Expect(e.data.size, 4)
        @Expect(e.data[0], 9)
        @Expect(e.data[3], 6)
    }

    // R-I8 回归：Array<SomeEntity> 仍是 ref_many（白名单只排除 Array<UInt8>）。
    // PostWithRel.tags（Array<Tag>）是既有 ref_many，appendTags 生成 junction INSERT
    // 即证明 Array<Tag> 未被误判为标量字段。
    @TestCase
    public func testArrayOfEntityStillRefMany(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let p = PostWithRel(); p.id = 42
        let t = Tag(); t.id = 7
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
    }
}

// ─── Tx.save/update/delete 级联接线 ───────────────────────
@Test
public class TxCascadeTest {
    @TestCase
    public func testTxSaveCascadesHasManyBackfillsFk(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let c = Comment()
        c.body = "hello"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)")
        @Expect(p.id, 42)
        @Expect(c.post_id, 42)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 42)
    }

    @TestCase
    public func testTxSaveCascadesHasOneBackfillsFk(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 7
        let tx = sqliteTx(conn)
        tx.begin()
        let u = UserWithRel()
        let pr = ProfileWithRel()
        pr.bio = "b"
        u.profile = Some(pr)
        tx.save(u)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"userWithRel\" (\"name\") VALUES (?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"profileWithRel\" (\"bio\", \"user_id\") VALUES (?, ?)")
        @Expect(u.id, 7)
        @Expect(pr.user_id, 7)
    }

    @TestCase
    public func testTxUpdateCascadesChildInsertAndUpdate(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let existing = Comment()
        existing.id = 9
        existing.body = "updated"
        let fresh = Comment()
        fresh.body = "new"
        let list = ArrayList<Comment>()
        list.add(existing)
        list.add(fresh)
        p.comments = list
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE \"postWithRel\" SET \"title\" = ?, \"user_id\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "UPDATE \"comment\" SET \"body\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)")
        @Expect(existing.post_id, 5)
        @Expect(fresh.post_id, 5)
    }

    @TestCase
    public func testTxDeleteCascadesChildrenThenParent(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("body", false), MapperMockColumnInfo("post_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "hi" } else { 5 }})])
        tx.delete(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 4)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"comment\" WHERE \"post_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"comment\" WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[3], "DELETE FROM \"postWithRel\" WHERE \"id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 5)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 9)
    }

    @TestCase
    public func testTxDeleteSoftDeleteCascadesChildren(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = SoftDeleteParent()
        p.id = 1
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("deleted_at", false), MapperMockColumnInfo("parent_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(4, {i => if (i == 0) { 2 } else if (i == 1) { "c" } else if (i == 2) { 0 } else { 1 }})])
        tx.delete(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"softDeleteChild\" WHERE \"parent_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1].contains("UPDATE \"softDeleteChild\" SET \"deleted_at\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("UPDATE \"softDeleteParent\" SET \"deleted_at\""), true)
    }

    @TestCase
    public func testTxSaveCycleNoDuplicateInsertSharedVisited(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let a = CategoryWithRel()
        let b = CategoryWithRel()
        let la = ArrayList<CategoryWithRel>()
        la.add(b)
        a.children = la
        let lb = ArrayList<CategoryWithRel>()
        lb.add(a)
        b.children = lb
        tx.save(a)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testTxSaveRefToBackfillsFkBeforeInsert(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let u = User()
        u.id = 5
        p.author = Some(u)
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, ?)")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 5)
    }

    @TestCase
    public func testCascadeRefToGhostThenSaveTargetDoesNotBackfill(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertIdQueue.add(1)   // p.id
        conn.stmt.mockLastInsertIdQueue.add(2)   // u.id
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let u = User()
        u.name = "ghost"
        p.author = Some(u)                       // u.id == 0，幽灵对象
        @Expect(p._authorModified, true)
        tx.save(p)
        @Expect(p.id, 1)
        @Expect(p.user_id, 0)                    // 幽灵对象按清空处理
        @Expect(p._authorModified, false)        // 标记已复位
        // 后存目标得 id → update 不再回填（一次性语义）
        tx.save(u)
        @Expect(u.id, 2)
        tx.update(p)
        @Expect(p.user_id, 0)                    // 不回填，user_id 保持 0
        // 重新整体赋值 → 回填
        p.author = Some(u)
        @Expect(p._authorModified, true)
        tx.update(p)
        @Expect(p.user_id, 2)
        @Expect(p._authorModified, false)
    }

    @TestCase
    public func testTxUpdateNoCascadeWhenRelsNotModified(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        p.title = "x"
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE \"postWithRel\" SET \"title\" = ?, \"user_id\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testTxSaveResetsMarkersThenUpdateDoesNotReplay(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let c = Comment()
        c.body = "hello"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        @Expect(p._commentsModified, true)
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(p._commentsModified, false)
        // 标记已复位：再次 update 不重放子列表
        conn.stmt.mockRowCount = 1
        p.title = "changed"
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[2], "UPDATE \"postWithRel\" SET \"title\" = ?, \"user_id\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testTxSaveResetsMarkersThenUpdateReplayAfterReassign(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let c = Comment()
        c.body = "hello"
        let list = ArrayList<Comment>()
        list.add(c)
        p.comments = list
        tx.save(p)
        @Expect(p._commentsModified, false)
        // 再次整体赋值 → 标记置位 → update 重放
        let c2 = Comment()
        c2.body = "world"
        let list2 = ArrayList<Comment>()
        list2.add(c)
        list2.add(c2)
        p.comments = list2
        @Expect(p._commentsModified, true)
        conn.stmt.mockRowCount = 1
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 5)
        @Expect(conn.stmt.capturedSqlHistory[3], "UPDATE \"comment\" SET \"body\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[4], "INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)")
        @Expect(p._commentsModified, false)
    }

    @TestCase
    public func testTxSaveRefManyRebuildsJunction(): Unit {
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let t1 = Tag()
        t1.id = 7
        let t2 = Tag()
        t2.id = 8
        let list = ArrayList<Tag>()
        list.add(t1)
        list.add(t2)
        p.tags = list
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 4)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[3], "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 42)
    }
}

// ─── 级联边界用例 ──────────────────────────────────────
// 覆盖设计文档第 2/4/7 节的边界：加载后未修改不级联、两个无 id 新对象互不误判、
// 空列表标记 true 的语义、三层深链、级联子对象乐观锁

@Test
public class CascadeBoundaryTest {
    @TestCase
    public func testTxUpdateLoadedEntityNoCascade(): Unit {
        // rowMapper 从库加载实体（含 ref_to include），关联字段标记必须保持 false
        let col1: ColumnInfo = MapperMockColumnInfo("id", false)
        let col2: ColumnInfo = MapperMockColumnInfo("title", false)
        let col3: ColumnInfo = MapperMockColumnInfo("user_id", false)
        let col4: ColumnInfo = MapperMockColumnInfo("post_id", false)
        let col5: ColumnInfo = MapperMockColumnInfo("author.id", false)
        let cols: Array<ColumnInfo> = [col1, col2, col3, col4, col5]
        let row = Array<Any>(5, {i => if (i == 0) { 5 } else if (i == 1) { "loaded" } else if (i == 2) { 7 } else if (i == 3) { 0 } else { 99 }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let e = PostWithRelRowMapper(result, cm)
        @Expect(e._authorModified, false)
        @Expect(e._tagsModified, false)
        @Expect(e._commentsModified, false)
        @Expect(e.author.getOrThrow().id, 99)

        // 仅加载未修改 → update 只发父 UPDATE，无 fk 改动 / 无子落库 / 无中间表重建
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()
        tx.update(e)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE \"postWithRel\" SET \"title\" = ?, \"user_id\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 5)
    }

    @TestCase
    public func testTxSaveTwoNewChildrenBothSaved(): Unit {
        // 两个不同实例的新子对象（都 id=0）不得被 visited 按 (type,id) 误判为同一对象
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        let c1 = Comment()
        c1.body = "one"
        let c2 = Comment()
        c2.body = "two"
        let list = ArrayList<Comment>()
        list.add(c1)
        list.add(c2)
        p.comments = list
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)")
        @Expect(p.id, 42)
        @Expect(c1.post_id, 42)
        @Expect(c2.post_id, 42)
        @Expect(capturedString(conn.stmt.capturedSetValues, 3), "one")
        @Expect(capturedString(conn.stmt.capturedSetValues, 5), "two")
    }

    @TestCase
    public func testTxSaveHasManyEmptyListNoChildInsert(): Unit {
        // 标记 true 且 has_many 列表为空 → save 无子对象要存（只父 INSERT）
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.comments = ArrayList<Comment>()
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, ?)")
    }

    @TestCase
    public func testTxUpdateHasManyEmptyListNoChildDelete(): Unit {
        // 标记 true 且 has_many 列表为空 → update 不删现有（不自动清库）
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        p.comments = ArrayList<Comment>()
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 1)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE \"postWithRel\" SET \"title\" = ?, \"user_id\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testTxSaveRefManyEmptyListClearsJunction(): Unit {
        // 标记 true 且 ref_many 列表为空 → save 清空中间表（DELETE 旧关联，无 INSERT）
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertId = 42
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.tags = ArrayList<Tag>()
        tx.save(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"postWithRel\" (\"title\", \"user_id\", \"post_id\") VALUES (?, ?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 42)
    }

    @TestCase
    public func testTxUpdateRefManyEmptyListClearsJunction(): Unit {
        // 标记 true 且 ref_many 列表为空 → update 清空中间表（重建为空 = 清旧关联）
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        p.tags = ArrayList<Tag>()
        tx.update(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE \"postWithRel\" SET \"title\" = ?, \"user_id\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 5)
    }

    @TestCase
    public func testTxSaveThreeLevelDeepChain(): Unit {
        // 三层嵌套：root → l2 → l3，自动递归，fk 逐层回填正确
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertIdQueue.add(10)
        conn.stmt.mockLastInsertIdQueue.add(11)
        conn.stmt.mockLastInsertIdQueue.add(12)
        let tx = sqliteTx(conn)
        tx.begin()
        let root = CategoryWithRel()
        root.name = "root"
        let l2 = CategoryWithRel()
        l2.name = "l2"
        let l3 = CategoryWithRel()
        l3.name = "l3"
        let l2List = ArrayList<CategoryWithRel>()
        l2List.add(l2)
        root.children = l2List
        let l3List = ArrayList<CategoryWithRel>()
        l3List.add(l3)
        l2.children = l3List
        tx.save(root)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[2], "INSERT INTO \"categoryWithRel\" (\"name\", \"parent_id\") VALUES (?, ?)")
        @Expect(root.id, 10)
        @Expect(l2.id, 11)
        @Expect(l3.id, 12)
        @Expect(l2.parent_id, 10)
        @Expect(l3.parent_id, 11)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 10)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 5), 11)
    }

    @TestCase
    public func testTxUpdateCascadesVersionedChildIncrementsVersion(): Unit {
        // 级联 update 子对象带乐观锁：子 UPDATE 含 version 校验并递增
        let conn = CaptureConnection()
        conn.stmt.mockRowCount = 1
        let tx = sqliteTx(conn)
        tx.begin()
        let order = VersionedOrder()
        order.id = 1
        order.name = "o"
        order.version = 1
        let item = VersionedOrderItem()
        item.id = 7
        item.name = "old"
        item.version = 1
        let list = ArrayList<VersionedOrderItem>()
        list.add(item)
        order.items = list
        tx.update(order)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "UPDATE \"versionedOrder\" SET \"name\" = ?, \"version\" = \"version\" + 1 WHERE \"id\" = ? AND \"version\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1], "UPDATE \"versionedOrderItem\" SET \"name\" = ?, \"order_id\" = ?, \"version\" = \"version\" + 1 WHERE \"id\" = ? AND \"version\" = ?")
        @Expect(order.version, 2)
        @Expect(item.version, 2)
        @Expect(item.order_id, 1)
    }

    @TestCase
    public func testTxUpdateCascadeVersionedChildConflictThrows(): Unit {
        // 级联 update 子对象乐观锁冲突：父成功、子 rowCount=0 → 抛 OptimisticLockException
        let conn = CaptureConnection()
        conn.stmt.mockRowCountQueue.add(1)
        conn.stmt.mockRowCountQueue.add(0)
        let tx = sqliteTx(conn)
        tx.begin()
        let order = VersionedOrder()
        order.id = 1
        order.version = 1
        let item = VersionedOrderItem()
        item.id = 7
        item.name = "old"
        item.version = 1
        let list = ArrayList<VersionedOrderItem>()
        list.add(item)
        order.items = list
        try {
            tx.update(order)
            @Fail("expected OptimisticLockException from cascade child update")
        } catch (e: OptimisticLockException) {
            @Expect(e.entityType, "VersionedOrderItem")
            @Expect(e.expected, 1)
            @Expect(e.actual, -1)
        }
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("versionedOrderItem"), true)
        @Expect(conn.stmt.capturedSqlHistory[2], "SELECT \"version\" FROM \"versionedOrderItem\" WHERE \"id\" = ?")
    }

    @TestCase
    public func testTxSaveCascadesNewVersionedChildInitsVersion(): Unit {
        // 级联 save 子对象（无 id）：version 0→1 初始化、父 id 回填子 fk、子 INSERT 带 version 列
        let conn = CaptureConnection()
        conn.stmt.mockLastInsertIdQueue.add(1)
        conn.stmt.mockLastInsertIdQueue.add(2)
        let tx = sqliteTx(conn)
        tx.begin()
        let order = VersionedOrder()
        order.name = "o"
        let item = VersionedOrderItem()
        item.name = "fresh"
        let list = ArrayList<VersionedOrderItem>()
        list.add(item)
        order.items = list
        tx.save(order)
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[0], "INSERT INTO \"versionedOrder\" (\"name\", \"version\") VALUES (?, ?)")
        @Expect(conn.stmt.capturedSqlHistory[1], "INSERT INTO \"versionedOrderItem\" (\"name\", \"version\", \"order_id\") VALUES (?, ?, ?)")
        @Expect(order.id, 1)
        @Expect(order.version, 1)
        @Expect(item.id, 2)
        @Expect(item.version, 1)
        @Expect(item.order_id, 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 4), 1)
    }
}

// ─── delete 钩子 abort 不删子 + physicalDelete 级联 ────────

@Test
public class TxDeleteHookAbortTest {
    @TestCase
    public func testTxDeleteHookAbortSkipsCascadeDelete(): Unit {
        let conn = CaptureConnection()
        let rf = Refine(RMockDS(), SQLiteDialect(), 0)
        let tx = Tx(conn, rf, 0)
        tx.begin()
        let p = PostWithRel()
        p.id = 5
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("body", false), MapperMockColumnInfo("post_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(3, {i => if (i == 0) { 9 } else if (i == 1) { "hi" } else { 5 }})])
        rf.hook<PostWithRel>("PostWithRel", HookKind.TxBeforeDelete) { scope: Scope<PostWithRel> =>
            scope.abort(Exception("blocked"))
        }
        try {
            tx.delete(p)
            @Fail("expected abort exception")
        } catch (e: Exception) {
            @Expect(e.message, "blocked")
        }
        @Expect(conn.stmt.capturedSqlHistory.size, 0)
    }
}

@Test
public class TxPhysicalDeleteCascadeTest {
    // F3(b) 孤儿策略固化：物理删父 + 软删子的混合策略。父 physicalDelete 时子对象
    // cascadeDelete 走子实体自身策略（软删子 → UPDATE deleted_at，行保留），
    // 父行物理删除。子行 deleted_at 置位但外键仍指向已物理删除的父——软删子保留
    // 历史（审计/恢复），属有意的孤儿语义（文档见 docs/plans/2026-08-01-cascade-save-design.md
    // 与 docs-site/guide/relations.md「级联删除」）。
    @TestCase
    public func testTxPhysicalDeleteCascadesChildren(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let p = SoftDeleteParent()
        p.id = 1
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("name", false), MapperMockColumnInfo("deleted_at", false), MapperMockColumnInfo("parent_id", false)]
        conn.stmt.queryResult = MapperMockQueryResult(cols, [Array<Any>(4, {i => if (i == 0) { 2 } else if (i == 1) { "c" } else if (i == 2) { 0 } else { 1 }})])
        tx.physicalDelete(p)
        @Expect(conn.stmt.capturedSqlHistory.size, 3)
        @Expect(conn.stmt.capturedSqlHistory[0], "SELECT * FROM \"softDeleteChild\" WHERE \"parent_id\" = ?")
        @Expect(conn.stmt.capturedSqlHistory[1].contains("UPDATE \"softDeleteChild\" SET \"deleted_at\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2], "DELETE FROM \"softDeleteParent\" WHERE \"id\" = ?")
        // 子对象只能被软删（UPDATE deleted_at=1，行保留），绝不能物理删（DELETE child 不应出现）
        for (sql in conn.stmt.capturedSqlHistory) {
            @Expect(sql.startsWith("DELETE FROM \"softDeleteChild\""), false)
        }
        // 参数序列：SELECT 用父 id=1，子 UPDATE 置 deleted_at=1 + WHERE id=2，父 DELETE WHERE id=1
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 0), 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 1), 1)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 2), 2)
        @Expect(capturedInt64(conn.stmt.capturedSetValues, 3), 1)
    }
}

// ─── I19: 宏层写路径标识符方言感知引号化 ─────────────────────
// 写路径 SQL（INSERT/UPDATE/DELETE/BATCH）通过 runtime dialect.quoteIdentifier 生成：
// SQLite 双引号、MySQL 反引号、PG 双引号，驼峰实体在 PG 可读可写。
// 修复前：宏层把裸表名/列名烘焙进编译期字符串，PG 未加引号标识符折叠小写，
// 无法命中引号原样建出的驼峰表/列。

@Test
public class WritePathDialectQuotingTest {
    @TestCase
    public func testSaveSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u = CamelUser()
        u.displayName = "Alice"
        tx.save(u)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"camelUser\" (\"displayName\") VALUES (?)")
    }

    @TestCase
    public func testSaveMySQLQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(MySQLDialect())
        let u = CamelUser()
        u.displayName = "Alice"
        tx.save(u)
        @Expect(conn.stmt.capturedSql, "INSERT INTO `camelUser` (`displayName`) VALUES (?)")
    }

    @TestCase
    public func testSavePostgresQuotesIdentifiers(): Unit {
        // ManualIdPost 客户端主键：PG save 不触发 RETURNING，可断言整条 INSERT
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = ManualIdPost()
        p.id = 1
        p.title = "T"
        tx.save(p)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"manualIdPost\" (\"id\", \"title\") VALUES (?, ?)")
    }

    @TestCase
    public func testSavePostgresAutoPkReturningQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        conn.stmt.queryResult = RowQueryResult(7)
        let p = PgPost()
        p.title = "T"
        p.content = "C"
        tx.save(p)
        @Expect(conn.stmt.capturedSql.contains("INSERT INTO \"pgpost\" (\"title\", \"content\") VALUES (?, ?)"), true)
        @Expect(conn.stmt.capturedSql.contains("RETURNING"), true)
        @Expect(p.id, 7)
    }

    @TestCase
    public func testSavePostgresCamelCaseAutoPkReturningQuotes(): Unit {
        // I20：驼峰自增主键列 postId 的 RETURNING 必须引号化（未引号 PG 折叠 postid）
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        conn.stmt.queryResult = RowQueryResult(9)
        let p = CamelAutoPkPost()
        p.title = "T"
        tx.save(p)
        @Expect(conn.stmt.capturedSql.contains("RETURNING \"postId\""), true)
        @Expect(p.postId, 9)
    }

    @TestCase
    public func testBatchSaveSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u1 = CamelUser(); u1.displayName = "A"
        let u2 = CamelUser(); u2.displayName = "B"
        tx.batchSave([u1, u2])
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"camelUser\" (\"displayName\") VALUES (?), (?)")
    }

    @TestCase
    public func testBatchSaveMySQLQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(MySQLDialect())
        let u1 = CamelUser(); u1.displayName = "A"
        let u2 = CamelUser(); u2.displayName = "B"
        tx.batchSave([u1, u2])
        @Expect(conn.stmt.capturedSql, "INSERT INTO `camelUser` (`displayName`) VALUES (?), (?)")
    }

    @TestCase
    public func testUpdateSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u = CamelUser()
        u.id = 1
        u.displayName = "Updated"
        tx.update(u)
        @Expect(conn.stmt.capturedSql, "UPDATE \"camelUser\" SET \"displayName\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testUpdateMySQLQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(MySQLDialect())
        let u = CamelUser()
        u.id = 1
        u.displayName = "Updated"
        tx.update(u)
        @Expect(conn.stmt.capturedSql, "UPDATE `camelUser` SET `displayName` = ? WHERE `id` = ?")
    }

    @TestCase
    public func testUpdatePostgresQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let u = CamelUser()
        u.id = 1
        u.displayName = "Updated"
        tx.update(u)
        @Expect(conn.stmt.capturedSql, "UPDATE \"camelUser\" SET \"displayName\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testUpdateCompoundPkQuotesIdentifiersSQLite(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let ot = OrderItemTag()
        ot.order_id = 1
        ot.item_id = 2
        ot.quantity = 5
        tx.update(ot)
        @Expect(conn.stmt.capturedSql, "UPDATE \"orderItemTag\" SET \"quantity\" = ? WHERE \"order_id\" = ? AND \"item_id\" = ?")
    }

    @TestCase
    public func testUpdateOnlyPkAndVersionNoLeadingCommaSQLite(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        conn.stmt.mockRowCount = 1
        let e = VersionedOnly()
        e.id = 1
        e.version = 1
        tx.update(e)
        // 回归：setParts 为空时 version 自增仍须是合法 SET 子句（无前导逗号）
        @Expect(conn.stmt.capturedSql, "UPDATE \"versionedOnly\" SET \"version\" = \"version\" + 1 WHERE \"id\" = ? AND \"version\" = ?")
        @Expect(e.version, 2)
    }

    @TestCase
    public func testUpdateOnlyPkAndVersionNoLeadingCommaPostgres(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        conn.stmt.mockRowCount = 1
        let e = VersionedOnly()
        e.id = 1
        e.version = 1
        tx.update(e)
        @Expect(conn.stmt.capturedSql, "UPDATE \"versionedOnly\" SET \"version\" = \"version\" + 1 WHERE \"id\" = ? AND \"version\" = ?")
        @Expect(e.version, 2)
    }

    @TestCase
    public func testDeleteSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u = CamelUser()
        u.id = 1
        tx.delete(u)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"camelUser\" WHERE \"id\" = ?")
    }

    @TestCase
    public func testDeleteCompoundPkSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let ot = OrderItemTag()
        ot.order_id = 1
        ot.item_id = 2
        tx.delete(ot)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"orderItemTag\" WHERE \"order_id\" = ? AND \"item_id\" = ?")
    }

    @TestCase
    public func testSoftDeleteSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u = SoftUser()
        u.id = 1
        tx.delete(u)
        @Expect(conn.stmt.capturedSql, "UPDATE \"softUser\" SET \"deleted_at\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testSoftDeletePostgresQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let u = SoftUser()
        u.id = 1
        tx.delete(u)
        @Expect(conn.stmt.capturedSql, "UPDATE \"softUser\" SET \"deleted_at\" = ? WHERE \"id\" = ?")
    }

    @TestCase
    public func testBatchUpdateSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let u1 = CamelUser(); u1.id = 1; u1.displayName = "A"
        let u2 = CamelUser(); u2.id = 2; u2.displayName = "B"
        tx.batchUpdate([u1, u2])
        @Expect(conn.stmt.capturedSql, "UPDATE \"camelUser\" SET \"displayName\" = CASE \"id\" WHEN ? THEN ? WHEN ? THEN ? END WHERE \"id\" IN (?, ?)")
    }

    @TestCase
    public func testBatchUpdateMySQLQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(MySQLDialect())
        let u1 = CamelUser(); u1.id = 1; u1.displayName = "A"
        let u2 = CamelUser(); u2.id = 2; u2.displayName = "B"
        tx.batchUpdate([u1, u2])
        @Expect(conn.stmt.capturedSql, "UPDATE `camelUser` SET `displayName` = CASE `id` WHEN ? THEN ? WHEN ? THEN ? END WHERE `id` IN (?, ?)")
    }

    @TestCase
    public func testBatchUpdatePostgresQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let u1 = CamelUser(); u1.id = 1; u1.displayName = "A"
        let u2 = CamelUser(); u2.id = 2; u2.displayName = "B"
        tx.batchUpdate([u1, u2])
        // PG 批量更新对 String 列追加 ::TEXT 类型转换（与既有 PG 行为一致）
        @Expect(conn.stmt.capturedSql, "UPDATE \"camelUser\" SET \"displayName\" = CASE \"id\" WHEN ? THEN ?::TEXT WHEN ? THEN ?::TEXT END WHERE \"id\" IN (?, ?)")
    }

    @TestCase
    public func testBatchUpdatePostgresCastSuffixQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p1 = PgPost(); p1.id = 1; p1.title = "A"; p1.content = "X"
        let p2 = PgPost(); p2.id = 2; p2.title = "B"; p2.content = "Y"
        tx.batchUpdate([p1, p2])
        @Expect(conn.stmt.capturedSql, "UPDATE \"pgpost\" SET \"title\" = CASE \"id\" WHEN ? THEN ?::TEXT WHEN ? THEN ?::TEXT END, \"content\" = CASE \"id\" WHEN ? THEN ?::TEXT WHEN ? THEN ?::TEXT END WHERE \"id\" IN (?, ?)")
    }

    @TestCase
    public func testBatchUpdateCompoundPkSQLiteQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let ot1 = OrderItemTag(); ot1.order_id = 1; ot1.item_id = 2; ot1.quantity = 5
        let ot2 = OrderItemTag(); ot2.order_id = 3; ot2.item_id = 4; ot2.quantity = 6
        tx.batchUpdate([ot1, ot2])
        @Expect(conn.stmt.capturedSql, "UPDATE \"orderItemTag\" SET \"quantity\" = CASE WHEN \"order_id\" = ? AND \"item_id\" = ? THEN ? WHEN \"order_id\" = ? AND \"item_id\" = ? THEN ? END WHERE (\"order_id\", \"item_id\") IN ((?, ?), (?, ?))")
    }

    // ─── I21: ref_many junction 写路径标识符引号化 ─────────────
    // junction SQL（INSERT/DELETE/LOAD/COUNT）的 via 表名、源列 <源表>_id、目标列
    // <目标类>_id、目标表名均经 tx.getDialect().quoteIdentifier 运行时引号化，
    // 与批量装配读路径（assembleRefMany）对齐。PostWithRel→Tag via post_tags。

    @TestCase
    public func testAppendTagsQuotesJunctionIdentifiersSQLite(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let p = PostWithRel(); p.id = 42
        let t = Tag(); t.id = 7
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testAppendTagsQuotesJunctionIdentifiersPostgres(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = PostWithRel(); p.id = 42
        let t = Tag(); t.id = 7
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"post_tags\" (\"postWithRel_id\", \"tag_id\") VALUES (?, ?)")
    }

    @TestCase
    public func testDeleteTagsQuotesJunctionIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = PostWithRel(); p.id = 42
        let t = Tag(); t.id = 7
        p.deleteTags(tx, t)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ? AND \"tag_id\" = ?")
    }

    @TestCase
    public func testClearTagsQuotesJunctionIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = PostWithRel(); p.id = 42
        p.clearTags(tx)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
    }

    @TestCase
    public func testCountTagsQuotesJunctionIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        conn.stmt.queryResult = MapperMockQueryResult([MapperMockColumnInfo("COUNT(*)", false)], [Array<Any>(1, {i => 3})])
        let p = PostWithRel(); p.id = 42
        let n = p.countTags(tx)
        @Expect(n, 3)
        @Expect(conn.stmt.capturedSql, "SELECT COUNT(*) FROM \"post_tags\" WHERE \"postWithRel_id\" = ?")
    }

    @TestCase
    public func testLoadTagsQuotesJunctionIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = PostWithRel(); p.id = 42
        p.loadTags(tx)
        @Expect(conn.stmt.capturedSql, "SELECT \"tag\".* FROM \"tag\" JOIN \"post_tags\" ON \"tag\".\"id\" = \"post_tags\".\"tag_id\" WHERE \"post_tags\".\"postWithRel_id\" = ?")
    }

    @TestCase
    public func testCamelViaPostJunctionQuotesIdentifiers(): Unit {
        // I21 驼峰 via 表名 + 驼峰源列（camelViaPostTags / camelViaPost_id）
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = CamelViaPost(); p.id = 42
        let t = Tag(); t.id = 7
        p.appendTags(tx, t)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"camelViaPostTags\" (\"camelViaPost_id\", \"tag_id\") VALUES (?, ?)")
    }
}

// ─── R-I6: 管理方法 SQL 标识符引号化 ────────────────────
// ref_to/has_many/has_one 的管理方法（loadX/clearX/setX/removeX）SQL 的
// 表名（TargetSchema().tableName()）、id、r.by fk 列全部经 tx.getDialect().quoteIdentifier
// 运行时引号化（与 I21 junction 引号化对齐）。修复前裸标识符在 PG 下折叠小写，
// @Table["CamelCase"] 表名或驼峰 fk 无法命中。
@Test
public class ManagementSQLQuotingTest {
    // ref_to：CamelPost.authorProfile → CamelUser（表 camelUser），fk authorId
    @TestCase
    public func testRefToLoadQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = CamelPost()
        p.id = 42
        p.authorId = 7
        p.loadAuthorProfile(tx)
        @Expect(conn.stmt.capturedSql, "SELECT * FROM \"camelUser\" WHERE \"id\" = ?")
    }

    @TestCase
    public func testHasManyLoadQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = CamelPostWithRel()
        p.id = 42
        p.loadComments(tx)
        @Expect(conn.stmt.capturedSql, "SELECT * FROM \"camelComment\" WHERE \"camelPostId\" = ?")
    }

    @TestCase
    public func testHasManyClearQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = CamelPostWithRel()
        p.id = 42
        p.clearComments(tx)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"camelComment\" WHERE \"camelPostId\" = ?")
    }

    @TestCase
    public func testHasOneLoadQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = CamelPostWithRel()
        p.id = 42
        p.loadProfile(tx)
        @Expect(conn.stmt.capturedSql, "SELECT * FROM \"camelProfile\" WHERE \"camelPostId\" = ?")
    }

    @TestCase
    public func testHasOneRemoveQuotesIdentifiers(): Unit {
        let (conn, tx) = makeTestTx(PostgreSQLDialect())
        let p = CamelPostWithRel()
        p.id = 42
        p.removeProfile(tx)
        @Expect(conn.stmt.capturedSql, "DELETE FROM \"camelProfile\" WHERE \"camelPostId\" = ?")
    }

    // ref_to 在 SQLite/MySQL 下也用各自方言引号化
    @TestCase
    public func testRefToLoadQuotesIdentifiersSQLite(): Unit {
        let (conn, tx) = makeTestTx(SQLiteDialect())
        let p = CamelPost()
        p.id = 42
        p.authorId = 7
        p.loadAuthorProfile(tx)
        @Expect(conn.stmt.capturedSql, "SELECT * FROM \"camelUser\" WHERE \"id\" = ?")
    }

    @TestCase
    public func testRefToLoadQuotesIdentifiersMySQL(): Unit {
        let (conn, tx) = makeTestTx(MySQLDialect())
        let p = CamelPost()
        p.id = 42
        p.authorId = 7
        p.loadAuthorProfile(tx)
        @Expect(conn.stmt.capturedSql, "SELECT * FROM `camelUser` WHERE `id` = ?")
    }
}

// ─── C2: include 预加载基于字段子集装配（缺列不抛异常/丢行） ──

@Test
public class C2IncludePreloadTest {
    @TestCase
    public func testRefToIncludeDefaultAllColumns(): Unit {
        // Task 3 批量协议：主查询 + 批量查询两次，String-pk 目标按 fk 回填全列
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let mainCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "nice" } else { "p1" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let postCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
            MapperMockColumnInfo("content", false),
        ]
        let postRow = Array<Any>(3, {i =>
            if (i == 0) { "p1" } else if (i == 1) { "First" } else { "Hello" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(postCols, [postRow]))
        let q = UuidRefComment.query().include(UuidRefCommentRel.post).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].post.isSome(), true)
        let post = entities[0].post.getOrThrow()
        @Expect(post.id, "p1")
        @Expect(post.title, "First")
        @Expect(post.content, "Hello")
    }

    @TestCase
    public func testRefToIncludeSubsetFieldsNoThrow(): Unit {
        // Task 3 批量协议：include(rel, fields) 字段子集 → 批量查询只选子集列，
        // 缺列字段保持默认值（content 缺列 → ""），不缺行不抛异常
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let mainCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "nice" } else { "p1" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let postCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let postRow = Array<Any>(2, {i => if (i == 0) { "p1" } else { "First" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(postCols, [postRow]))
        let rel = RefTo<UuidPost>("post", Col<Any>("post_id"),
            [Col<Any>("id"), Col<Any>("title")], "uuidPost",
            UuidRefCommentRel.postMapper, UuidRefCommentRel.postSetter,
            { e: Any => (e as UuidRefComment).getOrThrow().post_id }, dummyTargetIdExtractor)
        let q = UuidRefComment.query().include(rel, [Col<Any>("id"), Col<Any>("title")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        let post = entities[0].post.getOrThrow()
        @Expect(post.id, "p1")
        @Expect(post.title, "First")
        @Expect(post.content, "")
        // 批量查询按字段子集 SELECT（只含 id/title）
        @Expect(conn.stmt.capturedSqlHistory[1].contains("SELECT \"id\", \"title\" FROM \"uuidPost\""), true)
    }

    @TestCase
    public func testRefToIncludeNullTargetKeepsRow(): Unit {
        // Task 3 批量协议：fk 指向已删除目标 → 批量查询空结果，主实体保留、目标不挂载
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let mainCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let mainRow = Array<Any>(3, {i =>
            if (i == 0) { 5 } else if (i == 1) { "orphan" } else { "nope" }
        })
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let postCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(postCols, []))
        let rel = RefTo<UuidPost>("post", Col<Any>("post_id"),
            [Col<Any>("id"), Col<Any>("title")], "uuidPost",
            UuidRefCommentRel.postMapper, UuidRefCommentRel.postSetter,
            { e: Any => (e as UuidRefComment).getOrThrow().post_id }, dummyTargetIdExtractor)
        let q = UuidRefComment.query().include(rel, [Col<Any>("id"), Col<Any>("title")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        @Expect(entities[0].id, 5)
        @Expect(entities[0].post.isNone(), true)
    }

    @TestCase
    public func testHasManyIncludeSubsetFieldsNoThrow(): Unit {
        // Task 4 批量协议：主查询无 JOIN 列；批量查询按 fk（post_id）IN 主实体 id 取回，
        // SELECT 强制 fk 列 + 子集列并集，RowMapper 对未选字段保持宽容（不抛异常）。
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let mainCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRow = Array<Any>(2, {i => if (i == 0) { 5 } else { "post" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let batchCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("body", false),
            MapperMockColumnInfo("post_id", false),
        ]
        let batchRows = [
            Array<Any>(3, {i => if (i == 0) { "c1" } else if (i == 1) { "first" } else { 5 }}),
            Array<Any>(3, {i => if (i == 0) { "c2" } else if (i == 1) { "second" } else { 5 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let rel = HasMany<UuidComment>("comments", "post_id",
            [Col<Any>("id"), Col<Any>("body")], "uuidComment",
            UuidCommentRowMapper, UuidPostWithRelRel.commentsSetter, dummyTargetIdExtractor)
        let q = UuidPostWithRel.query().include(rel, [Col<Any>("id"), Col<Any>("body")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        let cs = entities[0].comments
        @Expect(cs.size, 2)
        @Expect(cs[0].id, "c1")
        @Expect(cs[0].body, "first")
        @Expect(cs[0].post_id, 5)
        @Expect(cs[1].id, "c2")
        @Expect(cs[1].body, "second")
        // 批量查询必须强制选中 fk 列（子集未声明也选中），且 fk 是分组键
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("SELECT \"id\", \"post_id\", \"body\" FROM \"uuidComment\""), true)
    }

    // Task 5 批量协议：ref_many 主查询无 JOIN 列；junction 批量查询按中间表源 id IN
    // 主实体 id 取回，SELECT 强制目标主键 id + 中间表源 id 分组键 + 字段子集并集，
    // RowMapper 对未选字段保持宽容（不抛异常）。目标是 String-pk 的 UuidTag。
    @TestCase
    public func testRefManyIncludeSubsetFieldsNoThrow(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let mainCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("title", false),
        ]
        let mainRow = Array<Any>(2, {i => if (i == 0) { 3 } else { "post1" }})
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(mainCols, [mainRow]))
        let batchCols: Array<ColumnInfo> = [
            MapperMockColumnInfo("id", false),
            MapperMockColumnInfo("uuidTagPost_id", false),
        ]
        let batchRows = [
            Array<Any>(2, {i => if (i == 0) { "t1" } else { 3 }}),
            Array<Any>(2, {i => if (i == 0) { "t2" } else { 3 }}),
        ]
        conn.stmt.queryResultQueue.add(MapperMockQueryResult(batchCols, batchRows))
        let rel = RefMany<UuidTag>("tags", "uuid_tag_post_tags",
            [Col<Any>("id")], "uuidTag",
            UuidTagRowMapper, UuidTagPostRel.tagsSetter, "uuidTag_id", dummyTargetIdExtractor)
        let q = UuidTagPost.query().include(rel, [Col<Any>("id")]).using(tx)
        let entities = q.all()
        @Expect(entities.size, 1)
        let ts = entities[0].tags
        @Expect(ts.size, 2)
        @Expect(ts[0].id, "t1")
        @Expect(ts[0].name, "")
        @Expect(ts[1].id, "t2")
        // junction 批量查询：强制目标主键 id + 中间表源 id 分组键，未选 name 列
        @Expect(conn.stmt.capturedSqlHistory.size, 2)
        @Expect(conn.stmt.capturedSqlHistory[1].contains(
            "SELECT \"uuidTag\".\"id\", \"uuid_tag_post_tags\".\"uuidTagPost_id\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("\"uuid_tag_post_tags\".\"uuidTag_id\" = \"uuidTag\".\"id\""), true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("\"uuid_tag_post_tags\".\"uuidTagPost_id\" IN (?)"), true)
    }

    @TestCase
    public func testRowMapperToleratesMissingColumns(): Unit {
        // 直接验证生成的 RowMapper 对字段子集宽容：缺列不抛异常、选中填充、未选中默认
        let cols: Array<ColumnInfo> = [MapperMockColumnInfo("id", false), MapperMockColumnInfo("email", false)]
        let row = Array<Any>(2, {i => if (i == 0) { 99 } else { "bob@x.com" }})
        let result = MapperMockQueryResult(cols, [row])
        result.next()
        let cm = buildColumnMap(cols)
        let u = UserRowMapper(result, cm)
        @Expect(u.id, 99)
        @Expect(u.email, "bob@x.com")
        @Expect(u.name, "")
    }
}

private func capturedInt64(arr: ArrayList<Any>, index: Int64): Int64 {
    match (arr[index]) {
        case v: Int64 => v
        case _ => throw Exception("param " + index.toString() + " is not Int64")
    }
}

private func capturedString(arr: ArrayList<Any>, index: Int64): String {
    match (arr[index]) {
        case v: String => v
        case _ => throw Exception("param " + index.toString() + " is not String")
    }
}

private func containsInt(arr: ArrayList<Any>, target: Int64): Bool {
    for (i in 0..arr.size) {
        match (arr[i]) {
            case v: Int64 => if (v == target) { return true }
            case _ => ()
        }
    }
    false
}

// I11 回归：has_many addX / has_one setX 的持久化语义
// - addX：子对象已有 id → update（回填 fk），无 id → save（INSERT），不再无条件 INSERT 导致主键冲突
// - setX：先解除旧关联（与 removeProfile 一致，DELETE 旧子对象），再按 id 区分 save/update
@Test
public class RelationMutationTest {
    @TestCase
    public func testAddCommentsNewChildInserts(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let post = PostWithRel()
        post.id = 1
        let c = Comment()
        c.body = "first"
        post.addComments(tx, c)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"comment\" (\"body\", \"post_id\") VALUES (?, ?)")
        @Expect(c.post_id, 1)
    }

    @TestCase
    public func testAddCommentsPersistedChildUpdates(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let post = PostWithRel()
        post.id = 1
        let c = Comment()
        c.id = 5
        c.body = "re-parent"
        post.addComments(tx, c)
        @Expect(conn.stmt.capturedSql, "UPDATE \"comment\" SET \"body\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
        @Expect(c.post_id, 1)
    }

    @TestCase
    public func testSetProfileNewChildInserts(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let user = UserWithRel()
        user.id = 1
        let p = ProfileWithRel()
        p.bio = "fresh"
        user.setProfile(tx, p)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"profileWithRel\" (\"bio\", \"user_id\") VALUES (?, ?)")
        @Expect(p.user_id, 1)
    }

    // 旧 profile 已存在且新 profile 是不同持久化行：先 DELETE 旧子对象再 update 新子对象
    @TestCase
    public func testSetProfileClearsOldThenUpdates(): Unit {
        let conn = CaptureConnection()
        conn.stmt.queryResult = profileResult(5, "old", 1)
        let tx = sqliteTx(conn)
        tx.begin()
        let user = UserWithRel()
        user.id = 1
        let p = ProfileWithRel()
        p.id = 9
        p.bio = "new"
        user.setProfile(tx, p)
        @Expect(conn.stmt.capturedSqlHistory.size >= 3, true)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("DELETE FROM \"profileWithRel\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("UPDATE \"profileWithRel\""), true)
        @Expect(p.user_id, 1)
    }

    // 重置同一个持久化 profile：不得 DELETE（避免删除后 update 命中 0 行丢数据）
    @TestCase
    public func testSetProfileSameChildNoDelete(): Unit {
        let conn = CaptureConnection()
        conn.stmt.queryResult = profileResult(5, "old", 1)
        let tx = sqliteTx(conn)
        tx.begin()
        let user = UserWithRel()
        user.id = 1
        let p = ProfileWithRel()
        p.id = 5
        p.bio = "edited"
        user.setProfile(tx, p)
        for (s in conn.stmt.capturedSqlHistory) {
            @Expect(s.contains("DELETE"), false)
        }
        @Expect(conn.stmt.capturedSqlHistory[1].contains("UPDATE \"profileWithRel\""), true)
        @Expect(p.user_id, 1)
    }

    // 旧 profile 已存在而新 profile 是新行：先 DELETE 旧子对象再 INSERT 新子对象
    @TestCase
    public func testSetProfileNewChildWithOldClears(): Unit {
        let conn = CaptureConnection()
        conn.stmt.queryResult = profileResult(5, "old", 1)
        let tx = sqliteTx(conn)
        tx.begin()
        let user = UserWithRel()
        user.id = 1
        let p = ProfileWithRel()
        p.bio = "replacement"
        user.setProfile(tx, p)
        @Expect(conn.stmt.capturedSqlHistory[1].contains("DELETE FROM \"profileWithRel\""), true)
        @Expect(conn.stmt.capturedSqlHistory[2].contains("INSERT INTO \"profileWithRel\""), true)
        @Expect(p.user_id, 1)
    }

    // String 主键子对象（UuidComment.id: String）：id 为空 → INSERT，覆盖 addX 的 String 分支
    @TestCase
    public func testAddCommentsStringPkNewChildInserts(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let post = UuidPostWithRel()
        post.id = 1
        let c = UuidComment()
        c.body = "uuid-new"
        post.addComments(tx, c)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"uuidComment\" (\"id\", \"body\", \"post_id\") VALUES (?, ?, ?)")
        @Expect(c.post_id, 1)
    }

    // String 主键子对象已持久化（id 非空）→ UPDATE，覆盖 addX 的 String 分支
    @TestCase
    public func testAddCommentsStringPkPersistedChildUpdates(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let post = UuidPostWithRel()
        post.id = 1
        let c = UuidComment()
        c.id = "c-5"
        c.body = "uuid-reparent"
        post.addComments(tx, c)
        @Expect(conn.stmt.capturedSql, "UPDATE \"uuidComment\" SET \"body\" = ?, \"post_id\" = ? WHERE \"id\" = ?")
        @Expect(c.post_id, 1)
    }
}

// I10 文档同步验证：文档 3.2.1/3.3/4.3.2 使用的 `@Rel[has_many, target: X, by: "y"]`、
// `@Ref[ref_to, target: X, by: "y", fields: [...]]` 具名参数语法必须真实可用，
// 且 has_many/ref_many 字段用 ArrayList（文档曾示例 Option<List<...>>，实现不支持 List）
@Refine
public class DocRelComment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
public class DocRelUser {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
public class DocRelPost {
    var id: Int64 = 0
    var title: String = ""
    var authorId: Int64 = 0

    @Rel[has_many, target: DocRelComment, by: "post_id"]
    var comments: ArrayList<DocRelComment> = ArrayList<DocRelComment>()

    @Ref[ref_to, target: DocRelUser, by: "authorId", fields: ["id", "name"]]
    var author: Option<DocRelUser> = None
}

@Refine
public class DocRelAuthor {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
public class DocRelBook {
    var id: Int64 = 0
    var title: String = ""

    @Ref[ref_many, target: DocRelAuthor, via: "doc_rel_book_authors", fields: ["id", "name"]]
    var authors: ArrayList<DocRelAuthor> = ArrayList<DocRelAuthor>()
}

@Test
public class DocSyncSyntaxTest {
    @TestCase
    public func testDocSyntaxRelsResolve(): Unit {
        @Expect(DocRelPostRel.comments.name, "comments")
        @Expect(DocRelPostRel.author.name, "author")
        @Expect(DocRelBookRel.authors.name, "authors")
        // fields: ["id", "name"] 具名参数必须解析进描述符（有自定义 fields 才用 genFieldCols）
        @Expect(DocRelPostRel.author.fields.size, 2)
        @Expect(DocRelPostRel.author.fields[0].name, "id")
        @Expect(DocRelPostRel.author.fields[1].name, "name")
        @Expect(DocRelBookRel.authors.fields.size, 2)
        @Expect(DocRelBookRel.authors.fields[0].name, "id")
        @Expect(DocRelBookRel.authors.fields[1].name, "name")
        // 未指定 fields 的 has_many 默认解析为全部列（经 <Target>ColumnNames()）
        @Expect(DocRelPostRel.comments.fields.size, 3)
        @Expect(DocRelPostRel.comments.fields[0].name, "id")
    }

    @TestCase
    public func testDocSyntaxHasManyMethodsWork(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let post = DocRelPost()
        post.id = 1
        let c = DocRelComment()
        c.body = "doc"
        post.addComments(tx, c)
        @Expect(conn.stmt.capturedSql, "INSERT INTO \"docRelComment\" (\"body\", \"post_id\") VALUES (?, ?)")
        @Expect(c.post_id, 1)
    }

    // 验证 4.4 文档示例「预加载 + 覆盖字段」的真实可编译写法：
    // include(rel, fields) 双参重载（setFields 链式返回 Relation 基类，不能直接传给 include(IRelation)）。
    // Task 2 后主查询不再生成 include JOIN，断言同步改为「无 LEFT JOIN」。
    @TestCase
    public func testDocSyntaxIncludeTwoArg(): Unit {
        let conn = CaptureConnection()
        let tx = sqliteTx(conn)
        tx.begin()
        let q = DocRelBook.query()
            .select([Column("id")])
            .from("docRelBook")
            .include(DocRelBookRel.authors, [Col<Any>("name")])
            .using(tx)
        let _ = q.all()
        @Expect(conn.stmt.capturedSql.contains("LEFT JOIN"), false)
    }
}

// Task 3: 表名转换已生效——snake 策略下表名走 applyTableNameStrategy → snake_blog_post。
// Task 4: 列名烘焙点统一切到 f.columnName——ColumnDef/ColumnNames/Col DSL 均输出
// snake_case 列名（"user_name"），且三处必须一致（rowMapper 键与 SELECT 列同源）。
// 非法 strategy（"kebab"/"SNAKE"）与 `naming:` 缺值在宏展开期抛编译错误，
// 无法在 unittest 运行时断言（见宏文件注释），由合法值覆盖：
//   - SnakeBlogPostSchema：显式 snake（Task 3 阶段表名已转 snake_case）
//   - ExplicitNonePostSchema：显式 none = 默认行为
//   - EmptyAttrPostSchema：@Refine[] 空 attr = 默认行为
@Test
public class SnakeNamingTest {
    @TestCase
    public func testNamingAttrMacroOverloadExpands(): Unit {
        let schema = SnakeBlogPostSchema()
        @Expect(schema.tableName(), "snake_blog_post")
        let cols = schema.columns()
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "user_name")
        @Expect(SnakeBlogPostColumnNames()[1].name, "user_name")
        @Expect(SnakeBlogPostCols().userName.name, "user_name")
    }

    @TestCase
    public func testExplicitNoneMatchesDefault(): Unit {
        let schema = ExplicitNonePostSchema()
        @Expect(schema.tableName(), "explicitNonePost")
        let cols = schema.columns()
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "title")
    }

    @TestCase
    public func testEmptyAttrMatchesDefault(): Unit {
        let schema = EmptyAttrPostSchema()
        @Expect(schema.tableName(), "emptyAttrPost")
        let cols = schema.columns()
        @Expect(cols[0].name, "id")
        @Expect(cols[1].name, "title")
    }
}

private func profileResult(id: Int64, bio: String, uid: Int64): QueryResult {
    let cols: Array<ColumnInfo> = [
        MapperMockColumnInfo("id", false),
        MapperMockColumnInfo("bio", false),
        MapperMockColumnInfo("user_id", false)
    ]
    let row: Array<Any> = [id, bio, uid]
    let rows: Array<Array<Any>> = [row]
    MapperMockQueryResult(cols, rows)
}
