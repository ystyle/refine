# M8-Json 设计：struct → Json 字段端到端读写（stdx.encoding.json.stream 版）

> 日期：2026-08-04（更新：2026-08-05 已验证 stdx 用法）
> 目标：让含未知 struct 字段的实体端到端可用。方案采用 **stdx.encoding.json.stream**（对象↔JSON 流互转的推荐库），要求 struct 类实现其接口（编译期强制），无需运行时注册表。

## 背景

- `StorageType.Json` 已存在（storage.cj），schema 推断未知 struct → Json（M8 已修，三方言 DDL 就绪：SQLite TEXT / MySQL JSON / PG JSONB）
- **未接线**：写路径 dispatchSet 收到 struct 实例落 `case _` 抛错；读路径 `result.get<StructType>` 抛错；M22 只发编译期 WARNING
- 旧的 `TypeAdapter<T>` 接口（storage.cj:23）保留但**不再扩展**——本方案用 stdx 标准接口替代

## stdx 依赖（已验证，2026-08-05）

- **stdx 不走中心仓**（中心仓 stdx-1.1.0 整包编译因 openssl -Werror 失败）。走 **cjvs 本地预编译库 + path-option**：
  ```toml
  [target.x86_64-unknown-linux-gnu.bin-dependencies]
    path-option = ["${CANGJIE_STDX_PATH}"]
  ```
  cjpm.toml 已有此配置（Decimal 时添加）。`${CANGJIE_STDX_PATH}` 经 `eval $(cjvs stdx env zsh)` 注入。
- **记忆 id 355 确认**：`stdx.encoding.json.stream` 的 `writeValue<T>`/`readValue<T>` 支持 Int64/Float64/Bool/String/Array/ArrayList/HashMap/Option<T>（内置实现），自定义 JsonDeserializable 类也可 readValue。
- **探针已验证（2026-08-05）**：泛型约束函数（`T <: JsonSerializable` / `T <: JsonDeserializable<T>`）在 refine 包可编译可运行，struct roundtrip 完整（Profile {name, age} → JSON 文本 → 读回）。**注意：必须用泛型约束，不能 `Any`**（Any 在 JsonReader/Writer 上不支持，记忆 id 355 亦用泛型）。

## stdx.encoding.json.stream（推荐版）

两个接口（stdx 主库 `libs/stdx/encoding/json_stream/`，本地已确认存在）：

```cangjie
public interface JsonSerializable {
    func toJson(w: JsonWriter): Unit
}
public interface JsonDeserializable<T> {
    static func fromJson(r: JsonReader): T
}
```

- `JsonWriter`：`writer.writeValue(entity.f)`——**泛型约束 `T <: JsonSerializable`**（写路径编译期强制 struct 实现了接口）
- `JsonReader`：`init(inputStream: InputStream)`，`T.fromJson(reader)`——**静态方法**，约束 `T <: JsonDeserializable<T>`
- 标量/集合已内置实现（Int/String/Bool/DateTime/Array/ArrayList/Option/HashMap）
- DB 存 String（JSON 文本），读写都经字节流

**核心优势**：宏生成 `writeValue(entity.profile)` / `Profile.fromJson(reader)`——若 struct 未实现接口，**编译期报错**（类型约束），无需全局注册表、无运行时查找、无 cast。编译时要求正是用户要的。

## 存储格式

DB 列（StorageType.Json）存 **String**（JSON 文本）：
- SQLite TEXT / MySQL JSON / PG JSONB 都接受 String 绑定（方言 dataTypeOf 已返回对应 DDL 类型，dispatchSet 的 `case v: String` 绑定即可）
- **注意**：PG JSONB 绑定 String 值需确认驱动行为（是否需 ::jsonb cast 或直接传文本）——实现时验证

## 宏层改动

### 判定：Json 兜底字段（typeNameToStorageType 返回 Json 的 struct 类型）
`isJsonFallbackType(typeName)`（meta.cj）已有此判定（非标量、非 Array<UInt8>、非 DateTime 的未知类型）。

### 包级 helper（运行时 refine 包，可单测）

```cangjie
// src/json_util.cj（package refine，宏生成代码可调用——用户实体文件已 import refine）
public func jsonToString<T>(v: T): String where T <: JsonSerializable {
    let buf = std.io.ByteBuffer()
    let w = JsonWriter(buf)
    w.writeValue(v)
    w.flush()
    String.fromUtf8(std.io.readToEnd(buf))
}
public func stringToJson<T>(s: String): T where T <: JsonDeserializable<T> {
    let buf = std.io.ByteBuffer()
    unsafe { buf.write(s.rawData()) }
    let r = JsonReader(buf)
    T.fromJson(r)
}
```

