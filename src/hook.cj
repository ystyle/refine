package refine

import std.collection.HashMap
import std.collection.ArrayList
import std.database.sql.QueryResult

public enum HookKind {
    // 事务内钩子 —— Tx.save/update/delete 中触发，scope.db = Some(tx)
    | TxBeforeCreate
    | TxAfterCreate
    | TxBeforeUpdate
    | TxAfterUpdate
    | TxBeforeDelete
    | TxAfterDelete

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
    | AfterFind
}

extend HookKind <: ToString {
    public func toString(): String {
        match (this) {
            case TxBeforeCreate => "TxBeforeCreate"
            case TxAfterCreate => "TxAfterCreate"
            case TxBeforeUpdate => "TxBeforeUpdate"
            case TxAfterUpdate => "TxAfterUpdate"
            case TxBeforeDelete => "TxBeforeDelete"
            case TxAfterDelete => "TxAfterDelete"
            case BeforeCreate => "BeforeCreate"
            case AfterCreate => "AfterCreate"
            case BeforeUpdate => "BeforeUpdate"
            case AfterUpdate => "AfterUpdate"
            case BeforeDelete => "BeforeDelete"
            case AfterDelete => "AfterDelete"
            case BeforeSave => "BeforeSave"
            case AfterSave => "AfterSave"
            case AfterFind => "AfterFind"
        }
    }
}

public class Scope<T> {
    public var entity: T
    public var db: ?Tx
    public var entityBefore: ?T
    public var fields: Array<Col<Any>>
    public var error: ?Exception
    public var aborted: Bool = false
    public var result: ?QueryResult

    public init(entity: T) {
        this.entity = entity
        this.db = None
        this.entityBefore = None
        this.fields = []
        this.error = None
        this.aborted = false
        this.result = None
    }

    public func abort(err: Exception) {
        this.error = err
        this.aborted = true
    }
}

public type HookFn<T> = (Scope<T>) -> Unit

// Registry stores untyped wrappers to avoid Any-to-function-type cast issues
private var hookRegistry = HashMap<String, ArrayList<Any>>()

public func registerHook<T>(typeName: String, kind: HookKind, hook: HookFn<T>): Unit {
    let key = typeName + ":" + kind.toString()
    match (hookRegistry.get(key)) {
        case Some(list) =>
            list.add(hook)
        case None =>
            let list = ArrayList<Any>()
            list.add(hook)
            hookRegistry.add(key, list)
    }
}

public func executeHooks<T>(typeName: String, kind: HookKind, scope: Scope<T>): ?Exception {
    let key = typeName + ":" + kind.toString()
    match (hookRegistry.get(key)) {
        case Some(hooks) =>
            for (h in hooks) {
                if (scope.aborted) {
                    return scope.error
                }
                let fn = (h as HookFn<T>).getOrThrow()
                fn(scope)
            }
            if (scope.aborted) {
                return scope.error
            }
        case None => ()
    }
    None
}

public func clearHooks(): Unit {
    hookRegistry.clear()
}
