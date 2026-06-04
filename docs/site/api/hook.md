# Hook

## HookKind

```cangjie
import refine.*

enum HookKind {
    | BeforeCreate   // save() 实体创建前
    | AfterCreate    // save() 实体创建后
    | BeforeUpdate   // update() 更新前
    | AfterUpdate    // update() 更新后
    | BeforeSave     // 保留接口
    | AfterSave
    | BeforeDelete   // delete() 删除前
    | AfterDelete    // delete() 删除后
    | AfterFind      // 已定义，待实现
}
```

## Scope\<T\>

```cangjie
class Scope<T> {
    public var entity: T
    public var db: ?Tx
    public var entityBefore: ?T
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
rf.hook<User>("User", HookKind.BeforeCreate) { scope: Scope<User> =>
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
