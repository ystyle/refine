# 事务管理

## 编程式事务

所有写操作必须在事务中执行。使用 `Refine.transaction()`：

```cangjie
rf.transaction { tx: Tx =>
    let user = User()
    user.name = "Alice"
    tx.save(user)

    let post = Post()
    post.title = "Hello"
    post.user_id = user.id
    tx.save(post)
}
```

## 自动提交/回滚

- 闭包正常返回 → 自动 `commit()`
- 闭包抛出异常 → 自动 `rollback()`，异常继续传播

```cangjie
try {
    rf.transaction { tx: Tx =>
        let user = User()
        user.name = "Alice"
        tx.save(user)
        throw Exception("事务回滚")
        // 不会执行到这里
    }
} catch (_: Exception) {
    // 事务已回滚
}
```

## 原始 SQL

在事务中可以直接执行原始 SQL：

```cangjie
rf.transaction { tx: Tx =>
    tx.execute("INSERT INTO logs (msg) VALUES (?)", ["hello"])
    let r = tx.query("SELECT * FROM logs", [])
    while (r.next()) {
        // 处理结果
    }
}
```

## 嵌套事务 / 保存点

`Tx` 支持保存点（savepoint），允许部分回滚：

```cangjie
rf.transaction { tx: Tx =>
    let u = User()
    u.name = "Alice"
    tx.save(u)

    tx.save("before_rollback") // 创建保存点

    let doomed = User()
    doomed.name = "Rollbacked"
    tx.save(doomed)

    tx.rollbackTo("before_rollback") // 回滚到保存点
    // doomed 不会保存到数据库
    // Alice 仍然存在
}
```

## 事务隔离级别

`transaction(level, action)` 重载可指定隔离级别：

```cangjie
rf.transaction(IsolationLevel.Serializable) { tx: Tx =>
    // 事务内所有操作在 Serializable 隔离级别下执行
}
```

- `IsolationLevel` 枚举：`ReadUncommitted` / `ReadCommitted` / `RepeatableRead` / `Serializable`
- 不带隔离级别的 `transaction { }` 保持数据库默认
- 设置通过驱动原生属性生效，MySQL / PostgreSQL 均支持
- SQLite 不支持设置隔离级别，调用抛异常
