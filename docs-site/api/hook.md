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

    // 事务外钩子 —— Entity.save/update/delete 中触发，scope.db = None
    | BeforeCreate
    | AfterCreate
    | BeforeUpdate
    | AfterUpdate
    | BeforeDelete
    | AfterDelete

    // 保留
    | BeforeSave
    | AfterSave
    | AfterFind      // all() / one() 映射后触发，用于脱敏
}
```

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

实例级别（推荐）：

```cangjie
rf.hook<User>("User", HookKind.TxBeforeCreate) { scope: Scope<User> =>
    if (scope.entity.name == "") {
        scope.abort(Exception("name required"))
    }
}
```

全局级别：

```cangjie
registerHook<User>("User", HookKind.BeforeCreate) { scope =>
    if (scope.entity.name == "") {
        scope.abort(Exception("name required"))
    }
}
```

## 清除钩子

```cangjie
clearHooks()  // 清除所有已注册的钩子
```
