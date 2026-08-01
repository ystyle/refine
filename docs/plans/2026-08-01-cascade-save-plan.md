# 级联保存实现计划：has/ref 关联 save/update/delete 自动级联 + ref_many 六件套

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现关联级联：用户填充实体的关联字段后，`tx.save`/`tx.update`/`tx.delete` 自动递归处理子对象；并为 ref_many 提供 GORM v2 风格六件套关联管理 API。

**Architecture:** 全部在宏层（`refine_macro.cj`）实现。核心机制：宏把实体的关联字段改写为 `mut prop` + 内部修改标记（setter 置位），`rowMapper` 直接赋私有字段避免误置标记；`Tx.save/update/delete` 扩展方法在事务钩子前后调用宏生成的级联遍历辅助函数（按对象引用 visited 防循环）。ref_many 六件套生成到实体方法，复用中间表操作。

**Tech Stack:** 仓颉（Cangjie）语言，宏编程（std.ast / quote / PropDecl），stdx 驱动（mariadb/pgsql），cjpm 构建。

**设计文档：** `docs/plans/2026-08-01-cascade-save-design.md`

---

### Task 1: 关联字段改写为 mut prop + 修改标记（基础机制）

**Files:**
- Modify: `src/macros/refine_macro.cj`
- Test: `src/macro_test.cj`

**背景**：当前实体关联字段是普通 `var posts: ArrayList<Post> = ...`。需改为：
```
private var _posts: ArrayList<Post> = <原初始化>
public var _postsModified: Bool = false
public mut prop posts: ArrayList<Post> {
    get() { _posts }
    set(v) { _posts = v; _postsModified = true }
}
```

**Step 1: 写失败测试**

在 `src/macro_test.cj` 添加断言：关联字段改写后存在 `_postsModified` 标记、赋值 `u.posts = [...]` 后标记为 true。测试实体用一个带 `@Rel[has_many]` 的实体（复用已有 Post/Comment 或新建 CascadeUser）。

先读 `src/macro_test.cj` 现有实体与测试模式，确认怎么访问生成的 prop/标记。

**Step 2: 运行确认失败**

Run: `cjpm test --filter 'CascadeTest'`（或对应类名）
Expected: FAIL（编译错误，字段未被改写）

**Step 3: 实现字段改写**

在 Refine 宏主流程（`extractFields` 之后、构建其他声明之前）新增 `rewriteRelationFields(cd, mergedRels)`：

- 对每个关联字段（mergedRels 里的 fieldName）：
  - 找到对应 `VarDecl`，读取其类型与初始化
  - 移除原 VarDecl，替换为：
    - `private var _<name>: <Type> = <原初始化>`
    - `public var _<name>Modified: Bool = false`
    - `public mut prop <name>: <Type> { get() { _<name> } set(v) { _<name> = v; _<name>Modified = true } }`
  - 用 `PropDecl`（quote 构造）与 `VarDecl` 组装，`cd.body.decls` 替换

**关键**：引用类型（`ArrayList<T>` / `Option<T>`）才改写。非关联字段不动。被改写的字段后续所有宏生成代码引用点（rowMapper/colsStruct/buildRelationMethods 里的 `this.xxx`）需用 prop 名（同名，自动兼容）或私有名，逐一核对。

**Step 4: 运行确认通过**

Run: `cjpm build && cjpm test`
Expected: 全绿（现有关联功能不回归——prop getter 返回 `_xxx`，`this.posts` 语义不变）

**Step 5: 提交**

```bash
git add src/macros/refine_macro.cj src/macro_test.cj
git commit -m "feat: 关联字段改写为 mut prop + 修改标记"
```

---

### Task 2: rowMapper 不置标记（加载不污染）

**Files:**
- Modify: `src/macros/refine_macro.cj`
- Test: `src/macro_test.cj`

**Step 1: 写失败测试**

断言：从 mock 结果映射实体后，关联字段标记保持 false（`entity._postsModified == false`）。

**Step 2: 运行确认失败**

Expected: FAIL（当前 rowMapper 走 setter 置标记）

**Step 3: 实现**

修改 `buildRowMapper`（约 1330 行）：
- ref_to / has_one 的赋值（`entity.xxx = Some(tmp)`，1374-1392 行）改为直接赋私有字段：`entity._xxx = Some(tmp)`（不触发 setter）
- 检查 buildRowMapper 是否有对其他关联字段的赋值路径，统一处理

**Step 4: 运行确认通过**

Run: `cjpm build && cjpm test`
Expected: 全绿

**Step 5: 提交**

```bash
git add src/macros/refine_macro.cj src/macro_test.cj
git commit -m "feat: rowMapper 直接赋私有关联字段，加载不置标记"
```

---

