# 级联保存设计：has/ref 关联的 save/update/delete 自动级联

日期：2026-08-01
分支：feature/cascade-save

## 背景

第二批（乐观锁/审计字段/隔离级别）已完成。本批实现关联级联：用户填充实体的关联字段后，`tx.save` / `tx.update` / `tx.delete` 自动遍历关联字段处理子对象，无需手动逐层 save。

## 1. 关联语义

四种关联（`@Ref` / `@Rel`）的级联行为严格区分「拥有」与「引用」：

| 关联 | save/update 级联 | delete 级联 |
|---|---|---|
| `has_many` / `has_one`（`@Rel`，拥有，fk 在子表） | 级联存子对象：子有 id → `tx.update`，无 id → `tx.save`；父 id 回填子 fk | **跟随子实体自身策略**：子有 `deleted_at` 字段 → 软删；否则物理删 |
| `ref_to`（`@Ref[Target, fk]`，引用，fk 在父表） | **只维护 fk**：关联对象 `Some(u)` 且 `u.id != 0` → 把 `u.id` 回填 fk；关联 `None` 或 id 为 0/空 → fk 清零（数值→0，String→空字符）。**完全不管被引对象本身**（不 save/update/delete 源表行） | 不处理 |
| `ref_many`（`@Ref[Target, via: j]`，多对多，中间表） | **只 CRUD 中间表**：按关联列表重建中间表记录（增删）。**不碰目标表** | **清空该实体的中间表记录** |

规则核心：
- **has 系（拥有）**：子对象是父的一部分，生命周期跟随父。
- **ref 系（引用）**：被引对象独立存在，ORM 完全不管其行数据；ref_to 只管 fk 字段值，ref_many 只管中间表。

## 1.5 ref_many 关联管理 API（GORM v2 风格六件套）

当前 ref_many 只有 `loadX(tx)`（JOIN 查询）与 `getX()`（返回字段值），中间表操作需手写 SQL。本批新增实体方法六件套（须在事务内调用，均要求 `tx: Tx` 参数）：

| 方法 | 签名 | 行为 |
|---|---|---|
| `appendX` | `appendTags(tx, tag: Tag): Post` / `appendTags(tx, tags: Array<Tag>): Post` | 追加关联（INSERT 中间表） |
| `replaceX` | `replaceTags(tx, tags: Array<Tag>): Post` | 全量替换（清旧中间表 + 插新） |
| `deleteX` | `deleteTags(tx, tag: Tag): Post` / `deleteTags(tx, tags: Array<Tag>): Post` | 移除指定关联（DELETE 中间表对应行） |
| `clearX` | `clearTags(tx): Post` | 清空全部关联 |
| `countX` | `countTags(tx): Int64` | 中间表计数 |
| `loadX` | `loadTags(tx): Array<Tag>`（已有） | 查询关联 |

- 单对象/数组双重重载（append / delete）
- 全部返回链式 `this`（除 count 返回 Int64、load 返回数组），与现有 `addX`/`clearX` 链式风格一致
- 目标对象 id 为空（新对象）时：append/delete 抛异常（「先保存目标对象以获取 id」），防静默丢关联
- 中间表写入必须原子：方法强制 `tx` 参数，不在内部开事务
- 级联保存的 ref_many 重建逻辑复用本套方法的中间表操作（INSERT/DELETE），两者并存

### ref_to fk 维护细节

`@Ref[User, user_id]` 声明在 Post 上，fk 字段是 `user_id`。级联时：

```
entity.author = Some(u) 且 u.id != 0  → entity.user_id = u.id
entity.author = None                 → entity.user_id = 0（数值）/ ""（String）
entity.author = Some(u) 且 u.id == 0 → 报错？还是回填后不管？
```

**决策**：`Some(u)` 且 `u.id != 0` → 回填 `user_id`。`Some(u)` 且 `u.id == 0` → 抛出异常「ref_to 关联对象必须先保存以获得 id」（防静默丢引用）。`None` → fk 清零。

### ref_many 中间表重建

`@Ref[Tag, via: post_tags]`，source 表 post，target 表 tag。级联 save/update 时：
1. `DELETE FROM post_tags WHERE post_id = ?`（清旧）
2. 对关联列表每个 tag：`INSERT INTO post_tags (post_id, tag_id) VALUES (?, ?)`

delete 时只执行第 1 步。

## 2. 递归与循环检测

- 从根实体递归遍历关联图，**无限深度**。
- 维护已访问集合（`Array<(String, String)>` 记录 `(entityType, id)` 或对象引用集合），环上重复节点跳过不重复处理。
- 深链示例：Order → items → product → category → ... 自动递归。

## 3. update 语义

- 子对象有 id → `tx.update`（含乐观锁 version 校验、审计 updated_at 刷新）
- 子对象无 id → `tx.save`（含审计 created_at/updated_at、version 0→1）
- 列表移除不自动删库（用户显式 `tx.delete` 或 delete 级联）
- has_one：`Some(sub)` → 存子；`None` 不处理（用户显式删）

