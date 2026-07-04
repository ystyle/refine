# Col\<T\>

字段描述符，类型安全的列引用。配合宏生成的 `Entity.col()` 使用。

## 构造

```cangjie
let idCol = Col<Int64>("id")
let nameCol = Col<String>("name")
```

通常通过宏生成的结构体获取：

```cangjie
let cols = User.col()
cols.id    // Col<Int64>
cols.name  // Col<String>
cols.email // Col<String>
```

## 比较操作符

```cangjie
Col<T> == T    // Binary(Column, Eq, Value)
Col<T> != T    // Binary(Column, Ne, Value)
Col<T> >  T    // Binary(Column, Gt, Value)
Col<T> <  T    // Binary(Column, Lt, Value)
Col<T> >= T    // Binary(Column, Ge, Value)
Col<T> <= T    // Binary(Column, Le, Value)

// 列对列比较
Col<T> == Col<T>
Col<T> != Col<T>
```

## 方法

### asc() / desc()

```cangjie
User.col().id.asc()   // Ordered(Column("id"), "ASC")
User.col().id.desc()  // Ordered(Column("id"), "DESC")
```

### anyOf() / notAnyOf()

```cangjie
User.col().id.anyOf([1, 2, 3])        // IN 查询
User.col().id.notAnyOf([4, 5])        // NOT IN 查询
```

## extend Col\<String\>

### like()

```cangjie
User.col().name.like("%lice%")  // Binary(Column, Like, Value)
// 生成: "name" LIKE ?
// 参数: "%lice%"
```

## extend Col\<Bool\>

### isTrue() / isFalse()

```cangjie
User.col().vip.isTrue()   // Unary(IsNotNull, Column("vip"))
User.col().vip.isFalse()  // Binary(Column("vip"), Eq, Value(false))
```