### 写路径（sql_gen/token_gen/tx_gen 参数生成处）
对 Json 兜底字段，宏生成 `allParams.add(jsonToString(entity.profile))`（替代裸 `entity.f`）。序列化后是 String，dispatchSet `case v: String` 绑定。

### 读路径（method_gen buildRowMapper）
对 Json 兜底字段，生成：
```cangjie
if (columnMap.contains("profile")) {
    let s = result.get<String>(columnMap.get("profile").getOrThrow())
    entity.profile = stringToJson<Profile>(s)
}
```

### M22 警告
- 保留（编译期提示 struct 需实现接口），措辞改为 "implement stdx.encoding.json.stream JsonSerializable + JsonDeserializable<X>"（不再提 TypeAdapter）
- 未实现时生成代码编译失败（writeValue/fromJson 类型约束）——**比 warning 更强的保障**，warning 变可选提示

### 用户 import 要求
宏生成代码调用 `jsonToString`/`stringToJson`（refine 包）+ 实体字段类型 struct 需 `JsonSerializable`（用户实现时必然 import stdx）。**宏生成代码不写 import**（既有约束），但：
- `jsonToString`/`stringToJson` 在 refine 包——用户实体文件已 `import refine.*`，可用
- struct 实现 `JsonSerializable`/`JsonDeserializable` 时用户必然 `import stdx.encoding.json.stream.*`——生成代码里的 `T.fromJson`/`writeValue` 经 helper 间接调用，**不直接出现在实体文件**，无需用户额外 import stdx（helper 在 refine 包内 import 了）

## 测试计划（TDD）

1. **helper 单测**（json_util_test.cj）：`jsonToString`/`stringToJson` roundtrip（struct 实现接口，含嵌套 Option/集合）
2. **宏测试**：含 struct 字段（Profile 实现 JsonSerializable + JsonDeserializable）实体：
   - 写路径：INSERT/UPDATE 绑定值为 JSON 文本（mock 断言 capturedSetValues 含序列化后 String，非 struct 实例）
   - 读路径：rowMapper 读回 struct（mock 断言字段被反序列化）
   - 未实现接口的 struct → 宏生成代码编译失败（编译期验证，文档说明）
3. **真实 DB**（SQLite/PG/MySQL）：struct 字段 roundtrip——save（struct → JSON 文本）→ query 读回
4. **回归**：现有 @Field[Text] 覆盖不受影响；无 struct 字段实体零开销

## 完成定义
- [x] stdx path-option 已验证可用（cjpm.toml 已有）
- [x] json_util.cj helper（jsonToString/stringToJson 泛型约束）
- [x] 宏层写路径用 jsonToString 序列化、读路径用 stringToJson 反序列化
- [x] 未实现接口编译期失败（编译约束保障）
- [x] 真实 DB roundtrip
- [x] 全量测试通过
- [x] M8 审计标记已解决

## Task 3 验证记录（2026-08-06）
- 真实 DB roundtrip：json_roundtrip_test.cj 共享 helper `runJsonRoundtrip`（参考 snake_roundtrip 模式），
  mysql/pgsql/mariadb 集成测试 thin wrapper + SQLite mock 链路 2 例。覆盖 save→query 读回（struct 完整）、
  update、batchSave、batchUpdate、upsert。
- **PG JSONB 修复**：batchUpdate 的 CASE 表达式内参数无法从 jsonb 目标列反向推断类型（42804）——
  `pgCastTypeOf` 对 Json 兜底 struct 此前返回 TEXT，修复为 JSONB（`?::JSONB` cast）。
  INSERT VALUES / 单条 UPDATE / upsert（excluded）可推断，无需 cast。
- **编译失败验证**：临时 fixture（未实现接口的 NoJsonImpl struct + 实体）实编译验证——写路径
  jsonToString 与读路径 stringToJson<X> 均报 `unable to infer generic argument ... constraint
  'X <: Generics-T' cannot be solved`，验证后移除并文档化于 macro_test.cj JsonStructFieldTest 注释。
  注：`cjpm build` 跳过 `*_test.cj`，需 `cjpm test`（编译测试文件）才能触发。