## 4. 关联字段修改标记（宏生成）

区分「用户没碰关联字段」vs「用户显式设空/设值」，否则空 ArrayList 会误触发「清空子对象」。

### 方案：宏改写关联字段为 `mut prop` + 内部标记

宏为每个关联字段生成：
1. 保留原字段（改私有名如 `_posts`）
2. 生成同名 `public mut prop posts: ArrayList<Post>`：
   - getter 返回 `_posts`
   - setter：`_posts = v; _postsModified = true`
3. 生成 `_postsModified: Bool` 内部标记（默认 false）

用户代码兼容性：
- `u.posts = [...]` → 走 setter → 置标记 ✓
- `u.posts.add(p)` → 走 getter 返回 ArrayList 再 add → **标记不置位**（需用户用 `u.posts = [...]` 整体赋值，或宏同时生成 `setPosts(list)` 便捷方法；文档说明）

**关键约束**：仓颉 `mut prop` 不能声明在数值/String/Bool/enum 类型上，但 `ArrayList<T>` / `Option<T>` 是引用类型（类），**可以**。已核实属性文档（manual prop.md）。

### 遍历时机

- `tx.save` / `tx.update`：只处理标记为 true 的关联字段
- `tx.delete`：处理所有关联字段（delete 不看标记）
- 递归子对象时，子对象自己的关联字段标记由子对象自身状态决定

### 空列表语义

- 标记 true 且列表为空（`u.posts = []`）→ save 视为无子对象要存；update 不删现有（不自动清库）
- 标记 true 且 ref_many 列表为空 → 中间表清空（重建为空 = 清旧关联）

## 5. 实现位置

`src/macros/refine_macro.cj`：

1. **字段改写**（Refine 宏主流程）：识别关联字段（`isRelationField`），改写为 mut prop + 标记
2. **buildRelationMethods** 扩展：生成级联遍历辅助函数（`cascadeSave(tx, visited)` / `cascadeDelete(tx, visited)`）
3. **buildTxSaveExtend** / **buildTxUpdateExtend** / **buildTxDeleteExtend**：钩子之后、SQL 之前/之后插入级联调用

级联顺序：
1. 先保存父实体（拿 id）
2. has_many / has_one：回填父 id 到子 fk → 递归存子
3. ref_to：维护 fk（回填/清零）
4. ref_many：重建中间表

delete 顺序：
1. 先递归删子（has 系）
2. 清中间表（ref_many）
3. 再删父

## 6. 边界与约定

- 循环引用：A → has_many B，B → ref_to A。递归时 visited 已含 A，跳过不再处理。
- 深递归性能：visited 用哈希/数组，O(n)。
- `tx.save` 父无 id（自增主键）→ 先 save 拿到 id 再回填子 fk。
- 批处理 `batchSave` / `batchUpdate` **不级联**（保持现状），用户需逐个 save 或手动处理。
- 钩子触发：子对象的 save/update/delete 走正常 `tx.save`/`tx.update`/`tx.delete`，各自触发钩子。
- 软删除：has 系子对象跟随自身策略（有 deleted_at → 软删）。

## 7. 测试策略

### 单元测试（src/macro_test.cj）

- 宏展开：关联字段被改写为 mut prop + 标记；生成级联辅助函数
- 修改标记：赋值置位、未赋值不置位
- SQL 生成：级联遍历生成的 save/update/delete 序列

### 双库集成测试（example/）

- 保存：User 带 posts + profile → 一次 `tx.save(user)` 全部落库，fk 回填正确
- 更新：改 user 名 + 改 post 标题 + 新增 post → `tx.update(user)` 分别 update/save
- 删除：`tx.delete(user)` → posts 级联删、profile 删
- ref_to：`post.author = Some(u)` → 回填 user_id；`None` → 清零
- ref_many：`post.tags = [...]` → 中间表重建
- 循环：A ↔ B 互引不死循环
- 深链：三层嵌套
- 乐观锁：级联 update 子对象带 version 校验
- 软删：子实体有 deleted_at → 级联软删

### ref_many 六件套测试

- `appendX`：单对象追加 + 数组批量追加，中间表 INSERT 正确
- `replaceX`：先清旧再插新，结果与列表一致
- `deleteX`：单对象 + 数组删除，DELETE 中间表对应行
- `clearX`：清空中间表
- `countX`：计数正确
- 目标 id 为空（新对象）时 append/delete 抛异常
- 双库各跑一遍（MySQL / PG），与现有 ServiceChecks 模式一致

## 8. 不做的（YAGNI）

- 列表差集全量同步（update 时列表移除不自动删库）
- 批处理级联（batchSave/batchUpdate 不级联）
- ref_to 被引对象的任何行操作（save/update/delete 源表）
- 级联保存时的显式配置项（`@Cascade` 注解等）——本设计为固定语义，符合 has/ref 区分
- ref_many 六件套之外的 GORM 特性（如 Association 链式上下文、带条件 count、预加载配置）
