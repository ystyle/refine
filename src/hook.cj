package refine

import std.database.sql.QueryResult

public enum HookKind {
    // 事务内钩子 —— Tx.save/update/delete 中触发，scope.db = Some(tx)
    | TxBeforeCreate
    | TxAfterCreate
    | TxBeforeUpdate
    | TxAfterUpdate
    | TxBeforeDelete
    | TxAfterDelete

    // 查询后钩子 —— all()/one()/page() 映射后触发（须绑定 Refine 实例）
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
