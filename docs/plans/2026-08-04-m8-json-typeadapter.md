# M8-Json 设计：struct → Json 字段端到端读写（stdx.encoding.json.stream 版）

> 日期：2026-08-04
> 目标：让含未知 struct 字段的实体端到端可用。方案采用 **stdx.encoding.json.stream**（用户指定：对象↔JSON 流互转的推荐库），要求 struct 类实现其接口（编译期强制），无需运行时注册表。

## 背景

- `StorageType.Json` 已存在（storage.cj），schema 推断未知 struct → Json（M8 已修，三方言 DDL 就绪：SQLite TEXT / MySQL JSON / PG JSONB）
- **未接线**：写路径 dispatchSet 收到 struct 实例落 `case _` 抛错；读路径 `result.get<StructType>` 抛错；M22 只发编译期 WARNING
- 旧的 `TypeAdapter<T>` 接口（storage.cj:23）保留但**不再扩展**——本方案用 stdx 标准接口替代

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

### 写路径（sql_gen/token_gen/tx_gen 参数生成处）
对 Json 兜底字段，生成序列化代码（替代裸 `entity.f` 入 Array<Any>）：

```cangjie
// 运行时每个 struct 字段：序列化到流
let wbuf = std.io.ByteBuffer()
let writer = JsonWriter(wbuf)
writer.writeValue(entity.profile)   // T <: JsonSerializable 编译期强制
writer.flush()
allParams.add(std.io.readToEnd(wbuf).toString())  // 字节流 → String
```

或封装一个包级 helper（如 `func jsonToString<T>(v: T): String where T <: JsonSerializable`），宏生成 `jsonToString(entity.profile)`——**更简洁**。读路径同理封装 `func stringToJson<T>(s: String): T where T <: JsonDeserializable<T>`。

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

## 依赖

- cjpm.toml 加 `stdx = "1.1.0"`（中心仓已有索引）
- 宏生成代码 import `stdx.encoding.json.stream.*` + `std.io.*`——但宏展开代码的 import 受约束（宏展开后不允许包声明与 import）。**需验证**：宏生成的代码如何访问 stdx 包？看现有宏生成代码如何处理 import（如 DateTime 的 import）——很可能生成的代码不写 import，依赖用户实体文件已有 import，或宏生成全限定路径引用。

## 测试计划（TDD）

1. **helper 单测**（json_util_test.cj）：`jsonToString`/`stringToJson` roundtrip（struct 实现接口）
2. **宏测试**：含 struct 字段（Profile 实现 JsonSerializable + JsonDeserializable）实体：
   - 写路径：INSERT/UPDATE 绑定值为 JSON 文本（mock 断言 capturedSetValues 含序列化后 String，非 struct 实例）
   - 读路径：rowMapper 读回 struct（mock 断言字段被反序列化）
   - 未实现接口的 struct → 宏生成代码编译失败（编译期验证，文档说明）
3. **真实 DB**（SQLite/PG/MySQL）：struct 字段 roundtrip——save（struct → JSON 文本）→ query 读回
4. **回归**：现有 @Field[Text] 覆盖不受影响；无 struct 字段实体零开销

## 完成定义
- [ ] cjpm.toml 加 stdx 依赖，验证 json.stream 可用
- [ ] 宏层写路径用 JsonSerializable 序列化、读路径用 JsonDeserializable 反序列化
- [ ] 未实现接口编译期失败（编译约束保障）
- [ ] 真实 DB roundtrip
- [ ] 全量测试通过
- [ ] M8 审计标记已解决
