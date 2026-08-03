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
| `ref_to`（`@Ref[Target, fk]`，引用，fk 在父表） | **只维护 fk**：关联对象 `Some(u)` 且 `u.id != 0` → 把 `u.id` 回填 fk；关联 `None` 或 id 为 0/空 → fk 清零（数值→0，String→空字符）。**完全不管被引对象本身**（不 insert/save/update/delete 源表行） | 不处理 |
| `ref_many`（`@Ref[Target, via: j]`，多对多，中间表） | **只 CRUD 中间表**：按关联列表重建中间表记录（增删）。**不碰目标表**（不 insert/save/update/delete） | **清空该实体的中间表记录** |

规则核心：
- **has 系（拥有）**：子对象是父的一部分，生命周期跟随父。
- **ref 系（引用）**：被引对象独立存在，ORM **完全不管其源表行数据（含 insert）**——添加源表在现代软件中往往有权限控制（审计、归属、校验），ORM 不应越权；无需权限的场景开发者手动 `tx.save` 即可。ref_to 只管 fk 字段值，ref_many 只管中间表。

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
- 目标对象 id 为空（新对象）时：append/delete 抛异常（「先手动保存目标对象以获取 id」，ORM 不代为 insert 目标表），防静默丢关联
- 中间表写入必须原子：方法强制 `tx` 参数，不在内部开事务
- 级联保存的 ref_many 重建逻辑复用本套方法的中间表操作（INSERT/DELETE），两者并存

### ref_to fk 维护细节

`@Ref[User, user_id]` 声明在 Post 上，fk 字段是 `user_id`。级联时：

```
entity.author = Some(u) 且 u.id != 0  → entity.user_id = u.id（回填）
entity.author = Some(u) 且 u.id == 0  → entity.user_id = 0 / ""（视为清空）
entity.author = None                 → entity.user_id = 0 / ""（清空）
```

**决策**：`Some(u)` 且 `u.id != 0` → 回填 `user_id`。`Some(u)` 且 `u.id == 0` → **视为清空 fk**（与 `None` 等价，数值→0、String→空字符）。`None` → 清空 fk。

**JSON 场景考虑**：HTTP + JSON 下 `null` 与 `0` 常常无法区分——许多 JSON 反序列化库会忽略 `null` 字段（字段保持默认 `None`），客户端想表达「清空关联」时只能显式传 `0`（或空字符串）。因此 **`u.id == 0` 不再抛异常，而是与 `None` 统一为「清空」**，保证 JSON 场景语义正确（同 Go/GORM 的 JSON 行为）。ORM 仍不代为 insert 源表：用户要建立新引用，需先手动 `tx.save` 目标对象拿到 id 再回填。

> 语义统一：`None` 与 `Some(0)` 均表示「清除该 fk 引用」。若未来需要区分「未设置」与「显式清除」，由字段修改标记（第 4 节）承担——标记 false（未赋值）时级联不处理该字段，标记 true 且 fk 为 0/空时清空。

### ref_many 中间表重建

`@Ref[Tag, via: post_tags]`，source 表 post，target 表 tag。级联 save/update 时：
1. `DELETE FROM post_tags WHERE post_id = ?`（清旧）
2. 对关联列表每个 tag：`INSERT INTO post_tags (post_id, tag_id) VALUES (?, ?)`

delete 时只执行第 1 步。

## 2. 递归与循环检测

- 从根实体递归遍历关联图，**无限深度**。
- 维护已访问集合，**按对象引用（identity）判断，不用 (type, id)**——因为级联中新对象 id 都是 0，用 (type, id) 会把两个不同新对象误判为同一对象而跳过。用对象引用集合（`Array<Any>` 存实体引用，`contains` 判断），环上重复节点跳过不重复处理。
- **delete 路径的 visited 与 save/update 不同**：级联删除用 `<Class>:<pk...>` 键（`loadX` 每次新建实体实例，refEq 无法识别 DB 常驻环），键是值类型 String，实现上用 `CascadeVisitedKeys`（`= HashSet<String>`，refine 包公开类型别名）提供 O(1) contains。save/update 的对象引用 visited 保持 `ArrayList<Object>` O(n) 线性扫描——仓颉无 identity-based 哈希集合（`HashSet`/`HashMap` 均按 Equatable 的 `==` 散列，实体默认值语义无法承载 refEq），见 `src/refine.cj` `visitedContains` 注释（2026-08 P1 审计 F2(c)）。
- 深链示例：Order → items → product → category → ... 自动递归。

## 3. update 语义

