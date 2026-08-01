# Refine ORM — 仓颉编译期类型安全 ORM

## 仓颉语言

- 语法问题使用 `cangjie_docs` 工具查找，不要猜 API 和语法
- 在提示语法错误时使用 `cangjie-mem` 加载语言级记忆
- 包名声明使用 `.` 分隔：`package refine`、`package refine.dialect`

## 要求

- 每次需要失败的用例，需要添加到单元测试里，沉淀下来

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
├── db.cj               DB / Session / Tx
├── storage.cj          StorageType / TypeAdapter
├── hook.cj             Hook 系统
├── mapper.cj           结果映射器
├── migrator.cj         Schema 迁移
├── error.cj            异常层次
├── macros/
│   └── refine_macro.cj 宏定义文件（macro package refine.macros）
├── xxx_test.cj         测试文件（与源码同包）
├── xxx.cj.macrocall    宏展开调试输出
```

- 宏定义在 `src/macros/` 下，使用 `macro package` 声明（包名 `refine.macros`）
- 测试文件放在 `src/` 下与源码同包（`package refine`），不使用 `tests/` 目录
- `output-type = "static"`，全程使用 `cjpm` 构建和测试

## 环境配置

使用 `cjvs` 管理仓颉版本。通过 `pty_spawn` 创建 zsh PTY 会话，先执行`eval $(cjvs env zsh)` 加载核心库，再 `eval $(cjvs stdx env zsh)` 加载stdx的`LD_LIBRARY_PATH`环境变量，再执行仓颉命令：

```shell
eval $(cjvs env zsh)                     # 加载核心库环境变量
eval $(cjvs stdx env zsh)  # 配置 LD_LIBRARY_PATH stdx 环境变量（含 stdx）
cjpm build

# 运行测试（含代码和测试文件）
cjpm test

# 清理
cjpm clean
```

- 日常开发只需 `cjpm build` 和 `cjpm test`
- 单独跑某个测试: `cjpm test --filter 'TestName.testMethod'`
- `cjpm` 会自动处理 `src/` 下所有源文件和测试文件，包括宏定义的编译

## 已知仓颉约束

- 枚举变体名不能与类型名相同（`BinOp` 类型 → 变体用 `Binary` 而非 `BinOp`）
- 方法名不能与字段名相同（`var fields` → 方法用 `setFields` 而非 `fields`）
- `struct` 字段无默认值需要显式 `init` 构造函数
- `where`、`quote` 是仓颉关键字，方法名需要用反引号或改用其他名称
- 泛型不变性：`Col<Int64>` ≠ `Col<Any>`，需要显式使用 `Col<Any>` 统一类型
- `String.join(Array<String>, delimiter:)` 用于拼接字符串数组（类似 Go），`ArrayList` 没有 `join()`
- `String.join(arr, delimiter: ",")` 而不是 `arr.join(",")`
- 完整枚举变体引用：当变体名与类名相同时，使用 `RelationKind.RefTo` 而非 `RefTo`
- `&&`/`||` 不支持操作符重载，条件组合使用 `Expr.and()` / `Expr.or()` 方法
- `Bool` 是关键字，枚举变体用 `` `Bool` `` 转义
- `std.database.sql.Statement` 与本地 `Statement` 冲突，使用 `import ... as SqlStatement` 别名
