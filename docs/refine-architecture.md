# Refine ORM 实例架构设计

> 本设计在 `docs/design.md` 基础上，将 `DB`（连接管理）与 `Refine`（运行时配置）合并为统一的 `Refine` 实例。

> **已落地（2026-08-03 DB 收敛）**：本设计已完整执行——`DB` 收敛为纯连接层（仅 datasource + paramOffset + 连接池，不再持有 dialect/migrator），`Refine` 独占 ORM 职责（持有 DB + dialect + hookRegistry + idGenerator），`session()`/`transaction()` 注入 ref，`DatabaseRegistry` 存 `Refine`（后于 2026-08-03 关联审计确认其设计外且零生产使用，已整体移除，见 `docs/audit/2026-08-02-full-audit.md` M16），`Query.using(DB)` 移除。详见 `docs/plans/2026-08-03-db-converge.md`。

---

## 目标

- 一个 `Refine` 实例管理：连接池、方言、Hook 注册表
- 多实例互相隔离（不同数据库、不同 Hook 配置）
- API 简洁，无需重复指定方言和执行上下文

## Refine 类

```cangjie
class Refine {
    // === 内部状态 ===
    private var datasource: PooledDatasource
    private var dialect: Dialect
    private var paramOffset: Int64      // 0=标准, 1=MariaDB
    private var hookRegistry: HashMap<String, ArrayList<Any>>

    // === 生命周期 ===
    static func open(url: String, opts: Array<(String, String)>): Refine
    func close(): Unit

    // === Session / Tx ===
    func session(): Session              // 自动获取连接
    func transaction<T>(action: (Tx) -> T): T

    // === 钩子（实例级，唯一注册方式）===
    func hook<T>(typeName: String, kind: HookKind, hook: HookFn<T>): Unit
    func executeHooks<T>(typeName: String, kind: HookKind, scope: Scope<T>): ?Exception
    func clearHooks(): Unit

    // === 查询快捷入口 ===
    func all<T>(query: Query<T>): Array<T>
    func one<T>(query: Query<T>): Option<T>

    // === 元数据 ===
    func getDialect(): Dialect
    func migrator(): Migrator
}
```

## 使用方式

```cangjie
// 打开数据库
let rf = Refine.open("mariadb://127.0.0.1:3306", [
    ("username", "refine_test"),
    ("password", "refine123")
])

// 注册钩子（只影响本实例）
rf.hook<Post>("Post", TxBeforeCreate) { scope =>
    if (scope.entity.title == "") {
        scope.abort(Exception("title required"))
    }
}

// 查询：using(rf) 自动设置方言和 session
let posts = Post.query()
    .using(rf)
    .where(Post.col.published == true)
    .all()

// 事务
rf.transaction { tx =>
    tx.save(post)       // hook 走 rf 实例的注册表
    tx.update(post)
    tx.delete(post)
}

// 快捷查询
let results = rf.all(Post.query().where(Post.col.published == true))

// 迁移
rf.migrator().autoMigrate([PostSchema()])

rf.close()

// 第二个实例，完全隔离
let rf2 = Refine.open("sqlite://test.db")
rf2.hook<Post>("Post", TxBeforeCreate) { scope => ... }  // 不影响 rf
```

## 改动范围

| 文件 | 改动 |
|---|---|
| `src/refine.cj` | 新建，包含 `Refine` 类主体 |
| `src/db.cj` | Tx/Session 加 `ref: Refine` 字段 |
| `src/hook.cj` | 全局 `hookRegistry` 已移除，钩子仅存于 `Refine` 实例 |
| `src/query.cj` | 加 `using(rf: Refine)` 重载，自动设置方言 |
| `src/macros/refine_macro.cj` | Hook 调用改为实例级 |
| `src/macro_test.cj` | 更新测试 |
| `example/src/main.cj` | 使用新 API |