- 子对象有 id → `tx.update`（含乐观锁 version 校验、审计 updated_at 刷新）
- 子对象无 id → `tx.save`（含审计 created_at/updated_at、version 0→1）
- 列表移除不自动删库（用户显式 `tx.delete` 或 delete 级联）
- has_one：`Some(sub)` → 存子；`None` 不处理（用户显式删）
- has_many 子对象已有 id（跨父迁移，如 `b.posts = [p]`）→ 级联 update 回填子 fk 为当前父 id（见第 5 节阶段 3）
- **环/菱形保护**：`tx.save/update/delete` 级联递归时，**同一 visited 集合贯穿整个递归路径**（父 save → 子 save → 孙 save 共享一个 visited）。在 save/update/delete 的**操作层**守卫已访问实体（而非仅 cascade body 层），防止环 A↔B 时重复 INSERT/DELETE 或无限递归。子对象落库前检查 visited，已访问则跳过。

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

**rowMapper 不得误置标记（关键）**：宏生成的 `buildRowMapper` 在从数据库加载实体时给关联字段赋值。若走公开 setter（`entity.posts = ...`）会置标记为 true，导致「仅加载未修改」的实体在 update 时也被级联处理（重建中间表、回填 fk 等不期望副作用）。修正：**rowMapper 对关联字段直接赋值私有字段**（`entity._posts = ...`，不触发 setter、不置标记），或加载完成后统一重置标记为 false。加载的实体标记保持 false，只有用户显式赋值才置位。

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

级联顺序（save/update 时）：

```
阶段 1（父 SQL 前）: ref_to 维护 fk——回填 u.id 到 fk（如 post.user_id = u.id），或清空
阶段 2:            父实体 save/update（此时 fk 已是正确值，一并写入）
阶段 3（父 SQL 后）: has_many / has_one——回填父 id 到子 fk → 递归存子
阶段 4:            ref_many——重建中间表
```

> **ref_to 必须在父 save 前**：ref_to 的 fk 是父表自己的列（如 `post.user_id`）。若在父 INSERT 后才回填，父行写入的 user_id 是旧值（0），还需额外 UPDATE 父行。故阶段 1 先改 fk，阶段 2 父 save 直接把正确 fk 落库。

**has_many fk 回填**：子对象无 id → save 后回填父 id 到子 fk。子对象**已有 id**（如把 post 从 user A 迁移到 user B：`b.posts = [p]`）→ 级联 update 时同样回填 `p.user_id = b.id`（拥有关系下子对象归属跟随父）。

delete 顺序：
1. 先递归删子（has 系）
2. 清中间表（ref_many）
3. 再删父

**级联 delete 不依赖内存列表（决策）**：`cascadeDelete` 对 has 系子对象**按 fk 直接执行 SQL**，不遍历内存列表——用户 `tx.delete(user)` 时即使未 `loadPosts`/include，子行也会全部清理，符合直觉且无孤儿行。每个实体生成一个「按 fk 删除自己」的辅助方法（子实体自知是否软删）：物理删实体 `DELETE FROM <table> WHERE <fk> = ?`，软删实体 `UPDATE <table> SET deleted_at = ? WHERE <fk> = ?`。父实体的 `cascadeDelete` 调用子实体的按 fk 删除方法，传入子表 fk 列名与父 id。ref_many 清中间表同理。

## 6. 边界与约定

- 循环引用：A → has_many B，B → ref_to A。递归时 visited 已含 A，跳过不再处理。
- 深递归性能：visited 用哈希/数组，O(n)。
- `tx.save` 父无 id（自增主键）→ 先 save 拿到 id 再回填子 fk。
- 批处理 `batchSave` / `batchUpdate` **不级联**（保持现状），用户需逐个 save 或手动处理。
- 钩子触发：子对象的 save/update/delete 走正常 `tx.save`/`tx.update`/`tx.delete`，各自触发钩子。
- 软删除：has 系子对象跟随自身策略（有 deleted_at → 软删）。

## 6.5 已知限制

- **has_one 关联的 String 主键目标实体**：父实体 rowMapper 的 include/JOIN 加载暂不支持（宏层无法跨类内省目标实体主键类型，`result.get<Int64>` 会类型错配导致父实体编译失败）。cascade save/delete 不受影响——has 系走 `loadX(tx)`（含目标实体自身 rowMapper，类型正确）。ref_to 的 String-pk 目标已支持（fk 字段在当前实体上，类型可推导）。

## 6.6 事务与原子性（2026-08 P1 审计 F3）

**级联操作本身不具备跨语句原子性，必须放在事务中使用。**

