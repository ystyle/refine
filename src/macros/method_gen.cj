macro package refine.macros

import std.ast.*
import std.collection.ArrayList
import refine.naming.*

func buildColsStruct(className: String, cd: ClassDecl, internalNames: ArrayList<String>, mergedFields: ArrayList<FieldInfo>): Tokens {
    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    let colLookup = buildNameToColumnLookup(mergedFields)
    var colsFields = Tokens()
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fn = vd.identifier.value
                if (isGeneratedInternalField(fn, internalNames)) { continue }
                if (!first) { colsFields = colsFields + Token(TokenKind.NL) }
                colsFields = colsFields + quote(
                    public let $(vd.identifier): Col<$(vd.declType)> = Col<$(vd.declType)>($(Token(TokenKind.STRING_LITERAL, lookupColumnName(colLookup, fn))))
                )
                first = false
            case _ => ()
        }
    }
    quote(
        public struct $(colsName) { $(colsFields) init() {} }
    )
}


func buildRelClass(className: String, rels: ArrayList<RelInfo>, strategy: String): Tokens {
    let relClassName = Token(TokenKind.IDENTIFIER, className + "Rel")
    var body = Tokens()
    var first = true
    for (i in 0..rels.size) {
        let r = rels[i]
        if (!first) { body = body + Token(TokenKind.NL) }
        let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
        let targetType = Token(TokenKind.IDENTIFIER, r.target)
        let nameLit = Token(TokenKind.STRING_LITERAL, r.fieldName)
        let schemaIdent = Token(TokenKind.IDENTIFIER, r.target + "Schema")
        let targetTableExpr = quote($(schemaIdent)().tableName())
        let mapperIdent = Token(TokenKind.IDENTIFIER, r.fieldName + "Mapper")
        let setterIdent = Token(TokenKind.IDENTIFIER, r.fieldName + "Setter")
        let mapperFuncIdent = Token(TokenKind.IDENTIFIER, r.target + "RowMapper")
        let cnIdent = Token(TokenKind.IDENTIFIER, className)
        let targetIdExtractorIdent = Token(TokenKind.IDENTIFIER, r.fieldName + "TargetIdExtractor")
        let targetTypeIdent = Token(TokenKind.IDENTIFIER, r.target)
        let targetIdFieldIdent = Token(TokenKind.IDENTIFIER, "id")
        // Task 7: 目标实体 Rel 类解析器闭包。includeAll 解析点号路径后缀段时，在上一层
        // 关系的目标实体 Rel 类上继续解析（如 "author.profile" 的 "profile" 在
        // NestedUserRel 上）。目标 Rel 类的 forName 静态方法与本体同包编译，引用可解析。
        // 注意：解析器必须声明为「独立静态 let 的直接 lambda」，而非内联在 relation 构造
        // 调用的实参里——仓颉静态初始化顺序检查只追踪「函数调用实参」里的跨类引用，直接
        // lambda 值不追踪。内联写法会让 PostRel.author 的初始化被检查器追踪到 UserRel
        // 的静态成员（声明靠后），报 "used before initialization"（NestedPost 链、自引用
        // Category.children 均触发，见 Task 7 实现记录）。
        let targetRelClass = Token(TokenKind.IDENTIFIER, r.target + "Rel")
        let resolverIdent = Token(TokenKind.IDENTIFIER, r.fieldName + "Resolver")
        let resolverLet = quote(
            public static let $(resolverIdent) = { n: String => $(targetRelClass).forName(n) }
        )
        body = body + quote(
            public static let $(mapperIdent) = $(mapperFuncIdent)
        )
        body = body + Token(TokenKind.NL)
        // Task 6: 目标实体主键读取器。嵌套 include 递归装配时，上一层装配出的目标实体
        // （Array<Any>，如 Post.author 装配出的 User）作为下一层的「主实体」，其 id 是
        // 下一层 has_many/ref_many 批量查询的 IN 主键集合。宏层已知目标类名（r.target），
        // 生成 `{ target: Any => (target as 目标类).getOrThrow().id }` 闭包读目标实体主键。
        // 限制：目标类必须有名为 `id` 的字段（@Id 自定义主键名目标类不支持——rawIdExtractor
        // 按 pkFields 的真实列名生成，而此处宏层无目标类内省信息，只能硬编码读 `id`）；
        // 复合主键目标类无 `id` 字段会编译失败，属已知限制。
        // id 字段用 $(targetIdFieldIdent) 拼接而非裸写 `t.id`：与 fkExtractor 的字段访问
        // 风格一致（裸写 `t.id` 在 quote 渲染下会丢失成员访问语义，运行时 cast 返回 None）。
        body = body + quote(
            public static let $(targetIdExtractorIdent): (Any) -> Any = { target: Any =>
                let t = (target as $(targetTypeIdent)).getOrThrow()
                t.$(targetIdFieldIdent)
            }
        )
        body = body + Token(TokenKind.NL)
        if (r.kind == "ref_to" || r.kind == "has_one") {
            let backingIdent = Token(TokenKind.IDENTIFIER, "_" + r.fieldName)
            body = body + quote(
                public static let $(setterIdent) = { entity: Any, target: Any =>
                    let e = (entity as $(cnIdent)).getOrThrow()
                    e.$(backingIdent) = target as $(targetType)
                }
            )
        } else {
            body = body + quote(
                public static let $(setterIdent) = { entity: Any, target: Any =>
                    let e = (entity as $(cnIdent)).getOrThrow()
                    e.$(fieldIdent).add((target as $(targetType)).getOrThrow())
                }
            )
        }
        body = body + Token(TokenKind.NL)
        let colNamesFunc = Token(TokenKind.IDENTIFIER, r.target + "ColumnNames")
        let hasCustomFields = r.fields.size > 1 || (r.fields.size == 1 && r.fields[0] != "id")
        var fieldsTok: Tokens
        if (hasCustomFields) {
            // Task 5: @Ref/@Rel fields 是目标表列名列表，随命名策略转换（与目标实体自身
            // columnName 同源一致；用户已给 snake 列名则 camelToSnake 幂等）。默认路径
            // 走 <Target>ColumnNames()（目标实体真实列名，无需宏层转换）。
            var convertedFields = ArrayList<String>()
            for (name in r.fields) { convertedFields.add(applyColumnNameStrategy(name, strategy)) }
            fieldsTok = genFieldCols(convertedFields)
        } else {
            fieldsTok = Tokens()
            fieldsTok = fieldsTok + colNamesFunc
            fieldsTok = fieldsTok + Token(TokenKind.LPAREN)
            fieldsTok = fieldsTok + Token(TokenKind.RPAREN)
        }
        // Task 7: 目标 Rel 类解析器先于 relation 静态成员声明（relation 依赖它，
        // 声明顺序必须靠前）。见上方注释：直接 lambda 形式规避静态初始化顺序检查。
        body = body + resolverLet
        body = body + Token(TokenKind.NL)
        if (r.kind == "ref_to") {
            // Task 5: r.by 双身份——fkLit（Col<Any> 列名 = SQL 列名）随策略转 snake
            //（authorId → author_id），fkField（e.authorId 字段访问）保持字段名。
            let fkLit = Token(TokenKind.STRING_LITERAL, applyColumnNameStrategy(r.by, strategy))
            let extractorIdent = Token(TokenKind.IDENTIFIER, r.fieldName + "FkExtractor")
            let fkField = Token(TokenKind.IDENTIFIER, r.by)
            // Task 3: ref_to 批量装配需要从主实体读取外键值。ref_to 的 fk 是主实体的普通字段
            // （如 Post.user_id），宏层已知类名与字段名，直接生成读取闭包。
            // 显式标注返回类型 (Any) -> Any：字段原生类型（Int64/String）自动上转 Any。
            body = body + Token(TokenKind.NL)
            body = body + quote(
                public static let $(extractorIdent): (Any) -> Any = { entity: Any =>
                    let e = (entity as $(cnIdent)).getOrThrow()
                    e.$(fkField)
                }
            )
            body = body + Token(TokenKind.NL)
            // Task 7: attachTargetRelResolver 保留静态成员具体类型（RefTo<Target>）的同时
            // 注入目标 Rel 类解析器闭包（getTargetRelResolver 供 includeAll 解析嵌套段）。
            body = body + quote(
                public static let $(fieldIdent) = attachTargetRelResolver(RefTo<$(targetType)>($(nameLit), Col<Any>($(fkLit)), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent), $(extractorIdent), $(targetIdExtractorIdent)), $(resolverIdent))
            )
        } else if (r.kind == "has_one") {
            let fkLit = Token(TokenKind.STRING_LITERAL, applyColumnNameStrategy(r.by, strategy))
            body = body + quote(
                public static let $(fieldIdent) = attachTargetRelResolver(HasOne<$(targetType)>($(nameLit), $(fkLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent), $(targetIdExtractorIdent)), $(resolverIdent))
            )
        } else if (r.kind == "has_many") {
            let fkLit = Token(TokenKind.STRING_LITERAL, applyColumnNameStrategy(r.by, strategy))
            body = body + quote(
                public static let $(fieldIdent) = attachTargetRelResolver(HasMany<$(targetType)>($(nameLit), $(fkLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent), $(targetIdExtractorIdent)), $(resolverIdent))
            )
        } else {
            let viaLit = Token(TokenKind.STRING_LITERAL, r.via)
            // Task 5: 中间表目标列名随命名策略转换（junctionTargetColumnName，与 buildJunctionSchema
            // 和 relation_gen.cj 的管理方法 SQL 三处同源；不能用 targetTable + "_id"，
            // 否则 @Table 覆盖目标表名时列名不一致）。宏层在编译期计算并传入 RefMany。
            let junctionTargetColLit = Token(TokenKind.STRING_LITERAL, junctionTargetColumnName(r.target, strategy))
            body = body + quote(
                public static let $(fieldIdent) = attachTargetRelResolver(RefMany<$(targetType)>($(nameLit), $(viaLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent), $(junctionTargetColLit), $(targetIdExtractorIdent)), $(resolverIdent))
            )
        }
        first = false
    }
    // Task 7: includeAll 字符串关系名解析入口。按关系名映射到对应静态成员（关系名来自
    // rels[i].fieldName），未知名称返回 None。供 Query.includeAll 顶层解析（relResolver =
    // <实体>Rel.forName）与目标 Rel 类解析器闭包（getTargetRelResolver）调用。
    // 完全限定引用 $(relClassName).author 避免与 forName 形参名 name 的遮蔽冲突
    // （关系名恰为 "name" 时裸引用会取到形参 String 而非静态成员，类型检查会直接报错）。
    var forNameBody = Tokens()
    var forNameFirst = true
    for (i in 0..rels.size) {
        let r = rels[i]
        if (!forNameFirst) { forNameBody = forNameBody + Token(TokenKind.NL) }
        let nameLit = Token(TokenKind.STRING_LITERAL, r.fieldName)
        let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
        forNameBody = forNameBody + quote(
            case $(nameLit) => Some($(relClassName).$(fieldIdent))
        )
        forNameFirst = false
    }
    if (!forNameFirst) { forNameBody = forNameBody + Token(TokenKind.NL) }
    forNameBody = forNameBody + quote(case _ => None)
    if (body.size > 0) { body = body + Token(TokenKind.NL) }
    body = body + quote(
        public static func forName(name: String): Option<IRelation> {
            match (name) {
                $(forNameBody)
            }
        }
    )
    quote(public class $(relClassName) { $(body) })
}