### Task 3: ref_many 六件套 API 生成

**Files:**
- Modify: `src/macros/refine_macro.cj`
- Modify: `src/dialect*.cj`（如需方言化 SQL）
- Test: `src/macro_test.cj`

**Step 1: 读现有 ref_many 生成**

读 `buildRelationMethods` 的 `ref_many` 分支（约 1517-1545 行）。当前有 `loadX(tx)` / `getX()`。新增 append/replace/delete/clear/count。

**Step 2: 写失败测试**

断言生成的六件套方法存在且行为正确（mock SQL 捕获）：
- `appendTags(tx, tag)` / `appendTags(tx, [t1, t2])` → INSERT 中间表
- `replaceTags(tx, [tags])` → DELETE 旧 + INSERT 新
- `deleteTags(tx, tag)` / `deleteTags(tx, [tags])` → DELETE 中间表对应行
- `clearTags(tx)` → DELETE 全部
- `countTags(tx)` → SELECT COUNT
- 目标 id 为 0（新对象）→ 抛异常

**Step 3: 实现**

在 `buildRelationMethods` 的 ref_many 分支添加六件套方法生成。SQL 用 `r.via` 中间表名，源 id 用 `this.id`（实体的 pk），目标 id 用 `entity.id`：

```
appendTags(tx, tag):   INSERT INTO <via> (post_id, tag_id) VALUES (?, ?)
appendTags(tx, tags):  for 循环 INSERT
replaceTags(tx, tags): DELETE FROM <via> WHERE post_id = ?; 再 for 循环 INSERT
deleteTags(tx, tag):   DELETE FROM <via> WHERE post_id = ? AND tag_id = ?
deleteTags(tx, tags):  for 循环 DELETE
clearTags(tx):         DELETE FROM <via> WHERE post_id = ?
countTags(tx):         SELECT COUNT(*) FROM <via> WHERE post_id = ?
```

注意中间表列名约定：`<sourceTable>_id` / `<targetTable>_id`（现有 junction schema 生成用 `buildJunctionSchema`，复用其列名逻辑）。源表名用 `classNameSchema().tableName()`（运行时的 @Table 覆盖值，与现有 loadSQL 一致）。

**Step 4: 运行确认通过**

Run: `cjpm build && cjpm test`
Expected: 全绿

**Step 5: 提交**

```bash
git add src/macros/refine_macro.cj src/macro_test.cj
git commit -m "feat: ref_many 六件套关联管理 API"
```

---

### Task 4: 级联遍历辅助函数（cascadeSave / cascadeDelete）

**Files:**
- Modify: `src/macros/refine_macro.cj`
- Test: `src/macro_test.cj`

**Step 1: 读现有结构**

确认 `buildTxSaveExtend` / `buildTxUpdateExtend` / `buildTxDeleteExtend` 的生成结构（第二批已实现审计/version 注入）。设计生成一个实体级级联方法 `cascadeSave(tx, visited)` / `cascadeDelete(tx, visited)` 挂在实体类上（或 Tx 扩展内部函数）。

**Step 2: 写失败测试**

断言级联辅助函数生成且按标记遍历：标记 true 的 has_many 字段回填 fk 并递归 save；未标记字段不处理。

**Step 3: 实现**

新增 `buildCascadeMethods(className, rels, cd)`：

生成实体方法：
```
public func cascadeSave(tx: Tx, visited: ArrayList<Any>): <cn> {
    if (visited.contains(this)) { return this }
    visited.add(this)
    // 阶段 1: ref_to 维护 fk（仅在关联字段标记 true 时）
    // 阶段 3: has_many/has_one 回填 fk → 递归子对象 cascadeSave
    // 阶段 4: ref_many 重建中间表（标记 true 时）
    this
}
public func cascadeDelete(tx: Tx, visited: ArrayList<Any>): <cn> {
    // 先递归删子（has 系）→ 清中间表（ref_many）→ 返回（父删除由外部执行）
}
```

对每个关联（按 kind 分支）：
- **ref_to**（标记 true 时）：`Some(u)` 且 `u.id != 0` → `this.<fk> = u.id`；`Some(u)` 且 `u.id == 0` 或 `None` → `this.<fk> = 0/""`
- **has_many / has_one**（标记 true 时）：子对象列表 → 先 `child.<fk> = this.id` → 递归 `child.cascadeSave(tx, visited)`（子级联再走 tx.save/update 落库）
- **ref_many**（标记 true 时）：重建中间表（复用六件套的 SQL 或直接生成）

**注意**：cascadeSave 里子对象的落库（tx.save/update）在递归返回后由父的 Tx 扩展统一执行，还是递归内立即执行？**设计决策**：递归内立即执行子对象落库（先子后父不行——父 id 未生成）。修正顺序见设计文档第 5 节：阶段 1 ref_to 维护 fk → 阶段 2 父 save（拿 id）→ 阶段 3 递归子（父 id 已生成，回填后 tx.save/update 子）→ 阶段 4 ref_many。

