# ID 系统重设计 — UUID / 复合主键 / 隐式规则

> **For Claude:** 设计文档，非实现计划。

**目标：** 支持 String UUID 主键、复合主键、无 `id` 字段实体，同时保持 `id: Int64` 自增主键零改动。

---

## 设计原则

1. **兼容优先**：现有 `id: Int64` 实体零改动
2. **隐式优于显式**：有 `id` 字段按类型推导规则，无 `id` 或复合主键才需 `@Id`
3. **运行时无反射**：所有分叉在宏编译期完成
4. **IdGenerator 可替换**：不硬编码 UUID 实现

---

## 方案：隐式规则 + @Id 显式标记

### 规则矩阵

| id 字段 | `@Id` | 行为 |
|---|---|---|
| `id: Int64` | 无 | 自增主键（**现有行为，零改动**） |
| `id: String` | 无 | UUID 主键，INSERT 包含 id 列，空时 `idGenerator.generate()` |
| 无 | 无 | 编译错误："实体缺少主键" |
| `id: Int64` | `@Id(auto=false)` | 用户手动设值，不加自增 |
| `id: String` | `@Id` | 同上（不加注解也一样） |
| 复合（多个 `@Id`） | 多个 `@Id` | 复合主键，WHERE pk1=? AND pk2=? |

### @Id 注解设计

```cangjie
public macro Id(attr: Tokens, input: Tokens): Tokens
```

参数：
- `auto` — `Bool`，仅对 `Int64` 有效，默认 `true`。设为 `false` 时关闭自增

示例：

```cangjie
@Refine
class User {
    var id: Int64 = 0           // 隐式：自增（零改动）
}

@Refine
class Order {
    var id: String = ""         // 隐式：UUID
}

@Refine
class Legacy {
    @Id(auto=false)
    var id: Int64 = 0           // 显式：不自增
}

@Refine
class OrderTag {
    @Id var order_id: Int64 = 0
    @Id var tag_id: Int64 = 0   // 复合主键
}
```

---

## 宏改动的 6 个分叉点

### 1. INSERT SQL (`buildInsertSQLString`)

| 场景 | INSERT |
|---|---|
| `id: Int64` 无 `@Id` | 不含 id 列（自增） |
| `id: Int64` + `@Id(auto=false)` | 含 id 列 |
| `id: String` | 含 id 列 |
| 复合主键（多个 `@Id`） | 含所有主键列 |

生成 SQL 时，遍历所有字段（跳过 relation 字段）：

```cangjie
for (f in fields) {
    if (f.name == "id" && isAutoId) { continue }     // 自增跳 id
    if (isRelationField(f.typeName)) { continue }     // 关联跳
    colNames.add(f.name)
}
```

### 2. UPDATE WHERE (`buildUpdateSQLString`)

| 场景 | WHERE 子句 |
|---|---|
| 单主键 `id` | `WHERE id = ?` |
| 复合主键 | `WHERE pk1 = ? AND pk2 = ?` |

### 3. DELETE WHERE (`buildDeleteSQLString`)

同 UPDATE，`WHERE pk1 = ? AND pk2 = ?`。

### 4. RowMapper

| 场景 | id 类型 |
|---|---|
| `id: Int64` | `result.get<Int64>("id")`（当前代码） |
| `id: String` | `result.get<String>("id")` |
| 复合主键 | 每个 `@Id` 字段各自读 |

### 5. aggregateWithCollections 去重 key

当前硬编码 `result.get<Int64>("id")`。改为统一 `HashMap<String, T>`：

```cangjie
// 不再区分 Int64/String，key 统一为 String
var map = HashMap<String, T>()

// Int64 id → key = id.toString()
// String id → key = id
// 复合主键 → key = "pk1:pk2:pk3"
```

### 6. 关联方法（loadXxx / addXxx / setXxx）

当前硬编码 `this.id`，改为读取主键字段：

| 方法 | 当前 | 复合主键时 |
|---|---|---|
| `loadPosts(tx)` | `WHERE post_id = this.id` | `WHERE post_id = this.order_id` |
| `addPost(tx, entity)` | `entity.user_id = this.id` | `entity.fk = this.pk` |

---

## IdGenerator 接口

```cangjie
public interface IdGenerator {
    func generate(): String
}

public class UuidGenerator <: IdGenerator {
    public func generate(): String {
        // UUID v4 实现
    }
}
```

- 默认 `UuidGenerator`，注册在 Refine 实例上
- 可通过 `rf.setIdGenerator(impl)` 替换为 ULID / Snowflake / 自定义

```cangjie
// 默认
let rf = Refine.open("sqlite:test.db")
// uuid = UuidGenerator.generate()

// 自定义
rf.setIdGenerator(MySnowflakeGenerator())
```

---

## 错误处理

| 场景 | 编译/运行时行为 |
|---|---|
| 无 id 字段 且 无 `@Id` | 编译错误 |
| `@Id` 标记了非 id 字段但 auto=true | 编译警告并忽略 auto |
| IdGenerator.generate() 返回空 | 运行时抛出异常 |
| 复合主键的实体做 include | 暂不支持，编译警告 |

---

## 实现顺序建议

1. **宏检测 `id` 类型分叉** + INSERT/UPDATE/DELETE SQL 调整
2. **IdGenerator 接口 + 默认 UUID 实现**
3. **复合主键**（`@Id` 多个标记）
4. **aggregateWithCollections 统一 HashMap<String, T>**
5. **关联方法适配**
6. **测试 + 文档**
