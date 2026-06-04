# Transaction

事务对象。实现 `ExecutionContext` 接口，可直接执行 SQL。

## 创建

通常通过 `Refine.transaction()` 获取，不直接构造。

```cangjie
rf.transaction { tx: Tx =>
    // tx 可用
}
```

## 事务控制

```cangjie
tx.begin()          // 开始事务（由 Refine.transaction 自动调用）
tx.commit()         // 提交（由 Refine.transaction 自动调用）
tx.rollback()       // 回滚全部（由 Refine.transaction 在异常时自动调用）
```

## 保存点

```cangjie
tx.save("sp1")              // 创建保存点
tx.rollbackTo("sp1")        // 回滚到保存点（不中断事务）
```

## SQL 操作

```cangjie
// 执行 INSERT/UPDATE/DELETE
let result: UpdateResult = tx.execute("UPDATE users SET name = ? WHERE id = ?", ["Bob", 1])

// 查询 — 手动映射
let result: QueryResult = tx.query("SELECT * FROM users WHERE id = ?", [1])
while (result.next()) {
    let name = result.get<String>(0)
}

// 自动映射到实体
let users = tx.queryAll("SELECT * FROM users", [], User.rowMapper())
let user  = tx.queryOne("SELECT * FROM users WHERE id = ?", [1], User.rowMapper())
```

## 参数偏移

MariaDB 驱动使用 1-based 参数索引。`Tx` 根据 `paramOffset` 自动适配：

```cangjie
// paramOffset = 0 时: stmt.set(0, value)
// paramOffset = 1 时: stmt.set(1, value)
```

## 钩子

宏生成的 `Tx.save/update/delete` 自动触发实体钩子：

```cangjie
tx.save(entity)     // BeforeCreate → INSERT → AfterCreate
tx.update(entity)   // BeforeUpdate → UPDATE → AfterUpdate
tx.delete(entity)   // BeforeDelete → DELETE → AfterDelete
```
