# 生命周期钩子

## 钩子类型

钩子分**事务内**和**事务外**两类，通过不同的 HookKind 区分注册：

```cangjie
enum HookKind {
    // 事务内钩子 —— Tx.save/update/delete 中触发，scope.db = Some(tx)
    | TxBeforeCreate | TxAfterCreate
    | TxBeforeUpdate | TxAfterUpdate
    | TxBeforeDelete | TxAfterDelete

    // 事务外钩子 —— Entity.save/update/delete 中触发，scope.db = None
    | BeforeCreate | AfterCreate
    | BeforeUpdate | AfterUpdate
    | BeforeDelete | AfterDelete

    // 保留 / 待实现
    | BeforeSave | AfterSave | AfterFind
}
```

## 分类对比

| | 事务内钩子 | 事务外钩子 |
|---|---|---|
| 触发方法 | `Tx.save/update/delete` | `Entity.save/update/delete` |
| `scope.db` | `Some(tx)` — 可访问当前事务 | `None` |
| abort 影响 | 回滚整个事务 | 仅阻止本次操作 |
| 典型用途 | 关联创建、唯一性校验、审计日志 | 格式校验、缓存清理、事件通知 |

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

通过 `Refine.hook()` 注册：

```cangjie
// 事务内钩子：写入审计日志，与主操作同事务
rf.hook<Order>("Order", HookKind.TxBeforeCreate) { scope: Scope<Order> =>
    let tx = scope.db.getOrThrow()
    tx.execute("INSERT INTO audit_logs (entity, action) VALUES (?, ?)",
        ["Order", "create"])
}

// 事务外钩子：格式校验
rf.hook<Order>("Order", HookKind.BeforeCreate) { scope: Scope<Order> =>
    if (scope.entity.total < 0) {
        scope.abort(Exception("negative total"))
    }
}
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
// 实例级注册（推荐，通过 rf.hook）
let rf = Refine.open("sqlite::memory:")
rf.hook<User>("User", HookKind.AfterFind) { scope: Scope<User> =>
    scope.entity.password = ""
}

// 之后所有 User.query().using(rf).all() / .one() 结果 password 被清空
let users = User.query().using(rf).all()

// 全局注册（有时无法获取 Refine 实例时使用）
registerHook<User>("User", HookKind.AfterFind) { scope =>
    scope.entity.password = ""
}
```

> 宏生成的 `query()` 会自动设置 `typeName`。查询时优先使用 `rf.hook()` 注册的实例级钩子，若无则回退到全局 `registerHook()`。