func buildRowMapper(className: String, cd: ClassDecl, rels: ArrayList<RelInfo>, internalNames: ArrayList<String>, mergedFields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let funcName = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    // Task 4 一致性铁律：rowMapper 的 columnMap 键必须与 buildSelectColumnTokens（SELECT 列）
    // 用同一 lookup/columnName 源，否则 columnMap.contains 恒 false 静默丢字段。
    let colLookup = buildNameToColumnLookup(mergedFields)
    var assignments = Tokens()
    assignments = assignments + Token(TokenKind.LET)
    assignments = assignments + Token(TokenKind.IDENTIFIER, "entity")
    assignments = assignments + Token(TokenKind.ASSIGN)
    assignments = assignments + cn
    assignments = assignments + Token(TokenKind.LPAREN)
    assignments = assignments + Token(TokenKind.RPAREN)
    assignments = assignments + Token(TokenKind.NL)
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fieldTypeStr = vd.declType.toTokens().toString()
                if (isRelationField(fieldTypeStr)) { continue }
                if (isGeneratedInternalField(vd.identifier.value, internalNames)) { continue }
                if (!first) { assignments = assignments + Token(TokenKind.NL) }
                let fieldNameLit = Token(TokenKind.STRING_LITERAL, lookupColumnName(colLookup, vd.identifier.value))
                // F4: Option<DateTime> 可空标量用 getOrNull<内部类型> 读取（NULL → None，
                // 有值 → Some<DateTime>），普通字段保持 result.get<T>。修复前该字段被
                // isRelationField 跳过，RowMapper 不赋值（读回恒 None，数据不可达）。
                if (isNullableScalarType(fieldTypeStr)) {
                    let innerType = Token(TokenKind.IDENTIFIER, unwrapOptionType(fieldTypeStr))
                    let fieldAssign = quote(
                        if (columnMap.contains($(fieldNameLit))) {
                            entity.$(vd.identifier) = result.getOrNull<$(innerType)>(columnMap.get($(fieldNameLit)).getOrThrow())
                        }
                    )
                    assignments = assignments + fieldAssign
                } else if (isJsonFallbackType(fieldTypeStr)) {
                    // M8-Json Task 2: Json 兜底 struct 字段读路径——DB 存 JSON 文本（String），
                    // 先 get<String> 取出文本再 stringToJson<F> 反序列化回 struct 赋给字段。
                    // 字段类型 F 由 declType 推导（stringToJson<T> 约束 T <: JsonDeserializable<T>，
                    // struct 未实现接口 → 编译失败，比运行时更早暴露）。
                    let fieldType = Token(TokenKind.IDENTIFIER, fieldTypeStr)
                    let fieldAssign = quote(
                        if (columnMap.contains($(fieldNameLit))) {
                            let s = result.get<String>(columnMap.get($(fieldNameLit)).getOrThrow())
                            entity.$(vd.identifier) = stringToJson<$(fieldType)>(s)
                        }
                    )
                    assignments = assignments + fieldAssign
                } else {
                    let fieldAssign = quote(
                        if (columnMap.contains($(fieldNameLit))) {
                            entity.$(vd.identifier) = result.get<$(vd.declType)>(columnMap.get($(fieldNameLit)).getOrThrow())
                        }
                    )
                    assignments = assignments + fieldAssign
                }
                first = false
            case _ => ()
        }
    }
    for (ri in 0..rels.size) {
        let r = rels[ri]
        if (r.kind == "ref_to" || r.kind == "has_one") {
            let prefixCheck = r.fieldName + ".id"
            let prefixCheckLit = Token(TokenKind.STRING_LITERAL, prefixCheck)
            let tmpName = Token(TokenKind.IDENTIFIER, "tmp")
            let targetType = Token(TokenKind.IDENTIFIER, r.target)
            let backingIdent = Token(TokenKind.IDENTIFIER, "_" + r.fieldName)
            // ref_to 的 fk 字段在当前实体上，类型可推导（支持 String-pk 目标）；
            // has_one 的 fk 在目标表、目标 pk 类型宏层无法跨类内省，保持 Int64（has_one→String-pk 目标暂不支持）
            let idTypeTok = if (r.kind == "ref_to" && getDeclFieldType(cd, r.by) == "String") {
                Token(TokenKind.IDENTIFIER, "String")
            } else {
                Token(TokenKind.IDENTIFIER, "Int64")
            }
            assignments = assignments + Token(TokenKind.NL)
            let check = quote(
                if (columnMap.contains($(prefixCheckLit))) {
                    match (result.getOrNull<$(idTypeTok)>(columnMap.get($(prefixCheckLit)).getOrThrow())) {
                        case Some(id) =>
                            let $(tmpName) = $(targetType)()
                            $(tmpName).id = id
                            entity.$(backingIdent) = Some($(tmpName))
                        case None => ()
                    }
                }
            )
            assignments = assignments + check
        }
    }
    assignments = assignments + Token(TokenKind.NL)
    assignments = assignments + Token(TokenKind.IDENTIFIER, "entity")
    quote(
        func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): $(cn) { $(assignments) }
    )
}

