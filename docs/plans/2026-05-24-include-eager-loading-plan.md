# Include/Eager Loading Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 完整实现 `include()` 预加载（方案 B：mapper 替换，实体零侵入）

**Architecture:** IRelation 存储目标实体 mapper + field setter；`include()` 包装 base mapper 为前缀列感知的复合 mapper；HasMany 在 `all()` 层按主键聚合。

**Tech Stack:** Cangjie macro (std.ast), refine ORM core

---

### Task 1: IRelation 接口增加 mapper + setter

**Files:**
- Modify: `src/relation.cj`

**Step 1:** IRelation 接口加两个方法

```cangjie
public interface IRelation {
    func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>)
    func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any
    func getFieldSetter(): (Any, Any) -> Unit   // (entity, targetValue) => entity.field = target
}
```

**Step 2:** 四个实现类构造函数加 `targetMapper` + `fieldSetter` 参数

```cangjie
public class RefTo<TTarget> <: Relation<TTarget> & IRelation {
    var targetMapper: (QueryResult, HashMap<String, Int64>) -> Any
    var fieldSetter: (Any, Any) -> Unit

    public init(name: String, fk: Col<Any>, fields: Array<Col<Any>>, targetTable: String,
                mapper: (QueryResult, HashMap<String, Int64>) -> Any,
                setter: (Any, Any) -> Unit) {
        super(name, targetTable, RelationKind.RefToRel, fk.name, None, fields)
        this.targetMapper = mapper
        this.fieldSetter = setter
    }

    public func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any { targetMapper }
    public func getFieldSetter(): (Any, Any) -> Unit { fieldSetter }
}
```

同样改动 `HasOne`、`HasMany`、`RefMany`。

**Step 3:** Build + test

Run: `cjpm build && cjpm test`
Expected: 编译错误（构建别处的旧调用）→ 修正后 223 pass

**Step 4:** Commit

---

### Task 2: 宏 — query() 生成显式 SELECT 列

**Files:**
- Modify: `src/macros/refine_macro.cj:719-725`

**Step 1:** `query()` 改为生成 `select([Column("id"), Column("name"), ...])`

从 `extractFields` 的返回列表获取所有非关系字段名，生成 `Column("name")` 的 tokens。

**Step 2:** Build + test

**Step 3:** Commit

---

### Task 3: 宏 — 关联常量传入 mapper + setter

**Files:**
- Modify: `src/macros/refine_macro.cj` — `buildRelClass`

**Step 1:** `buildRelClass` 生成的 `RefTo`/`HasOne`/`HasMany`/`RefMany` 调用传入 mapper 和 setter

为每个关联生成：
```cangjie
static let author = RefTo<User>("author", Col<Any>("user_id"), 
    [Col<Any>("id"), Col<Any>("name")], "user",
    PostRel.authorMapper, PostRel.authorSetter)

static let authorMapper = UserRowMapper

static let authorSetter = { entity: Any, target: Any =>
    (entity as Post).author = target as Option<User>
}
```

注意：`authorSetter` 中的 `Post` 和 `User` 类型名从 `className` 和 `r.target` 获取。

**Step 2:** 同时处理 `HasOne`（setter 设 Option<T>）、`HasMany`（setter 设 ArrayList<T>）

**Step 3:** Build + test

**Step 4:** Commit

---

### Task 4: processIncluded — 正确 JOIN + 别名列

**Files:**
- Modify: `src/query.cj:118-160`

**Step 1:** `processIncluded` 清掉当前 `Raw("*")` 逻辑

改为把别名列附加到已有 SelectClause 末尾（Task 2 已确保基表列完整）。

**Step 2:** 别名列 = `table_alias.field AS "relName.field"`

如 `posts.id AS "posts.id"`，前缀 = `name + "."`。

**Step 3:** Build + test

手动验证 SQL 输出。

**Step 4:** Commit

---

### Task 5: include() — 包装 mapper

**Files:**
- Modify: `src/query.cj` — `include()` + `createIncludeMapper()`

**Step 1:** `include()` 调用 `wrapMapper(rel)`

```cangjie
public func include(rel: IRelation): Query<T> {
    included.add(rel)
    match (this.mapper) {
        case Some(m) =>
            this.mapper = Some(wrapMapper(m, rel))
        case None => ()
    }
    this
}
```

**Step 2:** `wrapMapper` 实现

```cangjie
private func wrapMapper<T>(
    baseMapper: (QueryResult, HashMap<String, Int64>) -> T,
    rel: IRelation
): (QueryResult, HashMap<String, Int64>) -> T {
    let (kind, name, _, _, _, fields) = rel.resolve()
    let targetMapper = rel.getTargetMapper()
    let setter = rel.getFieldSetter()

    func wrapper(result: QueryResult, columnMap: HashMap<String, Int64>): T {
        let entity = baseMapper(result, columnMap)
        if (columnMap.contains(name + ".id")) {
            let stripped = stripPrefix(columnMap, name + ".")
            let target = targetMapper(result, stripped)
            setter(entity, target)
        }
        entity
    }
    wrapper
}
```

**Step 3:** 实现 `stripPrefix`：

```cangjie
func stripPrefix(cm: HashMap<String, Int64>, prefix: String): HashMap<String, Int64> {
    var result = HashMap<String, Int64>()
    for (entry in cm.entries()) {
        if (entry.key.startsWith(prefix)) {
            result[entry.key.substring(prefix.size)] = entry.value
        }
    }
    result
}
```

**Step 4:** Build + test

**Step 5:** Commit

---

### Task 6: all() — HasMany 聚合

**Files:**
- Modify: `src/query.cj` — `all()`

**Step 1:** `all()` 检测是否有集合类型 include

```cangjie
public func all(): Array<T> {
    // ... render, execute ...
    if (hasCollectionInclude()) {
        aggregateWithCollections(result, columnMap, mapper)
    } else {
        simpleMap(result, columnMap, mapper)
    }
}
```

**Step 2:** `aggregateWithCollections` 实现

按主键（`id`）聚合：
```cangjie
var map = HashMap<Int64, T>()
while (result.next()) {
    let id = result.get<Int64>(columnMap["id"].getOrThrow())
    if (!map.contains(id)) {
        map[id] = baseMapper(result, columnMap)
    }
    let entity = map[id].getOrThrow()
    for (inc in included) {
        let (kind, name, _, _, _, _) = inc.resolve()
        if (kind == HasManyRel || kind == RefManyRel) {
            if (columnMap.contains(name + ".id")) {
                let target = inc.getTargetMapper()(result, stripPrefix(columnMap, name + "."))
                inc.getFieldSetter()(entity, target)  // ArrayList.add
            }
        }
    }
}
```

**Step 3:** Build + test

**Step 4:** Commit

---

### Task 7: Example — include 测试全开

**Files:**
- Modify: `example/src/main.cj`

**Step 1:** 启用所有 include 测试

- `User.query().include(UserRel.posts).all()` → HasMany
- `Post.query().include(PostRel.author).all()` → RefTo
- `User.query().include(UserRel.profile).all()` → HasOne

**Step 2:** 验证 `getAuthor()` / `getPosts()` / `getProfile()` 直接返回

**Step 3:** 全量构建 + 运行

Run: `cjpm build && cjpm test && cd example && cjpm build && cjpm run`

**Step 4:** Commit
