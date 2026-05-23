# Refine ORM — 仓颉编译期类型安全 ORM

## 仓颉语言
- 语法问题使用 `cangjie_docs` 工具查找，不要猜 API 和语法
- 在提示语法错误时使用 `cangjie-mem` 加载语言级记忆
- 包名声明使用 `.` 分隔：`package refine`、`package refine.dialect`

## 项目结构

```
src/
├── main.cj             入口（当 output-type=executable 时）
├── expr.cj             Expr / BinOp / UnaryOp 枚举
├── col.cj              Col<T> 字段描述符
├── relation.cj         Relation / RefTo / RefMany / IRelation
├── statement.cj        Clause 枚举 / Statement 结构体
├── query.cj            Query<T> 构建器
├── dialect.cj          Dialect 接口
├── sqlite.cj           SQLiteDialect 实现
├── xxx_test.cj         测试文件（与源码同包）
```

- 源文件直接在 `src/` 下，不使用子目录
- 测试文件放在 `src/` 下与源码同包（`package refine`），不使用 `tests/` 目录
- `output-type = "static"`（作为库编译），需执行 `cjpm test` 运行测试

## 环境配置

使用 `cjvs` 管理仓颉版本，在 zsh PTY 中先执行 `cjenv` 加载环境变量：

```shell
cjenv       # 配置 LD_LIBRARY_PATH 等环境变量
cjpm build
cjpm test
```

## 常用命令

```shell
# 构建
cjpm build

# 运行测试
cjpm test --show-all-output

# 清理缓存
cjpm clean
```

## 已知仓颉约束

- 枚举变体名不能与类型名相同（`BinOp` 类型 → 变体用 `Binary` 而非 `BinOp`）
- 方法名不能与字段名相同（`var fields` → 方法用 `setFields` 而非 `fields`）
- `struct` 字段无默认值需要显式 `init` 构造函数
- `where`、`quote` 是仓颉关键字，方法名需要用反引号或改用其他名称
- 泛型不变性：`Col<Int64>` ≠ `Col<Any>`，需要显式使用 `Col<Any>` 统一类型
- `ArrayList` 没有 `join()` 方法，需要手写拼接
- 完整枚举变体引用：当变体名与类名相同时，使用 `RelationKind.RefTo` 而非 `RefTo`
- `&&`/`||` 不支持操作符重载，条件组合使用 `Expr.and()` / `Expr.or()` 方法