// Task 4: has_many/has_one 批量装配的主实体主键原始值提取器。返回 Any（Int64/String 自动上转），
// 主查询映射循环内逐行收集，供 `WHERE 目标.fk IN (主实体 id)` 批量查询与按 fk 分组回填。
// 被 rawIdExtractor 取代的旧 keyExtractor（输出 String「复合主键 ":" 拼接」）无法直接作为
// SQL 参数原值，故另设 rawId（R-M1 已删除 keyExtractor 全套）。
// 复合主键（pkSize > 1）不生成：目标 fk 是单列，无法匹配 ":" 拼接键（计划 D6 限制），
// 返回空 Tokens，refine_macro.cj 亦不 setRawIdExtractor → 装配入口抛 QueryException。
// 生成的函数内嵌主键列存在性守卫：用户 `.select(...)` 省略主键列时，
// 抛带列名的 QueryException（而非 Option.getOrThrow 的裸错误）。
func buildRawIdExtractor(className: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "RawIdFromResult")
    let pkSize = pkFields.size
    if (pkSize == 0) {
        let guardMsg = "主查询 SELECT 必须包含主键列 'id' 以支持集合 include（批量装配需要主键）"
        let idLit = Token(TokenKind.STRING_LITERAL, "id")
        let guardMsgLit = Token(TokenKind.STRING_LITERAL, guardMsg)
        return quote(
            func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): Any {
                if (!columnMap.contains($(idLit))) {
                    throw QueryException($(guardMsgLit))
                }
                result.get<Int64>(columnMap.get($(idLit)).getOrThrow())
            }
        )
    } else if (pkSize == 1) {
        let pk = pkFields.get(0).getOrThrow()
        let pkNameLit = Token(TokenKind.STRING_LITERAL, pk.columnName)
        let guardMsg = "主查询 SELECT 必须包含主键列 '" + pk.columnName + "' 以支持集合 include（批量装配需要主键）"
        let guardMsgLit = Token(TokenKind.STRING_LITERAL, guardMsg)
        if (pk.typeName == "String") {
            return quote(
                func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): Any {
                    if (!columnMap.contains($(pkNameLit))) {
                        throw QueryException($(guardMsgLit))
                    }
                    result.get<String>(columnMap.get($(pkNameLit)).getOrThrow())
                }
            )
        } else {
            return quote(
                func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): Any {
                    if (!columnMap.contains($(pkNameLit))) {
                        throw QueryException($(guardMsgLit))
                    }
                    result.get<Int64>(columnMap.get($(pkNameLit)).getOrThrow())
                }
            )
        }
    } else {
        Tokens()
    }
}

func buildRowMapperMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let mapperFunc = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    quote(
        public static func rowMapper(): (QueryResult, HashMap<String, Int64>) -> $(cn) {
            $(mapperFunc)
        }
    )
}

func buildFindAllMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    quote(
        public static func findAll(query: Query<$(cn)>): Array<$(cn)> { query.all() }
    )
}

func buildFindOneMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    quote(
        public static func findOne(query: Query<$(cn)>): Option<$(cn)> { query.one() }
    )
}