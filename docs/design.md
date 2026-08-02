# Refine ORM 设计文档（v0.2）

> **Refine** —— 仓颉语言的编译期类型安全、AI 友好的 ORM 框架。
> *取“精炼、清晰”之意，同时暗含 `Ref`（引用）关系模型。*

---

## 1. 背景与设计目标

### 1.1 现有 ORM 的痛点

| 痛点 | 传统方案（如 GORM、EntGo） | 对 AI 编程的影响 |
| :--- | :--- | :--- |
| **隐式字符串标签** | 依赖 `gorm:"column:user_name"` 运行时解析 | AI 需推测蛇形/驼峰转换，易出错 |
| **关联语义模糊** | `belongsTo` 隐含反向写能力，易破坏聚合边界 | AI 可能生成跨聚合修改的危险代码 |
| **过度查询** | 默认 `SELECT *`，无法按需加载字段 | AI 难以推断最优字段集 |
| **类型映射局限** | 缺乏编译期自定义类型映射 | AI 无法理解复杂业务类型的持久化逻辑 |

### 1.2 Refine 的设计目标

1. **编译期零反射**：所有 SQL 与映射代码由宏生成，保证类型安全与极致性能。
2. **清晰的关联语义**：用 `hasOne`/`hasMany`（拥有）与 `ref_to`/`ref_many`（引用）严格区分读写边界。
3. **原生按需加载**：在模型定义中声明引用字段集，杜绝冗余数据传输。
4. **可扩展的类型系统**：通过 `StorageType` 枚举与 `TypeAdapter` 接口，支持 JSON、字节数组等自定义类型映射。
5. **跨数据库方言**：逻辑存储类型自动适配不同数据库（MySQL、PostgreSQL、SQLite 等）。
6. **AI 友好**：所有 API 均为强类型、无歧义，可直接被 AI 理解和生成。

---

## 2. 核心术语与关系模型

Refine 将实体间关系精确划分为两个正交维度：**性质（拥有/引用）** × **数量（一/多）**。

| 术语 | 关系 | 语义 | 是否可修改关联对象 | 典型场景 |
| :--- | :--- | :--- | :--- | :--- |
| **`#hasOne`** | 1:1 | **拥有**一个附属实体，控制其生命周期 | 是 | `User` → `Profile` |
| **`#hasMany`** | 1:M | **拥有**多个附属实体 | 是 | `User` → `Post` |
| **`#ref_to`** | M:1 | **引用**另一个聚合根，仅用于数据组装 | 否 | `Post` → `User`（作者） |
| **`#ref_many`** | M:N | **引用**多个聚合根，通常经中间表 | 否 | `Post` → `Tag` |

**设计约束**：
- `#has*` 生成的 API 包含增删改关联对象的方法。
- `#ref*` **仅生成读取方法**，从 API 层面禁止跨聚合修改。

---

## 3. 宏设计

### 3.1 实体宏 `@Refine`

标记一个类为持久化模型，编译期生成：
- 基础 CRUD 方法
- 类型安全的查询构建器
- Schema 迁移代码（可选）

```cangjie
@Refine
class User {
    var id: Int64 = 0
    var name: String = ""
    var age: Option<Int32> = None
}
```

### 3.2 字段宏 `@Rel` 与 `@Ref`

#### 3.2.1 `@Rel` —— 拥有关系

```cangjie
// 语法
@Rel[has_one,  target: TargetModel, by: "foreignKeyField"]
@Rel[has_many, target: TargetModel, by: "foreignKeyField"]
```

关联字段的类型约定：

- 单值关系（`has_one` / `ref_to`）：字段声明为 `Option<T>`，如 `var profile: Option<Profile> = None`。
- 集合关系（`has_many` / `ref_many`）：字段声明为 `ArrayList<T>`，如 `var posts: ArrayList<Post> = ArrayList<Post>()`。
- **不支持 `List` / `Option<List<...>>`**：宏只识别 `ArrayList` / `Array` / `Option` 类型前缀，`List` 接口类型不被识别为关联。

#### 3.2.2 `@Ref` —— 引用关系（支持字段选择）

```cangjie
// 语法
@Ref[ref_to,   target: TargetModel, by: "foreignKeyField", fields: ["f1", "f2"]]
@Ref[ref_many, target: TargetModel, via: "中间表名", fields: ["f1", "f2"]]
```

- `fields`：可选，指定加载的目标字段。未指定时默认加载所有非敏感字段（推荐显式声明）。

### 3.3 完整模型定义示例

```cangjie
@Refine
class User {
    var id: Int64 = 0
    var name: String = ""

    @Rel[has_many, target: Post, by: "authorId"]
    var posts: ArrayList<Post> = ArrayList<Post>()

    @Rel[has_one, target: Profile, by: "userId"]
    var profile: Option<Profile> = None
}

@Refine
class Post {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
    var authorId: Int64 = 0

    @Ref[ref_to, target: User, by: "authorId", fields: ["id", "name"]]
    var author: Option<User> = None

    @Ref[ref_many, target: Tag, via: "post_tags", fields: ["id", "name"]]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

@Refine
class Tag {
    var id: Int64 = 0
    var name: String = ""

    @Ref[ref_many, target: Post, via: "post_tags", fields: ["id", "title"]]
    var posts: ArrayList<Post> = ArrayList<Post>()
}
```

---

## 4. SQL 表达式系统

类型安全的查询构建依赖一套运行时表达式树。字段操作通过重载返回 `Expr`，`Query` 构建器组合 `Expr` 生成 `Statement`。

### 4.1 表达式树 `Expr`

```cangjie
enum Expr {
    | Column(String)              // 列引用
    | Value(Any)                  // 字面值
    | Binary(Expr, BinOp, Expr)   // 二元运算（注：仓颉不允许变体名与类型同名，故用 Binary 而非 BinOp）
    | Range(Expr, Expr, Expr)     // BETWEEN low AND high（三操作数，见 Col.between）
    | Unary(UnaryOp, Expr)        // 一元运算
    | FuncCall(String, Array<Expr>) // 函数调用
    | SubQuery(Statement)         // 子查询
    | Raw(String)                 // 原生 SQL 逃生舱
}

enum BinOp {
    | Eq | Ne | Gt | Ge | Lt | Le
    | And | Or
    | Like | In | NotIn | Between
    | Add | Sub | Mul | Div | Mod
}

enum UnaryOp {
    | Not | IsNull | IsNotNull
}
```