- 级联 save/update/delete 由 `tx.save` / `tx.update` / `tx.delete` 触发，全程共用同一个 `tx`——一次级联会执行多条 SQL（父 + 子 + 中间表）。若在**自动提交**（非事务）上下文中直接调用，每条 SQL 独立提交，中途失败会留下**部分落库**（部分子对象已写、部分未写），无法整体回滚。
- 正确用法：级联写操作一律包在 `rf.transaction { tx => ... }` 内（或手动 `begin/commit/rollback`）。事务回滚时，级联产生的全部写入一起回滚，保证原子性。
- `tx.save` / `tx.update` / `tx.delete` 不会隐式开启事务——它们只是「在同一执行上下文上按序执行多条语句」，并不改变底层连接的提交模式。
- 只读级联（`loadX`、include 预加载）不涉及写入，无此约束。
- 相关实现位置：`src/macros/tx_gen.cj`（saveCascade/updateCascade/deleteCascade 全部在同一 extend Tx 内、复用传入 tx）、`src/macros/relation_gen.cj`（cascadePreSave/cascadePostSave/cascadeDelete）。

### 物理删父 + 软删子：孤儿策略（2026-08 P1 审计 F3）

`tx.physicalDelete(parent)` 硬删父实体时，子对象（has 系）仍按**子实体自身策略**处理：

- 子实体是软删模型（有 `deleted_at`）→ `cascadeDelete` 走 `tx.deleteCascade`（软删：`UPDATE deleted_at`），子行**保留**。
- 父行随后被物理删除。

结果：软删子的 `deleted_at` 置位、行仍在，但其外键指向的父行已物理删除——形成**孤儿行**。

**这是有意的策略**：软删子保留历史/审计/恢复能力，物理删父不应连带把子历史抹掉。代价是子行的外键悬空（访问父记录会命中已删父的软删影子或不存在行）。约束与取舍：

- 若需要「物理删父时物理删子」（不留孤儿），需在删父前手动 `tx.delete` 子对象（子仍软删）或用物理删逐个处理——ORM 不提供「物理删父强制级联物理删子」的开关。
- 全软删路径（`tx.delete` 软删父）不会产生孤儿：父、子都是 `UPDATE deleted_at`，行都在，仅查询过滤。
- 测试固化：`TxPhysicalDeleteCascadeTest.testTxPhysicalDeleteCascadesChildren`（物理删父 + 软删子，断言子仅软删、父物理删、无 DELETE 子行）。

实现位置：`src/macros/tx_gen.cj` `buildTxSoftDeleteExtend`（physicalDelete → physicalDeleteCascade → `entity.cascadeDelete(this, visited)` 递归子，子按自身策略软删，父走 DeleteSQL 硬删）。

## 7. 测试策略

### 单元测试（src/macro_test.cj）

- 宏展开：关联字段被改写为 mut prop + 标记；生成级联辅助函数
- 修改标记：赋值置位、未赋值不置位
- **rowMapper 不置标记**：从 mock 结果映射实体后，关联字段标记保持 false（仅加载未修改的实体 update 不触发级联）
- **循环检测用对象引用**：两个无 id 新对象互不误判；A ↔ B 环不死循环
- SQL 生成：级联遍历生成的 save/update/delete 序列

### 双库集成测试（example/）

- 保存：User 带 posts + profile → 一次 `tx.save(user)` 全部落库，fk 回填正确
- 更新：改 user 名 + 改 post 标题 + 新增 post → `tx.update(user)` 分别 update/save
- **加载后未修改即 update**：load user → 不改关联字段 → `tx.update(user)` 不触发任何关联级联（无中间表重建、无 fk 改动）
- **跨父迁移**：`b.posts = [p]`（p 已有 id）→ 级联 update 后 `p.user_id == b.id`
- **ref_to 时机**：`post.author = Some(u)` 后 save → 父行 user_id 直接落库正确（无需二次 UPDATE，可用 SQL 日志或断言验证）
- 删除：`tx.delete(user)` → posts 级联删、profile 删
- ref_to：`post.author = Some(u)` → 回填 user_id；`None` 或 `Some(0)` → 清零
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
- ref 系被引对象的**任何**源表操作（save/update/delete/insert 全部不做）——包括 ref_to 和 ref_many 的目标表。原因：现代软件中往源表插入数据往往有权限控制（如审计、归属、校验），ORM 不应越权；无需权限的场景开发者手动 `tx.save` 也不碍事。ref 系仅维护外键与中间表
- 级联保存时的显式配置项（`@Cascade` 注解等）——本设计为固定语义，符合 has/ref 区分
- ref_many 六件套之外的 GORM 特性（如 Association 链式上下文、带条件 count、预加载配置）
