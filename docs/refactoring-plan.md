# 修复与重构方案

> 本文档列出从当前实现到设计目标的修复路径。

---

## P0：API 类型安全化（消除字符串操作）

### 0.1 `Query<T>.all()` 自动映射（不传 mapper）

**现状：**
```cangjie
let r = Query<UserRow>().using(s)
    .select([Column("id"), Column("name")]).from("users")
    .all() { res, m =>
        UserRow(res.get<Int64>(m["id"]), res.get<String>(m["name"]), "")
    }
```

**设计目标：**
```cangjie
let r = Post.query().using(tx).where(Post.col.published == true).all()
```

**方案：**
- `@Refine` 宏为每个实体生成 `mapRow<T>(result, columnMap): T` 函数
- `Query<T>` 新增 `all(): Array<T>`（无参版本），内部检测是否能调用 `T.mapRow()`（通过接口或宏生成的胶水代码）
- 保留 `all(mapper)` 作为自定义映射的 escape hatch

**涉及文件：**
- `src/macros/refine_macro.cj` — 新增 `buildMapRow()` 代码生成
- `src/query.cj` — 新增无参 `all()`/`one()` 方法，调用宏生成的映射函数
- 可能需要一个 marker interface `Mappable<T>` 让 Query 检测

### 0.2 `Tx.save(entity)` / `Tx.delete(entity)` 真正执行 SQL

**现状：** 宏生成 `Post.save(post)` 静态方法，只调了 hooks，没实际 INSERT

**设计目标：**
```cangjie
db.transaction { tx =>
    tx.save(post)     // INSERT INTO post ...
    tx.delete(post)   // DELETE FROM post WHERE id = ?
}
```

**方案：**
- `@Refine` 宏为每个实体生成 `insertSQL()`、`updateSQL()`、`deleteSQL()` 静态方法（返回 SQL 字符串 + 字段列表）
- `extend Tx` 上新增泛型 `save<T>(entity: T)`、`delete<T>(entity: T)` 方法
- 通过 `TypeInfo` 或编译期生成的注册表将实体类型映射到对应的 SQL
- 内部调用：render SQL → dispatchSet → execute

**涉及文件：**
- `src/db.cj` — 新增 `extend Tx { save/delete }`
- `src/macros/refine_macro.cj` — 生成 insertSQL/updateSQL/deleteSQL

---

## P1：关系 API 与 JOIN

### 1.1 宏生成关系操作方法

**现状：** `@Rel`/`@Ref` 只生成了描述符类（XxxRel），无操作方法

**设计目标：**
```cangjie
// hasMany
user.addPost(tx, post)      // INSERT post + set FK
user.removePost(tx, post)   // DELETE post
user.clearPosts(tx)         // DELETE WHERE user_id = ?
user.loadPosts(tx)          // SELECT * FROM post WHERE user_id = ?

// hasOne
user.setProfile(tx, profile)
user.removeProfile(tx)
user.loadProfile(tx)

// ref_to
post.loadAuthor(tx)         // SELECT ... FROM user WHERE id = ?
post.getAuthor()            // 返回已预加载的 author（无 DB 查询）

// ref_many
post.loadTags(tx)           // SELECT ... FROM tag JOIN post_tags
post.getTags()              // 返回已预加载的 tags
```

**方案：**
- `@Refine` 宏遍历字段的 `@Rel`/`@Ref` 注解
- 根据 `RelationKind` 生成对应的方法
- 方法签名包含 `tx: Tx` 参数（或 `exec: ExecutionContext`）

### 1.2 JOIN/include() 渲染 + 嵌套映射

**现状：** `include()` 只收集 IRelation 列表，render() 不处理

**方案：**
- Query 构建 `all()` 时，遍历 `included` relations：
  - 为每个 relation 添加 `JoinClause` 到 Statement
  - 为主表和关联表的 SELECT 列添加前缀别名
- 渲染时 render() 输出 JOIN SQL + 别名列
- 结果映射时，按列前缀分拆为嵌套对象
- 宏生成 `mapWithRelations()` 函数处理嵌套映射

---

## P2：Dialect 接口补齐

### 2.1 向 Dialect 添加缺失方法

```cangjie
interface Dialect {
    // 已有
    func name(): String
    func render(stmt: Statement): (String, Array<Any>)
    func quoteIdentifier(name: String): String
    func hasUpsertSupport(): Bool
    func upsertSQL(...): String
    
    // 新增
    func dataTypeOf(st: StorageType): String     // 从 Migrator 移过来
    func hasReturningSupport(): Bool
    func hasJSONSupport(): Bool
}
```

- `SQLiteMigrator.dataTypeOf()` 改为调用 `dialect.dataTypeOf()`
- 各 Dialect 实现类实现 `dataTypeOf()` 方法，返回对应的物理类型

---

## P3：测试重构

所有集成测试从字符串操作改为类型安全的 Refine API：

| 测试 | 当前（字符串） | 目标（类型安全） |
|---|---|---|
| CRUD | `conn.prepareStatement("INSERT ...")` | `tx.save(entity)` |
| WHERE | `Binary(Column("name"), Eq, Value("Alice"))` | `User.col.name == "Alice"` |
| ORDER BY | `Ordered(Column("id"), "ASC")` | `User.col.id.asc()` |
| JOIN | `"posts p, post_tags pt, tags t"` | `include(Post.rel.tags)` |
| 映射 | `UserRow(res.get(m["id"]), ...)` | 自动映射 |

---

## 依赖关系

```
P0.2 Tx.save/delete ──→ P0.1 自动映射 ──→ P1.1 关系操作方法
                                              │
                                              └──→ P1.2 JOIN/include
                                                      │
                                                      ↓
                                                 P3 测试重构
```