**因此 cascadeSave 需要分段**：父的 Tx 扩展在父 save 前调用 cascadeSave 的阶段 1（ref_to 维护 fk），父 save 后调用阶段 3/4（子落库 + 中间表）。实现上可拆为两个辅助：`cascadePreSave(tx, visited)`（ref_to）+ `cascadePostSave(tx, visited)`（has 系 + ref_many）。

**Step 4: 运行确认通过**

Run: `cjpm build && cjpm test`
Expected: 全绿（现有实体无关联标记，行为不变）

**Step 5: 提交**

```bash
git add src/macros/refine_macro.cj src/macro_test.cj
git commit -m "feat: 级联遍历辅助函数（ref_to/has/ref_many 分段）"
```

---

### Task 5: Tx.save/update/delete 接入级联

**Files:**
- Modify: `src/macros/refine_macro.cj`
- Test: `src/macro_test.cj`

**Step 1: 写失败测试**

断言 `tx.save(user)`（user.posts 标记 true）→ 先生成父 INSERT，再生成子 INSERT（fk 回填正确）。mock 捕获 SQL 序列验证。

**Step 2: 运行确认失败**

Expected: FAIL（save 未级联）

**Step 3: 实现**

改造三个 Tx 扩展生成：

`buildTxSaveExtend`：
```
save(entity):
    entity.cascadePreSave(tx, visited)   // 阶段 1: ref_to 维护 fk
    <审计注入> <version 初始化>
    <钩子>
    <父 INSERT>
    entity.cascadePostSave(tx, visited)  // 阶段 3/4: 子落库 + ref_many
    <after 钩子>
```

`buildTxUpdateExtend`：同样分段，父 UPDATE 前后插入。**注意**：update 只处理标记 true 字段（cascadePreSave/PostSave 内部按标记判断）。

`buildTxDeleteExtend`（及软删版本）：
```
delete(entity):
    entity.cascadeDelete(tx, visited)  // 先递归删子 + 清中间表
    <钩子>
    <父 DELETE/软删>
```

**关键约束**：
- 无任何关联字段的实体：cascadePre/PostSave/cascadeDelete 为空实现或根本不生成，行为与第二批完全一致（全量测试防回归）
- visited 集合在每次 save/update/delete 调用时新建 `ArrayList<Any>()`
- 递归子对象落库走内部 `tx.save(child)` 逻辑（可复用宏生成的 save 内部，避免重复嵌套级联——子对象的子对象由子对象的 cascade 处理）

**Step 4: 运行确认通过**

Run: `cjpm build && cjpm test`
Expected: 全绿（现有无关联实体行为不变 + 新级联测试通过）

**Step 5: 提交**

```bash
git add src/macros/refine_macro.cj src/macro_test.cj
git commit -m "feat: Tx.save/update/delete 接入关联级联"
```

---

### Task 6: 单元级边界测试

**Files:**
- Modify: `src/macro_test.cj`

**Step 1: 补充单元测试**

- 循环检测：A ↔ B 互引，cascadeSave 不死循环（mock 捕获 SQL 次数断言）
- 两个无 id 新对象互不误判（对象引用 visited 生效）
- has_many 已有 id 子对象跨父迁移：update 回填 fk
- ref_to `Some(0)` 视为清空
- 空列表标记 true：save 无子、ref_many 清空中间表
- 加载后未修改即 update：不触发级联

**Step 2: 运行确认通过**

Run: `cjpm build && cjpm test`
Expected: 全绿

**Step 3: 提交**

```bash
git add src/macro_test.cj
git commit -m "test: 级联边界用例 - 循环/迁移/清空/加载不污染"
```

---

### Task 7: 双库集成测试

**Files:**
- Modify: `example/src/entity.cj`
- Modify: `example/src/service_test.cj`

**Step 1: 确认现有实体**

读 `example/src/entity.cj`（User/Profile/Post/Comment/Tag）与 `example/src/service_test.cj`（ServiceChecks 模式、openMySQL/openPostgres、initOnce）。

**Step 2: 新增级联测试实体（如需）**

现有实体已含 has_many（User.posts、Post.comments）、has_one（User.profile）、ref_to（Post.author）、ref_many（Post.tags）。若已有覆盖则复用，无需新建。注意现有实体没有关联修改标记——需确认宏改写后现有集成测试仍通过。

**Step 3: ServiceChecks 新增断言**

