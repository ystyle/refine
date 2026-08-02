# 生命周期钩子

## 钩子类型

钩子分**事务内**和**查询后**两类，通过不同的 HookKind 区分注册：

```cangjie
enum HookKind {
    // 事务内钩子 —— Tx.save/update/delete 中触发，scope.db = Some(tx)
    | TxBeforeCreate | TxAfterCreate
    | TxBeforeUpdate | TxAfterUpdate
    | TxBeforeDelete | TxAfterDelete

    // 查询后
    | AfterFind
}
```

> **I14 变更**：钩子系统已彻底统一为**实例级**（移除全局注册表），非事务写钩子（`BeforeCreate`/`AfterSave` 等 8 个死变体）一并移除。钩子只能在 `Refine` 实例上注册，且只在该实例发起的操作上触发；不同实例完全隔离。

> **C3 变更**：静态 `Entity.save/update/delete` 因不落库已移除，**请统一使用 `Tx.save/update/delete`**。事务内钩子是唯一会被真实持久化操作触发的写钩子。

## 事务内钩子

| | 事务内钩子 |
|---|---|
| 触发方法 | `Tx.save/update/delete` |
| `scope.db` | `Some(tx)` — 可访问当前事务 |
| abort 影响 | 回滚整个事务 |
| 典型用途 | 关联创建、唯一性校验、审计日志 |

## Scope\<T\>

```cangjie
class Scope<T> {
    public var entity: T          // 当前实体
    public var db: ?Tx            // 当前数据库事务（事务内钩子时可用）
    public var entityBefore: ?T   // 更新前的实体快照
    public var fields: Array<Col<Any>>
    public var error: ?Exception
    public var aborted: Bool
    public var result: ?QueryResult

    public func abort(err: Exception)
}
```

## 注册钩子

通过 `Refine.hook()` 注册，作用于该实例：

```cangjie
// 事务内钩子：写入审计日志，与主操作同事务
rf.hook<Order>("Order", HookKind.TxBeforeCreate) { scope: Scope<Order> =>
    let tx = scope.db.getOrThrow()
    tx.execute("INSERT INTO audit_logs (entity, action) VALUES (?, ?)",
        ["Order", "create"])
}

// 格式校验（事务内钩子同样适用）
rf.hook<Order>("Order", HookKind.TxBeforeCreate) { scope: Scope<Order> =>
    if (scope.entity.total < 0) {
        scope.abort(Exception("negative total"))
    }
}
```

### 清除钩子

```cangjie
rf.clearHooks()  // 清除该实例上所有已注册的钩子
```

## 钩子执行时机

```
Tx.save(entity):
  1. executeHooks(TxBeforeCreate, scope)    // scope.db = 当前事务
  2. if (aborted) throw scope.error
  3. INSERT INTO ...
  4. entity.id = lastInsertId
  5. executeHooks(TxAfterCreate, scope)

Tx.update(entity):
  1. executeHooks(TxBeforeUpdate, scope)
  2. if (aborted) throw scope.error
  3. UPDATE ... WHERE id = ?
  4. executeHooks(TxAfterUpdate, scope)

Tx.delete(entity):
  1. executeHooks(TxBeforeDelete, scope)
  2. if (aborted) throw scope.error
  3. DELETE FROM ... WHERE id = ?
  4. executeHooks(TxAfterDelete, scope)
```

事务内钩子抛异常或调用 `scope.abort()` 会导致整个事务回滚。

## AfterFind

`AfterFind` 在 `all()` / `one()` 映射完每个实体后触发。用于脱敏敏感字段、填充计算字段等：

```cangjie
// 实例级注册
let rf = Refine.open("mariadb://127.0.0.1:3306", [("username", "root"), ("password", "secret"), ("database", "myapp")])
rf.hook<User>("User", HookKind.AfterFind) { scope: Scope<User> =>
    scope.entity.password = ""
}

// 之后所有 User.query().using(rf).all() / .one() 结果 password 被清空
let users = User.query().using(rf).all()
```

> **I14 变更**：AfterFind 只在**绑定 Refine 实例**的查询（`Query.using(rf)` 或 `Refine.all/one`）上触发。**裸 Query**（仅绑定 session/tx）不触发 AfterFind；钩子注册也只在 `rf.hook()`（实例级），不再有全局 `registerHook()`。

AfterFind 钩子抛异常，或调用 `scope.abort()` 使钩子集返回错误时，错误会**向上抛出**，整个查询失败（不会被静默忽略）。