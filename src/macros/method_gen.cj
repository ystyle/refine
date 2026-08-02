macro package refine.macros

import std.ast.*
import std.collection.ArrayList

func buildColsStruct(className: String, cd: ClassDecl, internalNames: ArrayList<String>): Tokens {
    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    var colsFields = Tokens()
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fn = vd.identifier.value
                if (isGeneratedInternalField(fn, internalNames)) { continue }
                if (!first) { colsFields = colsFields + Token(TokenKind.NL) }
                colsFields = colsFields + quote(
                    public let $(vd.identifier): Col<$(vd.declType)> = Col<$(vd.declType)>($(Token(TokenKind.STRING_LITERAL, fn)))
                )
                first = false
            case _ => ()
        }
    }
    quote(
        public struct $(colsName) { $(colsFields) init() {} }
    )
}


func buildRelClass(className: String, rels: ArrayList<RelInfo>): Tokens {
    let relClassName = Token(TokenKind.IDENTIFIER, className + "Rel")
    if (rels.size == 0) { return quote(public class $(relClassName) {}) }
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
        body = body + quote(
            public static let $(mapperIdent) = $(mapperFuncIdent)
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
            fieldsTok = genFieldCols(r.fields)
        } else {
            fieldsTok = Tokens()
            fieldsTok = fieldsTok + colNamesFunc
            fieldsTok = fieldsTok + Token(TokenKind.LPAREN)
            fieldsTok = fieldsTok + Token(TokenKind.RPAREN)
        }
        if (r.kind == "ref_to") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
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
            body = body + quote(
                public static let $(fieldIdent) = RefTo<$(targetType)>($(nameLit), Col<Any>($(fkLit)), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent), $(extractorIdent))
            )
        } else if (r.kind == "has_one") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                public static let $(fieldIdent) = HasOne<$(targetType)>($(nameLit), $(fkLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent))
            )
        } else if (r.kind == "has_many") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                public static let $(fieldIdent) = HasMany<$(targetType)>($(nameLit), $(fkLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent))
            )
        } else {
            let viaLit = Token(TokenKind.STRING_LITERAL, r.via)
            // Task 5: 中间表目标列名固定用 lowerTableName(目标类) + "_id"（与 buildJunctionSchema
            // 和 relation_gen.cj 的 INSERT/LOAD SQL 一致，不能用 targetTable + "_id"，
            // 否则 @Table 覆盖目标表名时列名不一致）。宏层在编译期计算并传入 RefMany。
            let junctionTargetColLit = Token(TokenKind.STRING_LITERAL, lowerTableName(r.target) + "_id")
            body = body + quote(
                public static let $(fieldIdent) = RefMany<$(targetType)>($(nameLit), $(viaLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent), $(junctionTargetColLit))
            )
        }
        first = false
    }
    quote(public class $(relClassName) { $(body) })
}

func buildRowMapper(className: String, cd: ClassDecl, rels: ArrayList<RelInfo>, internalNames: ArrayList<String>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let funcName = Token(TokenKind.IDENTIFIER, className + "RowMapper")
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
                let fieldNameLit = Token(TokenKind.STRING_LITERAL, vd.identifier.value)
                let fieldAssign = quote(
                    if (columnMap.contains($(fieldNameLit))) {
                        entity.$(vd.identifier) = result.get<$(vd.declType)>(columnMap.get($(fieldNameLit)).getOrThrow())
                    }
                )
                assignments = assignments + fieldAssign
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

func buildKeyExtractor(className: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "KeyFromResult")
    let pkSize = pkFields.size
    if (pkSize == 0) {
        return quote(
            func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String {
                result.get<Int64>(columnMap.get("id").getOrThrow()).toString()
            }
        )
    } else if (pkSize == 1) {
        let pk = pkFields.get(0).getOrThrow()
        let pkNameLit = Token(TokenKind.STRING_LITERAL, pk.name)
        if (pk.typeName == "String") {
            return quote(
                func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String {
                    result.get<String>(columnMap.get($(pkNameLit)).getOrThrow())
                }
            )
        } else {
            return quote(
                func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String {
                    result.get<Int64>(columnMap.get($(pkNameLit)).getOrThrow()).toString()
                }
            )
        }
    } else {
        var parts = Tokens()
        var first = true
        for (i in 0..pkSize) {
            let pk = pkFields.get(i).getOrThrow()
            let pkNameLit = Token(TokenKind.STRING_LITERAL, pk.name)
            if (first) {
                parts = parts + Token(TokenKind.IDENTIFIER, "var")
                parts = parts + Token(TokenKind.IDENTIFIER, "key")
                parts = parts + Token(TokenKind.ASSIGN)
            } else {
                parts = parts + Token(TokenKind.NL)
                parts = parts + Token(TokenKind.IDENTIFIER, "key")
                parts = parts + Token(TokenKind.ASSIGN)
                parts = parts + Token(TokenKind.IDENTIFIER, "key")
                parts = parts + Token(TokenKind.ADD)
                parts = parts + Token(TokenKind.STRING_LITERAL, ":")
                parts = parts + Token(TokenKind.ADD)
            }
            if (pk.typeName == "String") {
                parts = parts + quote(result.get<String>(columnMap.get($(pkNameLit)).getOrThrow()))
            } else {
                parts = parts + quote(result.get<Int64>(columnMap.get($(pkNameLit)).getOrThrow()).toString())
            }
            first = false
        }
        parts = parts + Token(TokenKind.NL)
        parts = parts + Token(TokenKind.IDENTIFIER, "key")
        quote(
            func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String { $(parts) }
        )
    }
}

// Task 4: has_many/has_one 批量装配的主实体主键原始值提取器。返回 Any（Int64/String 自动上转），
// 主查询映射循环内逐行收集，供 `WHERE 目标.fk IN (主实体 id)` 批量查询与按 fk 分组回填。
// keyExtractor 输出 String（复合主键 ":" 拼接），无法直接作为 SQL 参数原值，故另设 rawId。
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
        let pkNameLit = Token(TokenKind.STRING_LITERAL, pk.name)
        let guardMsg = "主查询 SELECT 必须包含主键列 '" + pk.name + "' 以支持集合 include（批量装配需要主键）"
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