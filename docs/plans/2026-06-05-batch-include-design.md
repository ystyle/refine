# Eager Loading 分步查询方案

> **设计文档，非实现计划。** 讨论分步查询替代当前 LEFT JOIN 方案的设计。

**目标：** 解决多关联预加载时 LEFT JOIN 导致的笛卡尔积爆炸和无法嵌套 include 的问题。

---

## 当前方案的问题

当前 `processIncluded` 将关联以 LEFT JOIN 方式拼接到主查询：

```sql
-- include creator + items + tags
SELECT o.*, u.name AS creator.name, oi.id AS items.id, t.id AS tags.id
FROM orders o
LEFT JOIN users u ON o.creator_id = u.id
LEFT JOIN order_items oi ON o.id = oi.order_id
LEFT JOIN order_tags ot ON o.id = ot.order_id
LEFT JOIN tags t ON ot.tag_id = t.id
```

**三个问题：**

1. **笛卡尔积爆炸** — 5 个明细 × 3 个标签 = 15 行，多级 has_many 是乘法叠加
2. **同表多引用重复 JOIN** — 5 个 `@Ref[User]` 就 JOIN 5 次 `users`
3. **无法嵌套 include** — JOIN 出来的列别名只有一层，关联的关联无法映射

---

## 方案：分步查询

### 核心思路

```
Step 1: 查主实体          → SELECT * FROM orders WHERE ...
Step 2: 批量查所有 ref_to → SELECT * FROM users WHERE id IN (所有外键)
Step 3: 批量查所有 has_many → SELECT * FROM order_items WHERE order_id IN (主键列表)
                              SELECT * FROM comments WHERE post_id IN (主键列表)
Step 4: 批量查所有 ref_many → SELECT t.* FROM order_tags ot JOIN tags t
                              WHERE ot.order_id IN (主键列表)
```

### 关键优化：按目标表去重

所有指向同一目标表的 `@Ref`（如 5 个 `@Ref[User]`）合并为**一次**查询：

```
Step 2: SELECT * FROM users WHERE id IN (
    <creator_id 集合> ∪ <updater_id 集合> ∪ <reviewer_id 集合> ∪ ...
)
```

返回后按 id 建立 `HashMap<Int64, User>` 查找表，每条主实体按各自外键取值。

### 查询计划

```
输入: Query<T> 的 included 列表
输出: 填充完关联的 Array<T>

1. 执行主查询 (all/one)
   → entities: Array<T>

2. 按关联类型分组：
   ref_to_targets  = Map<目标表名, [IRelation]>
   has_one_targets = Map<目标表名, [IRelation]>
   has_many_targets = Map<目标表名, [IRelation]>
   ref_many_targets = Map<目标表名, [IRelation]>

3. 批量 ref_to：
   for each (targetTable, rels) in ref_to_targets:
     收集所有 entities 中对应 rel 的外键值
     SELECT * FROM targetTable WHERE id IN (去重后的外键集合)
     按 id 构建 HashMap<PK, TargetEntity>
     遍历 entities，按外键从 HashMap 取值赋给 entity.rel

4. 批量 has_one / has_many：
   for each (targetTable, rels) in has_many_targets:
     收集所有 entities 的 id
     SELECT * FROM targetTable WHERE fk IN (主键集合)
     按 fk 分组构建 HashMap<FK, Array<TargetEntity>>
     遍历 entities，从 HashMap 取值赋给 entity.rel

5. 批量 ref_many：
   for each (targetTable, rels) in ref_many_targets:
     收集所有 entities 的 id
     SELECT t.* FROM viaTable j JOIN targetTable t ON j.target_id = t.id
     WHERE j.source_id IN (主键集合)
     按 source_id 分组构建 HashMap<ID, Array<TargetEntity>>
     遍历 entities，从 HashMap 取值赋给 entity.rel
```

### 嵌套 include

分步查可以递归进行。如果 `include(OrderRel.creator)` 并且 `User` 实体上也有 include，在 Step 3 查出 User 后可递归执行分步查：

```
Step 1: SELECT * FROM orders
Step 2: SELECT * FROM users WHERE id IN (creator_ids)
Step 3: SELECT * FROM profiles WHERE user_id IN (user_ids)  ← 递归 User 的 include
```

实现方式：`Query<T>` 上保存 `included`，在分步查出目标实体后，对目标实体递归执行 `queryAll(sql, params, mapper)` + `processIncludedStepByStep`。

### 数据分组合并

当前 `aggregateWithCollections` 在 Join 方案中做去重，改为分步方案后不再需要：

```cangjie
// 分步查后
for (entity in entities) {
    let fk = entity.getField(rel.foreignKey)
    match (batchResult.get(fk)) {
        case Some(target) => entity.rel = target
        case None => entity.rel = None  // 无关联
    }
}
```

### 接口变化

`IRelation` 新增可选方法：

```cangjie
public interface IRelation {
    func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>)
    func getTargetMapper(): (QueryResult, HashMap<String, Int64>) -> Any
    func getFieldSetter(): (Any, Any) -> Unit

    // 新增：标记该关联是否支持分步查询（默认 true）
    func isBatchSupported(): Bool { true }
}
```

`Query<T>` 新增：

```cangjie
public var useBatchInclude: Bool = true  // 默认启用分步查

public func enableBatchInclude(v: Bool): Query<T> { useBatchInclude = v; this }
```

`processIncluded` 被拆分为两个分支：

```cangjie
public func processIncluded(dialect: Dialect): Unit {
    if (useBatchInclude) {
        // 不生成 JOIN，稍后在 all/one 中分步查
        return
    }
    // 原有 JOIN 逻辑
}
```

### 兼容性

- 默认启用分步查（`useBatchInclude = true`）
- 可通过 `.enableBatchInclude(false)` 切回 JOIN 模式
- 单表 ref_to 场景 JOIN 方式和分步查性能等价，分步查多一次查询但无数据冗余
- 多 has_many 场景分步查显著优于 JOIN

---

## 总结

| | LEFT JOIN（当前） | 分步查（方案） |
|---|---|---|
| 查询次数 | 1 | 1 + N (关联种类数) |
| 同表多 ref | 多次 JOIN | 合并为 1 次 |
| 数据冗余 | 笛卡尔积 | 无 |
| 多个 has_many | 乘法 | 加法 |
| 嵌套 include | ❌ | ✅ |
| 实现复杂度 | 低（已实现） | 中 |

**建议实现顺序：**

1. `IRelation` 新增 `batchTargetTable()` 方法（返回去重用的目标表名）
2. `Query<T>` 新增 `useBatchInclude` 字段 + 分步执行方法
3. 重写 `all()` / `one()` 中 include 处理逻辑
4. 保留 JOIN 模式作为可选降级
5. 测试覆盖：单 ref / 多同表 ref / 多 has_many / ref_many / 嵌套