- `cascadeSaveWithChildren`：User 带 posts + profile → 一次 `tx.save(user)` 全部落库，fk 回填正确
- `cascadeUpdateChildren`：改 user 名 + 改 post 标题 + 新增 post → 分别 update/save
- `loadedThenUpdateNoCascade`：load user → 不改关联 → update 不触发级联（无中间表重建）
- `cascadeMovePosts`：`b.posts = [p]`（p 已有 id）→ update 后 `p.user_id == b.id`
- `cascadeDeleteUser`：delete → posts/profile 级联删
- `refToFkBackfill`：`post.author = Some(u)` → user_id 回填；`None` / `Some(0)` → 清零
- `refManySixPiece`：append/replace/delete/clear/count 各断言
- `cascadeCycle`：A ↔ B 互引不死循环
- `cascadeDeepChain`：三层嵌套
- `cascadeOptimisticLock`：级联 update 子对象带 version 校验
- `cascadeSoftDelete`：子实体有 deleted_at → 级联软删

**Step 4: 两测试类注册**

MySQL/PostgreSQL 测试类各注册对应 @TestCase。

**Step 5: 运行**

Run（example 目录）：`cjpm test`
Expected: 全部 PASS（MySQL + PG 各 30+ 用例）

**Step 6: 提交**

```bash
git add example/src/entity.cj example/src/service_test.cj
git commit -m "test: 级联保存双库集成测试"
```

---

### Task 8: 文档

**Files:**
- Modify: `docs-site/guide/relations.md`
- Modify: `docs-site/guide/crud.md`
- Modify: `docs-site/guide/entities.md`
- Modify: `docs-site/api/relation.md`

**Step 1: relations.md**

新增「级联保存」章节：四种关联级联语义表、修改标记说明（整体赋值触发、`.add()` 不触发）、ref_to fk 维护规则（含 JSON 场景 `Some(0)` 视为清空）、级联顺序、循环检测。

**Step 2: relations.md（或独立章节）**

ref_many 六件套 API：append/replace/delete/clear/count/load 签名与行为、目标 id 为空抛异常、事务要求。

**Step 3: crud.md / entities.md**

save/update/delete 章节补充级联说明与边界（batchSave 不级联、列表移除不自动删库）。

**Step 4: api/relation.md**

RefMany 类型与六件套方法文档。

**Step 5: 构建验证**

Run: `cd docs-site && npm run docs:build`
Expected: build complete

**Step 6: 提交**

```bash
git add docs-site/
git commit -m "docs: 级联保存与 ref_many 六件套文档"
```

---

### Task 9: 全量回归 + 收尾

**Step 1: 全量测试**

refine 目录 Run: `cjpm test`；example 目录 Run: `cjpm test`
Expected: 全部 PASS

**Step 2: 最终代码审查**

对照设计文档与计划，审查所有任务。重点验证设计文档第 4 节修正的 4 个缺陷点（rowMapper 标记、循环检测、ref_to 时机、跨父迁移）都正确实现。

**Step 3: 合并 master 并推送**

```bash
git checkout master && git merge feature/cascade-save && git push origin master
```

---

## 风险与注意

- **字段改写兼容性**：`var posts` → `mut prop posts` 后，所有内部引用（rowMapper/colsStruct/buildRelationMethods 的 `this.posts`）走 getter，语义不变；但 `buildColsStruct` 等遍历字段的地方需确认仍能识别（prop 不是 VarDecl）。**可能需要在 extractFields 阶段就区分**，或调整 colsStruct 生成从 rels 而非 classDecl 遍历。
- **PropDecl 构造**：`PropDecl(inputs: Tokens)` 可用 quote 构造完整 `public mut prop posts: ... { get() {...} set(v) {...} }`。私有字段 `_posts` 与原初始值需保留。
- **`mut prop` 限制**：数值/String/Bool/enum 类型不能声明 mut 属性，但关联字段均为 `ArrayList<T>` / `Option<T>`（引用类型），已验证可行。
- **级联递归落库**：子对象落库必须在父 save 之后（父 id 已生成）。`cascadePostSave` 负责。ref_to 维护 fk 在父 save 前（`cascadePreSave`）。
- **visited 用对象引用**：`ArrayList<Any>` + `contains`（实体类未重载 == 时默认引用相等）。需验证 `ArrayList<Any>.contains` 对引用的行为，必要时用引用比较封装。
- **软删与级联**：父软删时 has 系子对象跟随自身策略（有 deleted_at → 软删）；ref_many 清中间表（软删父后中间表仍残留记录时需清）。
- **批处理不级联**：`batchSave` / `batchUpdate` 保持现状。
- **现有集成测试**：实体字段改写为 prop 后，现有 `entity.cj` 中直接字段访问（如 `u.posts.add(...)`、`post.author = Some(u)`）仍需编译通过——getter/setter 兼容。集成测试必须全绿。
