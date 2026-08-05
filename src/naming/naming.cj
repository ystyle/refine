// Task 2: 命名策略纯函数——单一实现，供宏包 refine.macros 在展开期调用（编译期烘焙），
// 同时可被测试直接单测。刻意放常规包而非宏包：宏包内非宏函数不可对外可见（官方文档），
// 若放宏包则需在运行时包另存副本（有漂移风险）。宏包展开期调用常规包函数已被实验验证。
package refine.naming

// 驼峰 → snake_case：除首字母外每个大写 ASCII 字母前插 "_"，整串转小写。
// 连续大写边界规则：前一个字符是大写、且下一个字符是小写时也插 "_"——
//   userID → user_id（ID 是结尾缩写，不拆分）
//   HTMLParser → html_parser（Parser 是新词边界）
// 对全小写 snake_case 输入幂等（下划线不触发边界）。
// 按 Rune 遍历（String 下标按字节，UTF-8 下会截断多字节字符）；非 ASCII 原样保留，
// 仅作为前字符时视同小写边界（isAsciiUpperCase/isAsciiLowerCase 只认 ASCII）。
public func camelToSnake(name: String): String {
    if (name.size == 0) { return name }
    let runes = name.toRuneArray()
    let sb = StringBuilder()
    for (i in 0..runes.size) {
        let cur = runes[i]
        if (cur.isAsciiUpperCase() && i > 0) {
            let prevIsUpper = runes[i - 1].isAsciiUpperCase()
            let nextIsLower = i + 1 < runes.size && runes[i + 1].isAsciiLowerCase()
            if (!prevIsUpper || nextIsLower) { sb.append(r'_') }
        }
        sb.append(cur.toAsciiLowerCase())
    }
    sb.toString()
}

// 表名策略分发：snake → camelToSnake；none（默认）→ 现有行为 lowerTableName。
// 非法 strategy 由 @Refine 宏在展开期白名单校验拦截（fail-fast），此处不重复。
public func applyTableNameStrategy(name: String, strategy: String): String {
    if (strategy == "snake") { camelToSnake(name) } else { lowerTableName(name) }
}

// 列名策略分发：snake → camelToSnake；none（默认）→ 保持字段原名。
public func applyColumnNameStrategy(name: String, strategy: String): String {
    if (strategy == "snake") { camelToSnake(name) } else { name }
}

// 首字母小写（实体类名 → 默认表名，如 BlogPost → blogPost）。原定义于宏包 meta.cj，
// Task 2 移入本包：applyTableNameStrategy 的 none 分支依赖它，单一实现避免漂移。
// 按 Rune 处理首字符（String 下标按字节，UTF-8 下会截断多字节字符）；非 ASCII 首字符原样保留。
public func lowerTableName(name: String): String {
    if (name.size == 0) { return name }
    let runes = name.toRuneArray()
    let sb = StringBuilder()
    sb.append(runes[0].toAsciiLowerCase())
    sb.append(runes[1..])
    sb.toString()
}

// 首字母大写（关系字段名 → 方法名前缀，如 userName → UserName）。随 lowerTableName
// 一并移入，保持字符串工具聚合。按 Rune 处理首字符（同 lowerTableName）。
public func upperFirstLetter(name: String): String {
    if (name.size == 0) { return name }
    let runes = name.toRuneArray()
    let sb = StringBuilder()
    sb.append(runes[0].toAsciiUpperCase())
    sb.append(runes[1..])
    sb.toString()
}
