macro package refine.macros

import std.ast.*
import std.collection.ArrayList

func buildColumnNamesFunc(className: String, cd: ClassDecl, internalNames: ArrayList<String>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "ColumnNames")
    var columns = Tokens()
    columns = columns + Token(TokenKind.LSQUARE)
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fieldTypeStr = vd.declType.toTokens().toString()
                if (isRelationField(fieldTypeStr)) { continue }
                if (isGeneratedInternalField(vd.identifier.value, internalNames)) { continue }
                if (!first) { columns = columns + Token(TokenKind.COMMA) }
                let nameLit = Token(TokenKind.STRING_LITERAL, vd.identifier.value)
                columns = columns + quote(Col<Any>($(nameLit)))
                first = false
            case _ => ()
        }
    }
    columns = columns + Token(TokenKind.RSQUARE)
    quote(
        func $(funcName)(): Array<Col<Any>> { $(columns) }
    )
}

func buildSchemaClass(className: String, fields: ArrayList<FieldInfo>, tableName: String): Tokens {
    let schemaName = Token(TokenKind.IDENTIFIER, className + "Schema")
    let tableNameLit = Token(TokenKind.STRING_LITERAL, tableName)
    var colDefs = Tokens()
    var first = true
    for (i in 0..fields.size) {
        let f = fields[i]
        if (isRelationField(f.typeName)) { continue }
        if (!first) { colDefs = colDefs + Token(TokenKind.COMMA) + Token(TokenKind.NL) }
        let nameLit = Token(TokenKind.STRING_LITERAL, f.name)
        let st = if (f.storageOverride != "") { "StorageType." + f.storageOverride } else { typeNameToStorageType(f.typeName) }
        let isPk = if (f.isPk) { "true" } else { "false" }
        let isAutoInc = if (f.autoInc) { "true" } else { "false" }
        // F4: Option<DateTime> 可空标量生成 nullable 列（ColumnDef 第五参 true）——
        // 否则 INSERT None 绑 NULL 会触发 DB NOT NULL 错误（硬编码 false 时该列 NOT NULL）。
        let isNullable = if (isNullableScalarType(f.typeName)) { "true" } else { "false" }
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, "ColumnDef") + Token(TokenKind.LPAREN) + nameLit + Token(TokenKind.COMMA)
        if (f.storageOverride == "Bool" || (f.storageOverride == "" && f.typeName == "Bool")) {
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, "StorageType") + Token(TokenKind.DOT)
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, "`Bool`")
        } else {
            let stParts = st.split(".")
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, stParts[0]) + Token(TokenKind.DOT)
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, stParts[1])
        }
        colDefs = colDefs + Token(TokenKind.COMMA) + Token(TokenKind.IDENTIFIER, isPk) + Token(TokenKind.COMMA)
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, isAutoInc) + Token(TokenKind.COMMA)
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, isNullable) + Token(TokenKind.RPAREN)
        first = false
    }
    quote(
        public class $(schemaName) <: TableSchema {
            public func tableName(): String { $(tableNameLit) }
            public func columns(): Array<ColumnDef> { [$(colDefs)] }
            public func indexes(): Array<IndexDef> { [] }
        }
    )
}

// F1: junction 源列类型跟随源实体主键类型（宏层可内省 className 的 pkFields）。
// 目标列类型 = 目标实体主键类型，但宏层无法跨类内省目标类字段（同 has_one→String-pk
// 目标的既有限制），故目标列保持 Integer：Int64-pk 目标正确；String-pk 目标时
// junction 目标列需 TEXT 而宏层无法推导，属已文档化限制（需手工迁移或用 Int64-pk 目标）。
// R-I9: 该限制的失败模式已收敛——relation_gen.cj 的 ref_many append/delete 生成守卫，
// 目标 id 为 String 时在 tx.execute 之前抛明确 RefineException（而非 String 绑进
// INTEGER 列的真实 DB 类型错误）。读路径（loadX/countX/include 批量装配）不受影响。
func buildJunctionSchema(className: String, rel: RelInfo, tableName: String, sourcePkStorage: String): Tokens {
    let sourceTable = tableName
    let viaLit = Token(TokenKind.STRING_LITERAL, rel.via)
    let srcColLit = Token(TokenKind.STRING_LITERAL, sourceTable + "_id")
    let tgtColLit = Token(TokenKind.STRING_LITERAL, lowerTableName(rel.target) + "_id")
    let schemaName = Token(TokenKind.IDENTIFIER, className + "_" + upperFirstLetter(rel.fieldName) + "JunctionSchema")
    let srcStParts = sourcePkStorage.split(".")
    let srcStorageTypeTok = Token(TokenKind.IDENTIFIER, srcStParts[0])
    let srcStorageNameTok = Token(TokenKind.IDENTIFIER, srcStParts[1])
    // M24: junction 两列（源/目标 fk）构成复合主键——同一 (src,tgt) 关联天然唯一，
    // 防重复关联行；createTableSQL 对 ≥2 主键列的表渲染表级 `PRIMARY KEY (col1, col2)`。
    quote(
        public class $(schemaName) <: TableSchema {
            public func tableName(): String { $(viaLit) }
            public func columns(): Array<ColumnDef> {
                [ColumnDef($(srcColLit), $(srcStorageTypeTok).$(srcStorageNameTok), true, false, false),
                 ColumnDef($(tgtColLit), StorageType.Integer, true, false, false)]
            }
            public func indexes(): Array<IndexDef> { [] }
        }
    )
}

func buildSchemasFunc(className: String, junctionRelNames: ArrayList<String>): Tokens {
    let schemaName = Token(TokenKind.IDENTIFIER, className + "Schema")
    if (junctionRelNames.size == 0) {
        quote(
            public static func schemas(): Array<TableSchema> { [$(schemaName)()] }
        )
    } else {
        var arr = Tokens()
        arr = arr + Token(TokenKind.IDENTIFIER, className + "Schema")
        arr = arr + Token(TokenKind.LPAREN) + Token(TokenKind.RPAREN)
        for (relName in junctionRelNames) {
            arr = arr + Token(TokenKind.COMMA)
            let jsName = Token(TokenKind.IDENTIFIER, className + "_" + upperFirstLetter(relName) + "JunctionSchema")
            arr = arr + jsName
            arr = arr + Token(TokenKind.LPAREN) + Token(TokenKind.RPAREN)
        }
        quote(
            public static func schemas(): Array<TableSchema> { [$(arr)] }
        )
    }
}