- `BinOp.Between` **不是二元操作符**（`Binary(x, Between, y)` 渲染缺 `AND high`，方言会直接抛错）。
  BETWEEN 必须用三操作数的 `Expr.Range`，通过 `Col.between(low, high)` 便捷方法构造。

`Expr` 上的便捷方法：

```cangjie
extend Expr {
    public func and(other: Expr): Expr { Binary(this, And, other) }
    public func or(other: Expr): Expr  { Binary(this, Or, other) }
    public func not(): Expr            { Unary(Not, this) }
}
```

### 4.2 字段描述符 `Col<T>`

`@Refine` 宏为每个实体生成一个 `Cols` 内部类，包含类型化的字段描述符：

```cangjie
// @Refine 宏生成
class PostCols {
    static let id = Col<Int64>("id")
    static let title = Col<String>("title")
    static let content = Col<String>("content")
    static let published = Col<Bool>("published")
    static let authorId = Col<Int64>("authorId")
    static let createdAt = Col<DateTime>("created_at")
}
```

`Col<T>` 定义：

```cangjie
struct Col<T> {
    var name: String

    // 关系操作符 → 返回 Expr（仓颉允许操作符返回任意类型）
    public operator func ==(rhs: T): Expr  { Binary(Column(name), Eq, Value(rhs)) }
    public operator func !=(rhs: T): Expr  { Binary(Column(name), Ne, Value(rhs)) }
    public operator func >(rhs: T): Expr   { Binary(Column(name), Gt, Value(rhs)) }
    public operator func <(rhs: T): Expr   { Binary(Column(name), Lt, Value(rhs)) }
    public operator func >=(rhs: T): Expr  { Binary(Column(name), Ge, Value(rhs)) }
    public operator func <=(rhs: T): Expr  { Binary(Column(name), Le, Value(rhs)) }

    // 列间比较：Col<T> vs Col<T>
    public operator func ==(rhs: Col<T>): Expr { Binary(Column(name), Eq, Column(rhs.name)) }
    public operator func !=(rhs: Col<T>): Expr { Binary(Column(name), Ne, Column(rhs.name)) }

    // 排序
    public func asc(): Expr  { Ordered(Column(name), "ASC") }
    public func desc(): Expr { Ordered(Column(name), "DESC") }

    // IN / NOT IN（OR 链 / AND 链；空数组返回 Raw 兜底，避免 IN () 语法错误）
    public func anyOf(values: Array<T>): Expr {
        if (values.size == 0) { return Raw("1 = 0") }
        var result = Binary(Column(name), Eq, Value(values[0]))
        for (i in 1..values.size) {
            result = Binary(result, Or, Binary(Column(name), Eq, Value(values[i])))
        }
        result
    }
    public func notAnyOf(values: Array<T>): Expr {
        if (values.size == 0) { return Raw("1 = 1") }
        var result = Binary(Column(name), Ne, Value(values[0]))
        for (i in 1..values.size) {
            result = Binary(result, And, Binary(Column(name), Ne, Value(values[i])))
        }
        result
    }

    // BETWEEN low AND high → 三操作数 Expr.Range（`between` 不是仓颉关键字；`in` 是，见下方 inSubquery）
    public func between(low: T, high: T): Expr {
        Expr.Range(Column(name), Value(low), Value(high))
    }

    // `col IN (SELECT ...)`：`in` 是仓颉关键字，方法名用 inSubquery
    public func inSubquery(sub: Statement): Expr {
        Binary(Column(name), In, SubQuery(sub))
    }
}

// String 专用扩展
extend Col<String> {
    public func like(pattern: String): Expr {
        Binary(Column(name), Like, Value(pattern))
    }
}

// Bool 专用：列自身作为条件（WHERE published）
extend Col<Bool> {
    public func isTrue(): Expr  { Unary(IsNotNull, Column(name)) }
    public func isFalse(): Expr { Binary(Column(name), Eq, Value(false)) }
}
```

**关键约束**：`&&` 和 `||` 不支持重载（仓颉内置逻辑操作符不可重载），条件组合使用 `Expr.and()` / `Expr.or()` 方法。

### 4.3 关系描述符 `Relation<TTarget>`

`@Ref` / `@Rel` 注解的关联信息由宏编译为类型安全的描述符对象，替代原始字符串。

#### 4.3.1 类型体系

```cangjie
enum RelationKind {
    | RefTo | RefMany | HasOne | HasMany
}

class Relation<TTarget> {
    var name: String               // 关联名，如 "author"
    var targetTable: String        // 目标表名
    var kind: RelationKind         // 关联类型
    var foreignKey: String         // 外键列名
    var via: Option<String>        // 中间表（RefMany/HasMany）
    var fields: Array<Col<Any>>    // 默认加载的字段
    var condition: Option<Expr>    // 自定义 ON 条件

    public func setFields(fs: Array<Col<Any>>): Relation<TTarget> {
        this.fields = fs
        this
    }
}
```

> 注：仓颉不允许方法与字段同名，字段覆盖方法命名为 `setFields` 而非 `fields`。

类型参数 `TTarget` 确保指向目标实体，但 `include()` 统一接收 `Relation<TTarget>` 的父类型。仓颉中所有 `Relation<TTarget>` 可通过上界通配共享同一接口：

```cangjie
interface IRelation {
    func resolve(): (kind: RelationKind, name: String, table: String,
                     fk: String, via: Option<String>, fields: Array<Col<Any>>)
}
```

#### 4.3.2 宏生成的关系描述符

```cangjie
@Refine
class Post {
    var id: Int64 = 0
    var authorId: Int64 = 0

    @Ref[ref_to, target: User, by: "authorId", fields: ["id", "name"]]
    var author: Option<User> = None

    @Ref[ref_many, target: Tag, via: "post_tags", fields: ["id", "name"]]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}
```

