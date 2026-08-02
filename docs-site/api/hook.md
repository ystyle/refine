# Hook

## HookKind

```cangjie
import refine.*

enum HookKind {
    // 事务内钩子 —— Tx.save/update/delete 中触发，scope.db = Some(tx)
    | TxBeforeCreate   // Tx.save() INSERT 前
    | TxAfterCreate    // Tx.save() INSERT 后
    | TxBeforeUpdate   // Tx.update() UPDATE 前
    | TxAfterUpdate    // Tx.update() UPDATE 后
    | TxBeforeDelete   // Tx.delete() 前
    | TxAfterDelete    // Tx.delete() 后

    // 查询后
    | AfterFind      // all() / one() 映射后触发，用于脱敏
}
```

> **I14 变更**：已移除非事务写钩子（`BeforeCreate`/`AfterSave` 等 8 个死变体）与全局注册表，钩子全部实例级。

## Scope\<T\>

```cangjie
class Scope<T> {
    public var entity: T
    public var db: ?Tx
    public var entityBefore: ?T   // 保留，暂未赋值
    public var fields: Array<Col<Any>>
    public var error: ?Exception
    public var aborted: Bool
    public var result: ?QueryResult

    public func abort(err: Exception)  // 中止并设置错误
}
```

## HookFn\<T\>

```cangjie
type HookFn<T> = (Scope<T>) -> Unit
```

## 注册钩子

实例级别（唯一方式）：

```cangjie
rf.hook<User>("User", HookKind.TxBeforeCreate) { scope: Scope<User> =>
    if (scope.entity.name == "") {
        scope.abort(Exception("name required"))
    }
}

// 查询后钩子
rf.hook<User>("User", HookKind.AfterFind) { scope =>
    scope.entity.password = ""
}
```

> AfterFind 只在绑定 Refine 实例的查询上触发（`Query.using(rf)` 或 `Refine.all/one`），裸 Query 不触发。

## 清除钩子

```cangjie
rf.clearHooks()  // 清除该 Refine 实例上所有已注册的钩子
```

## AfterFind 错误传播

AfterFind 钩子抛异常，或调用 `scope.abort()` 使钩子集返回错误时，错误会向上抛出，整个查询失败。