宏为 Post 生成：

```cangjie
// 宏生成
class PostRel {
    static let author = RefTo<User>(
        name: "author",
        fk: Col<Any>("authorId"),
        fields: [Col<Any>("id"), Col<Any>("name")]
    )
    static let tags = RefMany<Tag>(
        name: "tags",
        via: "post_tags",
        fields: [Col<Any>("id"), Col<Any>("name")]
    )
}
```

**类型安全的边界**：

- `PostRel.author`、`Tag.col().name` 等**宏生成的标识符**：拼错 → 编译报错 ✅
  （`Rel` 描述符类与 `Cols` 结构体的成员是编译期实体）
- 但 `@Ref` / `@Rel` 注解里的 `by` / `via` / `fields` 是**普通字符串**，宏**不做跨类校验**：
  拼错（如 `by: "authorrId"` 或 `fields: ["id", "namee"]`）能编译通过，
  **运行时**才会因 SQL 引用不存在的列而报错 ⚠️。

### 4.4 查询构建器 `Query<T>`

```cangjie
class Query<T> {
    // === 构建 ===
    func select(fields: Col<Any>...): Query<T>
    func where(predicates: Expr...): Query<T>     // 多参数 = AND
    func where(predicate: Expr): Query<T>         // 单条件
    func orderBy(fields: Expr...): Query<T>
    func limit(n: Int64): Query<T>
    func offset(n: Int64): Query<T>

    // === 关联预加载（类型安全） ===
    func include(rel: IRelation): Query<T>        // 使用默认 fields
    func include(rel: IRelation, fields: Array<Col<Any>>): Query<T>

    // === 高级查询 ===
    func groupBy(fields: Col<Any>...): Query<T>
    func having(predicates: Expr...): Query<T>    // 配合 groupBy 使用

    // === 聚合 ===
    func count(): Int64
    func exists(): Bool
}
```

> **字段子集与静默默认值**：生成的 `RowMapper` 按 `columnMap.contains(col)` 逐字段装配，结果集中不存在的列保持类型默认值（不抛异常）：
> - `include(rel, [Col("id"), Col("email")])` 只装配选中的字段子集，未选中字段保持默认值；
> - 自定义 `select([...])` 子集同理——未 select 的字段为默认值而非报错，因此 SELECT 列名写错会**静默**返回默认值而不抛错（调试时优先核对列名与结果集列是否一致）。

### 4.5 Clause 与 Statement

```cangjie
enum Clause {
    | SelectClause(Array<Expr>)        // SELECT fields
    | FromClause(String)               // FROM table
    | WhereClause(Array<Expr>)         // WHERE conditions
    | GroupByClause(Array<Expr>)       // GROUP BY fields
    | HavingClause(Array<Expr>)        // HAVING conditions
    | OrderByClause(Array<Expr>)       // ORDER BY fields
    | LimitClause(Int64)               // LIMIT n
    | OffsetClause(Int64)              // OFFSET n
    | JoinClause(String, String, Expr) // JOIN table ON condition
}

struct Statement {
    var clauses: ArrayList<Clause> = ArrayList<Clause>()

    // 由 Dialect 渲染为 (sql, params)
    public func render(dialect: Dialect): (String, Array<Any>) {
        // 遍历 clauses，委托各 clause 调用 dialect 的方法
        // 收集 SQL 片段和参数
    }
}
```

### 4.6 使用示例

```cangjie
// 宏生成：Post.col() 返回 PostCols（字段描述符集合）；Post.query() 返回 Query<Post>
// 宏生成：PostRel 是关系描述符类（静态成员如 PostRel.author、PostRel.tags）

// 查询已发布的文章，按时间倒序
let posts = Post.query()
    .where(Post.col().published == true)
    .where(Post.col().createdAt > DateTime.of(2024, 1, 1))
    .orderBy(Post.col().createdAt.desc())
    .limit(10)
    .all()

// 复杂条件组合
let results = Post.query()
    .where(
        (Post.col().title.like("%refine%"))
            .and(Post.col().published == true)
            .or(Post.col().authorId == 1)
    )
    .all()

// 关联预加载（类型安全）
let postsWithAuthor = Post.query()
    .include(PostRel.author)
    .all()
// postsWithAuthor[0].getAuthor() 直接返回，不触发二次查询

// 预加载 + 覆盖字段（include 双参重载）
// 注：setFields 返回 Relation 基类、不能直接链式传给 include(IRelation)，字段覆盖用双参重载
let postsWithTags = Post.query()
    .include(PostRel.tags, [Col<Any>("name")])
    .all()

// 聚合查询：按作者分组统计文章数
let stats = Post.query()
    .select(Post.col().authorId, count().as("total"))
    .groupBy(Post.col().authorId)
    .having(count() > 5)
    .all()
```

---

## 5. 生成的 API 契约

### 5.1 拥有关系（`#hasOne` / `#hasMany`）API

以 `User` 为例：

| 方法 | 说明 |
| :--- | :--- |
| `func addPost(post: Post): User` | 关联新文章 |
| `func removePost(post: Post): User` | 解除关联 |
| `func clearPosts(): User` | 清空所有文章 |
| `func loadPosts(): ArrayList<Post>` | 显式加载 |
| `func setProfile(profile: Profile): User` | 设置/替换资料 |
| `func removeProfile(): User` | 移除资料 |

### 5.2 引用关系（`#ref_to` / `#ref_many`）API

以 `Post` 为例：

| 方法 | 说明 |
| :--- | :--- |
| `func loadAuthor(): User?` | 按 `fields` 配置加载作者 |
| `func getAuthor(): User?` | 返回已预加载的对象 |
| `func loadTags(): ArrayList<Tag>` | 加载标签集合 |
| `func getTags(): ArrayList<Tag>` | 返回已预加载的集合 |

**关键约束**：`@Ref` **不生成** `setAuthor()`、`addTag()` 等修改方法。

---

## 6. 类型系统与存储映射

### 6.1 逻辑存储类型 `StorageType`

Refine 定义了一套数据库无关的逻辑类型，由具体方言映射为物理类型。

```cangjie
enum StorageType {
    | Integer          // 整数
    | Float            // 浮点
    | Bool             // 布尔
    | String           // 短字符串（VARCHAR）
    | Text             // 长文本
    | Json             // JSON 数据
    | Bytes            // 字节数组
    | Timestamp        // 时间戳
}
```

### 6.2 类型适配器 `TypeAdapter`

自定义类型通过实现该接口告知 Refine 其存储形态与转换逻辑。

```cangjie
interface TypeAdapter<T> {
    func storageType(): StorageType
    func toStored(value: T): Any
    func fromStored(stored: Any): T
}
```

#### 示例：JSON 字段

```cangjie
import stdx.encoding.json.stream.*
import std.io.{ByteBuffer, readToEnd}

struct UserProfile <: JsonSerializable & JsonDeserializable<UserProfile> {
    var bio: String = ""
    var avatarUrl: String = ""

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("bio").writeValue(bio)
        w.writeName("avatarUrl").writeValue(avatarUrl)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): UserProfile {
        var res = UserProfile()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "bio" => res.bio = r.readValue<String>()
                case "avatarUrl" => res.avatarUrl = r.readValue<String>()
                case _ => ()
            }
        }
        r.endObject()
        return res
    }
}

extend UserProfile <: TypeAdapter<UserProfile> {
    public func storageType(): StorageType { StorageType.Json }

    public func toStored(value: UserProfile): Any {
        let stream = ByteBuffer()
        let writer = JsonWriter(stream)
        writer.writeValue(value)
        writer.flush()
        String.fromUtf8(readToEnd(stream))
    }

    public func fromStored(stored: Any): UserProfile {
        let jsonStr = stored as String
        let stream = ByteBuffer()
        unsafe { stream.write(jsonStr.rawData()) }
        UserProfile.fromJson(JsonReader(stream))
    }
}
```

#### TypeAdapter 与 std.database.sql 的集成

查询结果映射时，Refine 采用**两阶段读取**策略，不侵入 `std.database.sql.QueryResult.get<T>()`：

```
DB 列类型      std 原生读                     TypeAdapter 转（如果存在）
────────────   ────────────────────────        ──────────────────────────────
INTEGER        qr.get<Int64>(i)       ──→      直接使用
VARCHAR        qr.get<String>(i)      ──→      直接使用
JSON/TEXT      qr.get<String>(i)      ──→      jsonAdapter.fromStored(str) → UserProfile
BYTEA          qr.get<Array<Byte>>(i) ──→      byteAdapter.fromStored(bytes) → 业务类型
TIMESTAMP      qr.get<DateTime>(i)    ──→      dateAdapter.fromStored(dt) → 业务类型
```

`@Refine` 宏为每个字段生成的映射代码只有两种路径：

```cangjie
// 宏生成的伪逻辑
if (field.hasTypeAdapter) {
    // 先以原生类型读出，再经过 TypeAdapter 转换
    let native = qr.get<NativeType>(index)
    entity.field = typeAdapter.fromStored(native)
} else {
    // 直接使用 std 的原生类型
    entity.field = qr.get<NativeType>(index)
}
```

其中 `NativeType` 由 `StorageType` 根据 [6.3 节](#63-默认类型推断)的映射表确定（`Json` → `String`、`Bytes` → `Array<Byte>`、`Timestamp` → `DateTime`……）。

### 6.3 默认类型推断

未实现 `TypeAdapter` 的普通类型按以下规则自动推断：

| 仓颉类型 | 默认 `StorageType` |
| :--- | :--- |
| 整数类型 | `StorageType.Integer` |
| 浮点类型 | `StorageType.Float` |
| `Bool` | `StorageType.Bool` |
| `String` | `StorageType.Text` |
| `struct` | `StorageType.Json` |
| `Array<UInt8>` | `StorageType.Bytes` |
| `Option<T>` | 同 `T`，列约束为 `NULL` |

### 6.4 字段级覆盖（可选）

```cangjie
@Refine
class Document {
    var id: Int64 = 0

    @Field(storage: StorageType.Text)   // 覆盖默认推断
    var content: String = ""
}
```

---

考虑到文档的篇幅，我将直接对原文档中的 Dialect 部分进行更新。

---

## 7. 数据库方言映射（更新）

### 7.1 Dialect 接口设计

借鉴 GORM Dialector 的设计思路，同时结合仓颉语言特性，设计 Refine 的 `Dialect` 接口：

```cangjie
interface Dialect {
    // === 基础信息 ===
    func name(): String                         // 返回方言名称，如 "mysql"、"postgres"
    func initialize(db: DB): Unit               // 初始化连接，注册子句构建器等

    // === Schema 迁移 ===
    func migrator(db: DB): Migrator             // 返回数据库迁移工具接口

    // === 类型映射 ===
    func dataTypeOf(field: schema.Field): String   // 根据字段确定数据库列类型
    func defaultValueOf(field: schema.Field): String // 生成字段的默认值 SQL 表达式

    // === SQL 生成 ===
    func bindVarTo(writer: clause.Writer, stmt: Statement, index: Int64): Unit  // 处理参数占位符（?/$1/$n）
    func quoteTo(writer: clause.Writer, identifier: String): Unit                 // 标识符引用（``/""/[]）
    func explain(sql: String, vars: Array<Any>): String                           // 格式化 SQL 用于调试

    // === 特性检测 ===
    func hasReturningSupport(): Bool             // 是否支持 RETURNING 子句
    func hasUpsertSupport(): Bool                // 是否支持 UPSERT（如 INSERT ... ON CONFLICT）
    func hasJSONSupport(): Bool                  // 是否原生支持 JSON 类型
}
```

### 7.2 各方法职责详解

| 方法 | 职责 | 数据库差异示例 |
| :--- | :--- | :--- |
| `name()` | 返回方言标识符 | `"mysql"`, `"postgres"`, `"sqlite"` |
| `initialize()` | 注册数据库特有的 SQL 子句构建器 | 如 MySQL 的 `ON DUPLICATE KEY UPDATE`，PostgreSQL 的 `ON CONFLICT` |
| `migrator()` | 返回 `Migrator` 接口实现，负责建表、改列、索引等 | GORM 的 `AutoMigrate` 依赖此接口完成跨数据库的 DDL 操作 |
| `dataTypeOf()` | **核心方法**：将 `schema.Field` 转换为具体数据库的列类型 | 见下方详细说明 |
| `defaultValueOf()` | 为字段生成 `DEFAULT` 子句 | 如 `CURRENT_TIMESTAMP` vs `NOW()` |
| `bindVarTo()` | 生成参数占位符 | MySQL: `?`, PostgreSQL: `$1, $2`, SQLite: `?` |
| `quoteTo()` | 引用标识符（表名、列名） | MySQL: `` `table` ``, PostgreSQL: `"table"`, SQLite: `"table"` 或 `[table]` |
| `explain()` | 将 SQL 与参数组合为可读字符串，便于调试 | 用于日志输出 |

### 7.3 扩展接口：Savepoint 支持

对于支持嵌套事务的数据库（如 PostgreSQL、MySQL），可单独实现 `SavepointDialect` 接口：

```cangjie
interface SavepointDialect {
    func savepoint(tx: DB, name: String): Unit      // 创建保存点
    func rollbackTo(tx: DB, name: String): Unit     // 回滚到保存点
}
```

`@Refine` 宏检测方言是否实现了此接口，从而决定是否生成嵌套事务 API。

### 7.4 物理类型映射表

以下是各数据库方言对 `StorageType` 的详细映射：

| StorageType | MySQL | PostgreSQL | SQLite | SQL Server |
| :--- | :--- | :--- | :--- | :--- |
| `Integer` | `BIGINT` | `BIGINT` | `INTEGER` | `BIGINT` |
| `SmallInt` | `SMALLINT` | `SMALLINT` | `INTEGER` | `SMALLINT` |
| `Float` | `DOUBLE` | `DOUBLE PRECISION` | `REAL` | `FLOAT` |
| `Decimal` | `DECIMAL(65,30)` | `DECIMAL` | `NUMERIC` | `DECIMAL(38,18)` |
| `Bool` | `TINYINT(1)` | `BOOLEAN` | `INTEGER` | `BIT` |
| `String(length)` | `VARCHAR(n)` | `VARCHAR(n)` | `TEXT` | `NVARCHAR(n)` |
| `Text` | `TEXT` / `LONGTEXT` | `TEXT` | `TEXT` | `NVARCHAR(MAX)` |
| `Json` | `JSON` | `JSONB` | `TEXT` | `NVARCHAR(MAX)` |
| `Bytes` | `LONGBLOB` | `BYTEA` | `BLOB` | `VARBINARY(MAX)` |
| `Timestamp` | `DATETIME(6)` | `TIMESTAMP` | `DATETIME` | `DATETIME2` |
| `Date` | `DATE` | `DATE` | `DATE` | `DATE` |
| `Time` | `TIME(6)` | `TIME` | `TIME` | `TIME` |
| `UUID` | `CHAR(36)` | `UUID` | `TEXT` | `UNIQUEIDENTIFIER` |

### 7.5 仓颉类型到 StorageType 的默认推断（更新）

| 仓颉类型 | 默认 `StorageType` | 说明 |
| :--- | :--- | :--- |
| `Int8`/`Int16`/`Int32`/`Int64` | `StorageType.Integer` | 有符号整数 |
| `UInt8`/`UInt16`/`UInt32`/`UInt64` | `StorageType.Integer` | 无符号整数（方言层可能添加 `UNSIGNED`） |
| `Float32`/`Float64` | `StorageType.Float` | 浮点数 |
| `Decimal` (std.math.numeric) | `StorageType.Decimal` | 精确数值 |
| `Bool` | `StorageType.Bool` | 布尔值 |
| `String` | `StorageType.Text` | 默认映射为长文本 |
| `Array<UInt8>` | `StorageType.Bytes` | 字节数组 |
| `DateTime` (std.time) | `StorageType.Timestamp` | 日期时间 |
| `struct` (实现 `Serializable<T>`) | `StorageType.Json` | 默认 JSON 序列化 |
| `Option<T>` | 同 `T`，列约束为 `NULL` | 可选值 |

---

## 8. 连接与 Session 管理

Refine 在 `std.database.sql` 之上构建连接管理层，封装连接池、事务传播和 Session 生命周期。所有资源由 `Refine` 实例统一管理，多实例互相隔离。

### 8.1 整体架构

```
┌─────────────────────────────────────────────────┐
│  Refine                                          │
│  ┌─────────────────────────────────────────┐     │
│  │  PooledDatasource (std.database.sql)    │     │
│  │  ┌──────────────────────────────────┐   │     │
│  │  │  connection pool                 │   │     │
│  │  └──────────────────────────────────┘   │     │
│  │  ┌──────────────────────────────────┐   │     │
│  │  │  Dialect (自动检测)               │   │     │
│  │  └──────────────────────────────────┘   │     │
│  │  ┌──────────────────────────────────┐   │     │
│  │  │  HookRegistry (实例级)           │   │     │
│  │  └──────────────────────────────────┘   │     │
│  └─────────────────────────────────────────┘     │
│          │ connect()                             │
│          ▼                                       │
│  Session ───→ Connection (std.database.sql)      │
│       │        + ref: Refine                     │
│       ├── Tx ───→ Transaction + Connection        │
│       │      + ref: Refine                       │
│       │      .commit() / .rollback()              │
│       │                                           │
│       └── Query<T>.all() / .one()                 │
│            │                                      │
│            ▼                                      │
│     Statement → render(Dialect)                   │
│              → Connection.prepareStatement(sql)   │
│              → Statement.set<T>(index, value)     │
│              → execute                             │
└─────────────────────────────────────────────────┘
```

### 8.2 `Refine` — 统一入口

```cangjie
class Refine {
    // === 内部状态 ===
    private var datasource: PooledDatasource  // 连接池
    private var dialect: Dialect              // 方言（从 URL 自动检测）
    private var paramOffset: Int64            // 0=标准, 1=MariaDB
    private var hookRegistry                  // 实例级钩子注册表

    // === 创建 ===
    static func open(url: String): Refine
    static func open(url: String, opts: Array<(String, String)>): Refine

    // === Session / 事务 ===
    func session(): Session                          // 获取一个新的 Session
    func transaction<T>(action: (Tx) -> T): T        // 事务内执行，自动 commit/rollback

    // === 钩子（实例级）===
    func hook<T>(typeName: String, kind: HookKind, hook: HookFn<T>): Unit
    func executeHooks<T>(typeName, kind, scope): ?Exception

    // === 查询快捷入口 ===
    func all<T>(query: Query<T>): Array<T>
    func one<T>(query: Query<T>): Option<T>

    // === 元数据 ===
    func getDialect(): Dialect
    func migrator(): Migrator
    func close(): Unit

    // === 连接池配置 ===
    mut prop maxPoolSize: Int32
    mut prop connectionTimeout: Duration
    mut prop idleTimeout: Duration
    mut prop maxLifeTime: Duration
}
```

`Refine.open(url)` 内部流程：

```cangjie
static func open(url: String, opts: Array<(String, String)>): Refine {
    // 1. 从 URL 提取驱动名（如 "postgres://..." 提取 "postgres"）
    // 2. DriverManager.getDriver(driverName) ?? throw
    // 3. driver.open(url, opts) → Datasource
    // 4. PooledDatasource(datasource) → 带连接池的数据源
    // 5. detectDialect(driverName) → 根据驱动自动选择方言
    // 6. 检测 MariaDB 的 1-based 参数偏移
    // 7. 返回 Refine 实例
}
```

### 8.3 `Session` — 连接会话

```cangjie
class Session {
    // 内部持有 Connection + ref: Refine
    var ref: Option<Refine>              // 所属 Refine 实例

    // === SQL 执行 ===
    func prepareStatement(sql: String): Statement
    func execute(sql: String, params: Array<Any>): UpdateResult
    func query(sql: String, params: Array<Any>): QueryResult

    // === 元数据 ===
    func getDialect(): Dialect                     // 方言检测（自动推断）
}
```

### 8.4 `Tx` — 事务

```cangjie
class Tx {
    // 内部持有 Connection + Transaction + ref: Refine
    var ref: Option<Refine>              // 所属 Refine 实例（hook 调用走此路径）

    // === 继承 Session 的全部执行能力 ===

    // === 事务控制 ===
    func commit(): Unit
    func rollback(): Unit
    func save(name: String): Unit                  // 创建保存点
    func rollbackTo(name: String): Unit             // 回滚到保存点

    // === 事务配置 ===
    mut prop isoLevel: TransactionIsoLevel
    mut prop accessMode: TransactionAccessMode
}
```

### 8.5 事务传播

```cangjie
db.transaction { tx: Tx =>
    // tx 已处于事务中，所有操作在事务内执行
    // 成功退出 lambda → tx.commit()
    // 抛出异常 → tx.rollback()

    // 嵌套事务
    tx.save("savepoint1")
    // ... 中间操作
    tx.rollbackTo("savepoint1")  // 回滚到保存点
}
```

**传播规则**：

| 调用方式 | 行为 |
|:---|:---|
| `db.transaction { tx => ... }` | 新开事务，lambda 结束时 commit，异常时 rollback |
| `tx.transaction { nested => ... }` | 创建保存点，嵌套执行，回滚到保存点 |

### 8.6 `Query<T>` 与连接绑定

`Query<T>` 支持三种绑定方式：

```cangjie
// 方式一：Refine 实例（推荐，自动设置方言 + session）
let posts = Post.query().using(rf).all()

// 方式二：Session 执行
let session = rf.session()
let posts = Post.query().using(session).all()

// 方式三：事务内执行
let posts = rf.transaction { tx: Tx =>
    Post.query().using(tx).all()
}
```

`Query<T>` 的 `using()` 方法：

```cangjie
class Query<T> {
    func using(exec: ExecutionContext): Query<T>   // Session | Tx
    func using(rf: Refine): Query<T>               // 自动创建 session + 设置方言
    // ExecutionContext = Session | Tx

    func all(): Array<T> {
        let stmt = this.build()           // 构建内部 Statement
        let (sql, params) = stmt.render(dialect)
        let ps = exec.prepareStatement(sql)
        // 绑定参数
        // 执行 + 结果映射
    }
}
```

### 8.7 完整调用链示例

```cangjie
// 初始化
let rf = Refine.open("sqlite://refine.db")

// 查询
let posts = rf.transaction { tx =>
    Post.query()
        .using(tx)
        .where(Post.col().published == true)
        .include(PostRel.author)
        .orderBy(Post.col().createdAt.desc())
        .limit(10)
        .all()
}

// 插入
rf.transaction { tx =>
    let post = Post {
        title: "Hello Refine",
        content: "..."
    }
    tx.save(post)   // 宏生成的实体持久化方法，hook 走 rf 实例
}
```

---

## 9. 结果映射（Row → Object）

将 `std.database.sql.QueryResult` 的行数据映射回实体对象，分为平坦映射和嵌套映射。

### 9.1 平坦映射（无关联加载）

每个实体字段对应一个列索引，由 `columnInfos.name` → index 建立映射表：

```cangjie
// @Refine 宏生成
func mapPost(result: QueryResult, columnMap: HashMap<String, Int64>): Post {
    var entity = Post()

    // Integer → 直接 std 读取
    entity.id = result.get<Int64>(columnMap["id"])

    // Text → 直接 std 读取
    entity.title = result.get<String>(columnMap["title"])

    // 拥有 TypeAdapter → 先读原生类型，再适配
    if (columnMap.contains("profile")) {
        let json = result.get<String>(columnMap["profile"])
        entity.profile = profileAdapter.fromStored(json)
    }

    return entity
}
```

### 9.2 嵌套映射（预加载关联）

`include()` 生成 LEFT JOIN 时，SQL 输出列使用带前缀的别名：

```sql
-- Post.query().include(PostRel.author).all()
-- @Ref[ref_to, target: User, by: "authorId", fields: ["id", "name"]]
SELECT
  p.id      AS "id",
  p.title   AS "title",
  p.author_id AS "author_id",
  u.id      AS "author.id",       -- 前缀: "author"
  u.name    AS "author.name"       -- 前缀: "author"
FROM post p
LEFT JOIN user u ON p.author_id = u.id
```

前缀名取自 `Relation.name`（即 `PostRel.author` 的 name）。结果映射时按前缀分拆：

```cangjie
// @Refine 宏生成，含 include(author) 时的逻辑
func mapPostWithAuthor(
    result: QueryResult,
    columnMap: HashMap<String, Int64>
): Post {
    var entity = mapPost(result, columnMap)                    // 主实体映射

    if (columnMap.contains("author.id")) {                      // 检查前缀
        var author = User()
        author.id   = result.get<Int64>(columnMap["author.id"])
        author.name = result.get<String>(columnMap["author.name"])
        entity.author = Some(author)                            // 装配到关联字段
    }

    return entity
}
```

### 9.3 `Query<T>` 执行完整路径

```cangjie
class Query<T> {
    func all(): Array<T> {
        // 1. 构建 Statement + render
        let stmt = this.build()
        let (sql, params) = stmt.render(dialect)

        // 2. std 预编译 + 参数绑定
        let ps = exec.prepareStatement(sql)
        for (i in 0..params.size) {
            dispatchSet(ps, i, params[i])     // 运行时类型分发
        }

        // 3. 执行
        let result = ps.query()

        // 4. 结果映射
        let columnMap = buildColumnMap(result.columnInfos)
        var entities = ArrayList<T>()
        while (result.next()) {
            entities.add(mapWithRelations(result, columnMap))
        }
        return entities.toArray()
    }
}
```

其中 `dispatchSet` 处理 `Array<Any>` 到 `Statement.set<T>()` 的分发：

```cangjie
func dispatchSet(ps: Statement, index: Int, value: Any): Unit {
    match (value) {
        case v: Int64    => ps.set<Int64>(index, v)
        case v: String   => ps.set<String>(index, v)
        case v: Bool     => ps.set<Bool>(index, v)
        case v: Float64  => ps.set<Float64>(index, v)
        case v: DateTime => ps.set<DateTime>(index, v)
        case v: Array<UInt8> => ps.set<Array<UInt8>>(index, v)
        case _           => throw SqlException("unsupported param type")
    }
}
```

---

## 10. 生命周期钩子

钩子允许在不侵入实体定义的前提下挂载业务逻辑到 CRUD 操作，天然避免循环依赖。

### 10.1 注册与执行

钩子注册在 `Refine` 实例上，多实例互相隔离：

```cangjie
// 实例 A：注册钩子
let rf = Refine.open("sqlite://test.db")
rf.hook<Post>("Post", TxBeforeCreate) { scope =>
    if (scope.entity.title == "") {
        scope.error = Exception("title required")
        scope.aborted = true
    }
}

// 模块 B：审计（独立注册）
rf.hook<Post>("Post", TxAfterCreate) { scope =>
    AuditLog.log("created: ${scope.entity.id}")
}

// 模块 C：验证（与模块 A 串行执行，任一 abort 终止后续）
rf.hook<Post>("Post", TxBeforeCreate) { scope =>
    if (scope.entity.content.size > 10000) {
        scope.error = Exception("content too long")
    }
}

// 实例 B：完全独立的钩子
let rf2 = Refine.open("mysql://...")
rf2.hook<Post>("Post", TxBeforeCreate) { scope => ... }  // 不影响 rf
```

- 多个钩子按**注册顺序**串行执行
- 任一钩子返回 error，**后续钩子不再执行**
- 注册方和实体定义方可以是不同 package，零耦合

### 10.2 钩子类型

```cangjie
enum HookKind {
    | TxBeforeCreate
    | TxAfterCreate
    | TxBeforeUpdate
    | TxAfterUpdate
    | TxBeforeDelete
    | TxAfterDelete
    | AfterFind        // 查询结果映射后触发
}
```

> **I14 变更**：非事务写钩子（`BeforeCreate` 等）与全局注册表已移除，钩子全部实例级、仅随 `Tx.save/update/delete` 与绑定实例的查询触发。

### 10.3 Scope

```cangjie
class Scope<T> {
    var entity: T                    // 当前操作的实体
    var db: Tx                       // 事务上下文
    var entityBefore: T?             // 更新前的旧值（仅 Update）
    var fields: Array<Col<Any>>      // 变更字段列表（仅 Update）
    var error: Error?                // 设置后终止钩子链
    var aborted: Bool = false        // 是否中断
    var result: QueryResult?         // AfterFind/TxAfterCreate 的结果

    public func abort(err: Error) {
        error = err
        aborted = true
    }
}
```

### 10.4 宏生成的内联钩子调用

`@Refine` 宏在生成的 `extend Tx` 方法中通过 `this.ref` 调用实例级钩子：

```cangjie
// @Refine 宏生成（extend Tx）
func save(entity: User): Unit {
    let scope = Scope<User>(entity)

    // Before — 通过 Tx 持有的 Refine 实例调用
    if (this.ref.isSome()) {
        this.ref.getOrThrow().executeHooks("User", TxBeforeCreate, scope)
    }
    if (scope.aborted) { throw scope.error }

    // INSERT INTO ...
    let result = this.execute("INSERT INTO user ...")

    // After
    let afterScope = Scope<User>(entity)
    if (this.ref.isSome()) {
        this.ref.getOrThrow().executeHooks("User", TxAfterCreate, afterScope)
    }
}
```

### 10.5 运行时注册入口

钩子实例级注册，应用启动时通过 `Refine` 实例配置：

```cangjie
func main() {
    let rf = Refine.open("sqlite://test.db")

    // 注册钩子
    rf.hook<Post>("Post", TxBeforeCreate, validatePost)
    rf.hook<Post>("Post", TxAfterCreate, auditPost)
    rf.hook<Post>("Post", AfterFind, cachePost)

    // 启动
    runServer()
}
```

---

## 11. Schema 与自动迁移

GORM 的 AutoMigrate 经大量实战验证，Refine 以相同行为为基准：**只加不减，不改类型**。

### 11.1 宏生成 Schema 元数据

`@Refine` 宏在编译期提取完整的表结构信息，运行时不需要反射：

```cangjie
// @Refine 宏生成
class PostSchema <: TableSchema {
    public func tableName(): String { "post" }

    public func columns(): Array<ColumnDef> {
        [
            ColumnDef("id", StorageType.Integer, primaryKey: true, autoIncrement: true),
            ColumnDef("title", StorageType.Text, nullable: false),
            ColumnDef("content", StorageType.Text, nullable: true),
            ColumnDef("author_id", StorageType.Integer, nullable: false),
            ColumnDef("created_at", StorageType.Timestamp, nullable: false),
        ]
    }

    public func indexes(): Array<IndexDef> {
        [
            IndexDef("idx_post_author", ["author_id"]),
        ]
    }

    public func relations(): Array<RelationDef> {
        [
            RelationDef("author", "user", foreignKey: "author_id"),
        ]
    }
}
```

### 11.2 Migrator 接口

```cangjie
interface Migrator {
    // 自动同步（只加不减）
    func autoMigrate(schemas: Array<TableSchema>): Unit

    // 单个操作
    func createTable(schema: TableSchema): Unit
    func dropTable(schema: TableSchema): Unit
    func hasTable(name: String): Bool

    func addColumn(table: String, col: ColumnDef): Unit
    func addIndex(table: String, idx: IndexDef): Unit

    // 显式迁移（需要用户主动调用，以防丢数据）
    func dropColumn(table: String, colName: String): Unit
    func alterColumn(table: String, old: ColumnDef, new: ColumnDef): Unit
}
```

### 11.3 Diff 算法

```cangjie
func autoMigrate(schemas: Array<TableSchema>): Unit {
    for (schema in schemas) {
        let tableName = schema.tableName()

        if (!hasTable(tableName)) {
            createTable(schema)
            continue
        }

        let existing = inspectTable(tableName)     // 查询实际表结构

        for (col in schema.columns()) {
            if (!existing.hasColumn(col.name)) {
                addColumn(tableName, col)
            }
        }

        for (idx in schema.indexes()) {
            if (!existing.hasIndex(idx.name)) {
                addIndex(tableName, idx)
            }
        }
    }
}
```

**安全规则**：

| 操作 | AutoMigrate 行为 | 说明 |
|:---|:---:|:---|
| 新增表 | ✅ 自动创建 | |
| 新增列 | ✅ 自动添加 | 已有行使用 DEFAULT 或 NULL |
| 新增索引 | ✅ 自动添加 | |
| 删除列 | ❌ 不操作 | 需要显式调用 `dropColumn()` |
| 修改列类型 | ❌ 不操作 | 需要显式调用 `alterColumn()` |
| 删除表 | ❌ 不操作 | 需要显式调用 `dropTable()` |

### 11.4 使用入口

```cangjie
func main() {
    let rf = Refine.open("sqlite://test.db")

    // 自动迁移：对比模型和数据库，应用安全变更
    rf.migrator().autoMigrate([PostSchema(), UserSchema()])

    // 显式迁移：示例如下
    rf.migrator().alterColumn("post",
        ColumnDef("content", StorageType.Text),
        ColumnDef("content", StorageType.String(1000)))
}
```

`Refine.migrator()` 委托给当前方言的 `Dialect.migrator()`。


`DB.migrator()` 委托给当前方言的 `Dialect.migrator()`：

```cangjie
extend DB {
    public func migrator(): Migrator {
        dialect.migrator(this)
    }
}
```

---

## 12. AI 友好性评估

| 对比维度 | 传统 ORM | Refine |
| :--- | :--- | :--- |
| **字段映射** | 依赖字符串标签，AI 易出错 | 强类型方法，编译期检查 |
| **关联修改** | AI 可能调用危险的级联修改 | 引用关系无修改 API，安全边界硬约束 |
| **按需加载** | AI 需推测字段集 | `fields` 显式声明，AI 直接复用 |
| **自定义类型** | 缺乏统一模式，AI 难理解 | `TypeAdapter` 提供标准范式 |

---

## 13. 实现路线图

### Phase 1：表达式系统与查询构建器
- 实现 `Expr` / `Col<T>` / `BinOp` / `UnaryOp` 表达式树（详见第 4 章）
- 实现 `Clause` / `Statement` 构建器
- 实现 `Query<T>` 类型安全查询接口
- 实现 SQLite 方言的表达式渲染

### Phase 2：核心宏框架
- 实现 `@Refine`、`@Rel`、`@Ref` 宏
- 宏生成 `Cols` 字段描述符 + `query()` 入口
- 生成基础 CRUD + 类型安全查询器
- 生成钩子调用逻辑（TxBeforeCreate、TxAfterCreate 等，详见第 10 章）

### Phase 3：类型系统、连接管理与迁移
- 实现 `StorageType` 枚举与方言映射
- 实现 `TypeAdapter` 接口与默认推断
- 实现 `DB` 连接池与 Session 管理
- 实现结果映射（Row → Object）
- 实现 Migrator 自动迁移（详见第 11 章）
- 支持 JSON、Bytes 等常用自定义类型

### Phase 4：生态与工具
- 迁移工具（基于宏生成 Schema）
- LSP 集成（宏展开预览、智能提示）
- 官方文档与 AI 提示词库

---

## 14. 总结

Refine 充分利用仓颉语言的编译期元编程能力，重新定义了 ORM 的关系语义与类型系统。通过 **“拥有-引用”** 的清晰二分、**编译期代码生成** 与 **逻辑存储类型抽象**，Refine 不仅为开发者提供了极致的类型安全体验，更从根本上消除了 AI 辅助编程中的歧义与风险，是面向下一代软件开发的数据持久化方案。
