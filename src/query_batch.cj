package refine

import std.collection.ArrayList
import std.collection.HashMap
import std.collection.HashSet
import std.database.sql.QueryResult

// M20: Query<T> 批量 include 装配方法组（727 行，原 query.cj 的膨胀主体）。
// 通过 extend 从 query.cj 核心类中按职责拆出。extend 不能访问被扩展类型的
// private 成员，故类内被本文件调用的成员（included/rawIdExtractor/
// MaxNestedDepth/getSourceTable 及 query.cj 的 requireExecutor 等）在核心为
// 包级可见。本文件内只在本块使用的方法为 private（扩展内 private 仅同块可见）；
// assembleIncludes/mapMainResult/requireCollectionIdSupport 被 query_exec.cj
// 跨文件调用，保持包级可见。装配引擎沿用原语义与注释，逐字迁移。
extend<T> Query<T> {

    // Task 3: ref_to 批量装配。主查询返回实体后调用：
    //   1. 按目标表分组（保持 rels 顺序），同表多个 ref_to 关系合并为一条批量查询；
    //   2. 收集各实体外键值（getForeignKeyExtractor），去重并过滤 0/"" 未设置值；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT <字段并集> FROM <目标表> WHERE "id" IN (?, ...)` 批量取目标；
    //   5. 目标 id → 实体 映射，按各关系 fk 值命中回填（未命中保持未挂载，不抛错）。
    // Task 6 扩展：返回各关系实际装配到的目标实体数组（按关系去重——同一目标实体被
    // 多个主实体引用时只收集一次），供嵌套 include 递归装配下一层关联使用。
    // E 泛型：顶层为 Array<T>（主查询实体），嵌套层为 Array<Any>（上一层装配结果）。
    // 批量 SQL 采用手写占位符（与 relation_gen.cj 一致）：IN 列表不是 Expr 模型的一部分
    // （Expr.Value 数组渲染为单个参数，无法展开为 ?,?,...），且在 scope 内不允许改动
    // 三方言 renderExpr 为 IN 列表新增变体，故 SELECT/FROM 走 Statement 机器，
    // WHERE 的 IN 部分由 buildInClause 手写占位符生成。
    // R-I2：sourceColumnMap 是产生当前 entities 的查询结果列映射（顶层为主查询 columnMap，
    // 嵌套层为父关系批量查询 columnMap）。ref_to 批量装配需要从主实体读 fk 值，若主查询
    // SELECT 省略 fk 列（如 select([id, title]) include author），宏层 mapper 对缺失列宽容
    // （列缺失字段留默认值 0/""），isEmptyFk 会把整批 fk 误判为空而静默跳过批量查询，
    // author 恒为 None 且无任何错误。故每个 ref_to 关系的 fk 列必须出现在 sourceColumnMap
    // 中，否则抛带关系名与列名的 QueryException（fail-fast，风格同 has_many 的 rawIdExtractor
    // 主键守卫；只守卫 ref_to——has_many/has_one 用主实体主键，已由 requireCollectionIdSupport/
    // rawIdExtractor 守卫）。守卫与行数无关：空行集下配置错误同样抛错。
    // Task 6 递归需要把各关系装配到的目标实体（targets）对应的批量查询 columnMap 一并返回
    // （三元组第三位），供下一层递归对嵌套 ref_to 做同样的 fk 列守卫。
    private func assembleRefTo<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rels: Array<IRelation>,
        sourceColumnMap: HashMap<String, Int64>
    ): ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)> {
        let result = ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)>()
        if (rels.size == 0) { return result }

        // R-I2 守卫：所有 ref_to 关系的 fk 列必须出现在源结果列映射中。
        // sourceColumnMap.size == 0（驱动/mock 返回空列元信息，如 RMockDS 空结果集）时
        // 无法验证，fail-open 保持旧行为（真实驱动的 SELECT 结果恒带列元信息，可验证）。
        for (rel in rels) {
            let (kind, relName, _, fkName, _, _) = rel.resolve()
            if (kind != RelationKind.RefToRel) { continue }
            if (sourceColumnMap.size > 0 && !sourceColumnMap.contains(fkName)) {
                throw QueryException("include ref_to '" + relName + "' requires fk column '" + fkName +
                    "' in the SELECT (batch include needs the foreign key value)")
            }
        }

        if (entities.size == 0) { return result }

        var groups = ArrayList<(String, ArrayList<IRelation>)>()
        for (inc in rels) {
            let (kind, _, targetTable, _, _, _) = inc.resolve()
            if (kind != RelationKind.RefToRel) { continue }
            var found = false
            for (i in 0..groups.size) {
                if (groups[i][0] == targetTable) {
                    groups[i][1].add(inc)
                    found = true
                    break
                }
            }
            if (!found) {
                let rels2 = ArrayList<IRelation>()
                rels2.add(inc)
                groups.add((targetTable, rels2))
            }
        }

        for (i in 0..groups.size) {
            let targetTable = groups[i][0]
            let rels2 = groups[i][1]

            // 1. 收集该目标表全部 fk 值（跨关系去重、过滤 0/""）
            var ids = ArrayList<Any>()
            var seen = HashMap<String, Bool>()
            for (rel in rels2) {
                let extractor = rel.getForeignKeyExtractor()
                for (entity in entities) {
                    let v = extractor(entity)
                    if (isEmptyFk(v)) { continue }
                    let key = fkKey(v)
                    if (!seen.contains(key)) {
                        seen[key] = true
                        ids.add(v)
                    }
                }
            }
            if (ids.size == 0) { continue }

            // 2. 字段并集 + 强制目标主键列（装配查表与回填都用），批量查询
            let cols = buildBatchSelectCols(rels2, ["id"])
            let (inSQL, inParams) = buildInClause(dialect, "id", ids.toArray())
            let result2 = execBatchQuery(exec, dialect, targetTable, cols, inSQL, inParams)

            // 3. 目标 id → 实体 映射（同表关系共享同一目标 RowMapper）
            let columnMap = buildColumnMap(result2.columnInfos, exec.getParamOffset())
            let idIdx = columnMap.get("id").getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels2[0].getTargetMapper()
            var targetMap = HashMap<String, Any>()
            while (result2.next()) {
                let idKey = if (isStringPk) {
                    result2.get<String>(idIdx)
                } else {
                    result2.get<Int64>(idIdx).toString()
                }
                targetMap[idKey] = targetMapper(result2, columnMap)
            }

            // 4. 回填：fk 命中即挂载，未命中（目标被删）保持未挂载；同时收集该关系
            //    装配到的目标实体（按 fkKey 去重：多个主实体引用同一目标只收集一次）。
            for (rel in rels2) {
                let extractor = rel.getForeignKeyExtractor()
                let setter = rel.getFieldSetter()
                var targets = ArrayList<Any>()
                var targetSeen = HashMap<String, Bool>()
                for (entity in entities) {
                    let v = extractor(entity)
                    if (isEmptyFk(v)) { continue }
                    let key = fkKey(v)
                    match (targetMap.get(key)) {
                        case Some(t) =>
                            setter(entity, t)
                            if (!targetSeen.contains(key)) {
                                targetSeen[key] = true
                                targets.add(t)
                            }
                        case None => ()
                    }
                }
                result.add((rel, targets.toArray(), columnMap))
            }
        }
        result
    }

    // 构建 `col IN (?, ?...)` 子句。契约：返回的 (fragment, params) 必须一体追加——
    // 本 WHERE 子句内不能再有其它 Value 占位符（否则 render 收集的参数顺序会与占位符错位）。
    // 批量装配目前只有 IN 列表一个参数源，此契约在 Task 4/5 复用批量装配时同样成立。
    private func buildInClause(dialect: Dialect, col: String, ids: Array<Any>): (String, Array<Any>) {
        buildInClauseCol(dialect.quoteIdentifier(col), ids)
    }

    // buildInClause 的通用形态：colSQL 是调用方已构造好的列引用片段（可带表限定，
    // 如 SQLite 的 `"post_tags"."postWithRel_id"`），仅负责生成占位符与参数。
    // Task 5 ref_many junction 查询的 IN 列在中间表上且需表限定，不能经 quoteIdentifier 二次转义。
    private func buildInClauseCol(colSQL: String, ids: Array<Any>): (String, Array<Any>) {
        var placeholders = ArrayList<String>()
        for (_ in 0..ids.size) { placeholders.add("?") }
        (colSQL + " IN (" + String.join(placeholders.toArray(), delimiter: ", ") + ")", ids)
    }

    // 批量 SELECT 的字段并集 + 强制列：同表多关系合并时取所有选中列；forced 为必须选中的列
    // （目标主键 id、has_many/has_one 的 fk 分组键），即使不在字段子集里也强制前置。
    // 取舍：合并查询按「并集」SELECT，共享目标实体携带并集列值（非某关系声明的子集），属预期行为。
    private func buildBatchSelectCols(rels: ArrayList<IRelation>, forced: Array<String>): Array<Expr> {
        var fieldNames = ArrayList<String>()
        var seenField = HashMap<String, Bool>()
        for (rel in rels) {
            let (_, _, _, _, _, fields) = rel.resolve()
            for (c in fields) {
                if (!seenField.contains(c.name)) {
                    seenField[c.name] = true
                    fieldNames.add(c.name)
                }
            }
        }
        var cols = ArrayList<Expr>()
        var selected = HashMap<String, Bool>()
        for (name in forced) {
            cols.add(Expr.Column(name))
            selected[name] = true
        }
        for (name in fieldNames) {
            if (!selected.contains(name)) {
                selected[name] = true
                cols.add(Expr.Column(name))
            }
        }
        cols.toArray()
    }

    // 执行批量 IN 查询：SELECT <cols> FROM <table> WHERE <inSQL>，返回结果集。
    // inSQL/inParams 必须由 buildInClause 一体生成（本 WHERE 内无其它 Value 占位符），
    // SELECT/FROM 走 Statement 机器、WHERE 的 IN 部分手写占位符（见 assembleRefTo 注释）。
    private func execBatchQuery(
        exec: ExecutionContext,
        dialect: Dialect,
        targetTable: String,
        cols: Array<Expr>,
        inSQL: String,
        inParams: Array<Any>
    ): QueryResult {
        let bs = Statement()
        bs.addClause(Clause.SelectClause(cols))
        bs.addClause(Clause.FromClause(targetTable))
        bs.addClause(Clause.WhereClause([Expr.Raw(inSQL)]))
        let (sql, baseParams) = dialect.render(bs)
        var params = ArrayList<Any>()
        for (p in baseParams) { params.add(p) }
        for (v in inParams) { params.add(v) }
        Logger.logSQL(sql, params.toArray())
        exec.query(sql, params.toArray())
    }

    private func isEmptyFk(v: Any): Bool {
        match (v) {
            case i: Int64 => i == 0
            case s: String => s == ""
            case _ => false
        }
    }

    private func fkKey(v: Any): String {
        match (v) {
            case i: Int64 => i.toString()
            case s: String => s
            case _ => throw QueryException("unsupported foreign key value type for batch ref_to")
        }
    }

    private func fkIsString(v: Any): Bool {
        match (v) {
            case _: String => true
            case _ => false
        }
    }

    // 递归深度上限 MaxNestedDepth 的定义与完整理由见 query.cj 核心类（本文件直接引用）。

    // 批量装配调度：统一递归引擎入口（Task 6 起 ref_to / has_one / has_many / ref_many
    // 与嵌套 include 共用同一条递归路径，见 assembleRecursive）。顶层 rels = included，
    // depth = 0，sourceTable = 顶层主查询 FROM 表（getSourceTable）；rawIds 与 entities
    // 按索引对齐，仅在 needsCollectionAssembly() 时有意义。
    // R-I2：mainColumnMap 是主查询结果列映射，供顶层 ref_to 的 fk 列守卫使用
    // （嵌套层由 assembleRecursive 逐层传入父批量查询的 columnMap）。
    func assembleIncludes(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<T>,
        rawIds: Array<Any>,
        mainColumnMap: HashMap<String, Int64>
    ): Unit {
        assembleRecursive(exec, dialect, entities, included.toArray(), rawIds, mainColumnMap, getSourceTable(), 0)
    }

    // Task 6: 嵌套 include 统一装配引擎（递归）。对 entities（E 泛型：顶层为 Array<T>
    // 主实体、嵌套层为 Array<Any> 上一层装配结果）装配 rels 中声明的关联，并递归装配
    // 各关联目标实体的嵌套 include（rel.getNested()）。按 kind 分派三条协议：
    //   ref_to 组 → 读实体 fk（getForeignKeyExtractor）→ `WHERE 目标."id" IN (fk 集合)`
    //   has_one/has_many 组 → 读实体原始主键（mainIds，与 entities 按索引对齐）
    //     → `WHERE 目标."fk" IN (主键集合)`
    //   ref_many 组 → junction 中间表批量查询（源列 = <sourceTable>_id）
    // 三条协议各返回 (relation, 该关系装配到的目标实体数组)；对每条声明了嵌套的关系，
    // 用父关系 getTargetIdExtractor 读目标实体主键作为下一层 mainIds，递归下一层。
    // sourceTable = 当前层级 entities 所在的表：顶层为主查询 FROM 表（getSourceTable），
    // 嵌套层为父关系的 targetTable（ref_many 的 junction 源列必须跟随当前层级，否则嵌套
    // ref_many 会错误使用顶层表名生成 `<顶层表>_id`，PG 上报 column does not exist）。
    // 深度超过 MaxNestedDepth 抛 QueryException（含 include 环时终止递归）。
    private func assembleRecursive<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rels: Array<IRelation>,
        mainIds: Array<Any>,
        sourceColumnMap: HashMap<String, Int64>,
        sourceTable: String,
        depth: Int64
    ): Unit {
        if (depth > MaxNestedDepth) {
            throw QueryException("nested include exceeds max depth " + MaxNestedDepth.toString() +
                "; check for include cycles")
        }
        if (rels.size == 0) { return }
        // 不因 entities.size == 0 提前返回：assembleRefTo 的 R-I2 fk 列守卫与行数无关，
        // 空结果集下 SELECT 缺 fk 列同样是配置错误，必须 fail-fast（对齐
        // requireCollectionIdSupport 与行数无关的守卫语义）。各装配协议内部仍有
        // entities.size == 0 早退，不会对空集发批量查询。

        // 1. 按 kind 分组（保持各组内 rels 顺序；ref_to → 集合 → ref_many 三条协议依次执行）
        var refToRels = ArrayList<IRelation>()
        var collRels = ArrayList<IRelation>()
        var refManyRels = ArrayList<IRelation>()
        for (rel in rels) {
            let (kind, _, _, _, _, _) = rel.resolve()
            match (kind) {
                case RelationKind.RefToRel => refToRels.add(rel)
                case RelationKind.RefManyRel => refManyRels.add(rel)
                case RelationKind.HasOneRel | RelationKind.HasManyRel => collRels.add(rel)
            }
        }

        // 2. 三条协议依次装配，收集各关系装配到的目标实体（三元组第三位为产生 targets 的
        //    批量查询 columnMap，供下一层递归对嵌套 ref_to 做 fk 列守卫，见 assembleRefTo 注释）。
        var pairs = ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)>()
        let refToPairs = assembleRefTo(exec, dialect, entities, refToRels.toArray(), sourceColumnMap)
        for (p in refToPairs) { pairs.add(p) }
        if (collRels.size > 0 || refManyRels.size > 0) {
            let collPairs = assembleCollections(exec, dialect, entities, mainIds, collRels.toArray())
            for (p in collPairs) { pairs.add(p) }
            let refManyPairs = assembleRefMany(exec, dialect, entities, mainIds, refManyRels.toArray(), sourceTable)
            for (p in refManyPairs) { pairs.add(p) }
        }

        // 3. 递归装配各关系的嵌套 include（目标实体为空时下一层早退，不产生额外查询）。
        //    下一层 sourceTable = 父关系的 targetTable（当前层实体的表），供嵌套 ref_many
        //    推导 junction 源列 `<当前层表>_id`；下一层 sourceColumnMap = 父批量查询的
        //    columnMap（targetColumnMap），供嵌套 ref_to 的 fk 列守卫使用。
        // 3.1 R-M10：先按「下一层源表」合并 pairs。diamond include（同一层两条关系指向
        //     同一目标表且带相同嵌套 include，如 author.withInclude(profile) +
        //     editor.withInclude(profile)，author/editor 指向同一个用户）下，逐对递归会
        //     对共享目标实例跑两次嵌套装配——嵌套 has_many 的 setter .add() 把子项重复
        //     追加成两份（同一实例被两个 pair 的目标列表同时持有，见 assembleRefTo 的
        //     identity-map 缓存与 assembleCollections/assembleRefMany 的 targetSeen 注释）。
        //     合并后每个目标表只递归一次：
        //       - targets 取各 pair 并集，按 refEq（对象引用）去重——只有「同一实例」才
        //         会重复装配；has_one/has_many 不同 fk 指向同一行的独立实例 refEq 不相等，
        //         各自保留并递归，不会误删嵌套装配（若按 target id 去重会把第二条独立
        //         实例漏掉，导致其父关系看到空嵌套）；
        //       - nested 取各 pair 的嵌套关系并集，按结构 key 去重——宏层 getNested 每次
        //         返回新 IRelation 实例，同一逻辑关系须按 (kind,name,table,fk,via,fields)
        //         归一化识别（见 nestedRelationKey）；
        //       - sourceColumnMap 取各 pair 列名并集（嵌套 ref_to 的 fk 列守卫只查
        //         contains，任一源查询选中该列即通过；目标实例来自多条批量查询时按并集
        //         放行是安全超集，对齐 assembleRefTo 的 fail-open 语义）。
        //     单层各关系的 setter 回填仍逐关系执行（第 2 步已按主实体完成），合并只作用于
        //     递归层，不改变当前层每个关系的回填语义。
        //     R-M10 over-fill：若同表两条关系的嵌套声明不同（如 author 带 profile、
        //     editor 带 settings），并集让所有目标都装上两套嵌套——从任一关系装配到的目标
        //     都会看到并集字段（extra 嵌套可能为空列表），无数据丢失/重复，仅多填字段。
        //     与「union fields」哲学一致（对齐 sourceColumnMap 的安全超集），不做按关系切分。
        var recGroups = ArrayList<(String, ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)>)>()
        for (pair in pairs) {
            let (rel, _, _) = pair
            if (rel.getNested().size == 0) { continue }
            let (_, _, nextTable, _, _, _) = rel.resolve()
            var found = false
            for (i in 0..recGroups.size) {
                if (recGroups[i][0] == nextTable) {
                    recGroups[i][1].add(pair)
                    found = true
                    break
                }
            }
            if (!found) {
                let pl = ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)>()
                pl.add(pair)
                recGroups.add((nextTable, pl))
            }
        }

        // 3.2 每组合并目标/嵌套/列映射后递归一次
        for (g in recGroups) {
            let nextTable = g[0]
            let groupPairs = g[1]
            var mergedTargets = ArrayList<Any>()
            var targetSeen = ArrayList<Object>()
            var mergedNested = ArrayList<IRelation>()
            var nestedSeen = HashMap<String, Bool>()
            var mergedColMap = HashMap<String, Int64>()
            for (pair in groupPairs) {
                let (rel, targets, colMap) = pair
                for (t in targets) {
                    match (t as Object) {
                        case Some(o) =>
                            if (!visitedContains(targetSeen, o)) {
                                targetSeen.add(o)
                                mergedTargets.add(t)
                            }
                        case None =>
                            // 目标不是引用类型（理论上的值类型目标，正常实体恒为类实例）：
                            // 无法按引用去重，直接保留
                            mergedTargets.add(t)
                    }
                }
                for (name in colMap.keys()) {
                    if (!mergedColMap.contains(name)) { mergedColMap[name] = colMap.get(name).getOrThrow() }
                }
                for (n in rel.getNested()) {
                    let nk = nestedRelationKey(n)
                    if (!nestedSeen.contains(nk)) { nestedSeen[nk] = true; mergedNested.add(n) }
                }
            }
            let firstRel = groupPairs[0][0]
            let targetIds = collectTargetIds(firstRel, mergedTargets.toArray())
            assembleRecursive(exec, dialect, mergedTargets.toArray(), mergedNested.toArray(), targetIds, mergedColMap, nextTable, depth + 1)
        }
    }

    // 递归层的 mainIds：用父关系 getTargetIdExtractor 逐目标读取主键，与 targets 按索引对齐。
    private func collectTargetIds(rel: IRelation, targets: Array<Any>): Array<Any> {
        let extractor = rel.getTargetIdExtractor()
        var ids = ArrayList<Any>()
        for (t in targets) { ids.add(extractor(t)) }
        ids.toArray()
    }

    // R-M10: 嵌套关系的结构归一化 key。宏层 getNested() 每次返回新 IRelation 实例，
    // 同一逻辑关系（如两次 withInclude 挂的同一 NestedUserRel.comments）是不同对象，
    // 不能用实例引用相等去重——按 resolve() 的结构分量 (kind,name,table,fk,via,fields)
    // 归一化（对齐 Relation.hasNested 的 (kind,name,table,fk,via) 比较，并追加 fields
    // 列名以区分字段子集包装器 FieldOverrideRelation）。不同逻辑关系（同表不同嵌套，
    // 如 profile 与 orders）key 不同，均保留并一次递归装配完全。
    private func nestedRelationKey(rel: IRelation): String {
        let (kind, name, table, fk, via, fields) = rel.resolve()
        var viaStr = ""
        match (via) {
            case Some(v) => viaStr = v
            case None => ()
        }
        var fieldParts = ArrayList<String>()
        for (c in fields) { fieldParts.add(c.name) }
        kind.toString() + "|" + name + "|" + table + "|" + fk + "|" + viaStr + "|" +
            String.join(fieldParts.toArray(), delimiter: ",")
    }

    // 是否有需要批量装配的集合 include（has_one / has_many / ref_many）。
    // ref_many 走 junction 中间表（Task 5 接入，与 has 系共用主实体原始主键 rawIds），
    // 故同样判定为需要收集 rawIds（旧 JOIN 路径的 hasCollectionInclude 已删除）。
    private func needsCollectionAssembly(): Bool {
        for (inc in included) {
            let (kind, _, _, _, _, _) = inc.resolve()
            if (kind == RelationKind.HasManyRel || kind == RelationKind.HasOneRel ||
                kind == RelationKind.RefManyRel) {
                return true
            }
        }
        false
    }

    // 集合 include 装配前置守卫：批量 has_many/has_one/ref_many 需要主实体单列主键的
    // 原始值（rawIdExtractor，宏层随 query() 挂载）。复合主键主实体或手工构造的 Query
    // 未挂载时，主查询执行前就抛带说明的 QueryException（计划 D6 限制），避免发无意义的主查询。
    func requireCollectionIdSupport(): Unit {
        if (!needsCollectionAssembly()) { return }
        match (this.rawIdExtractor) {
            case Some(_) => ()
            case None => throw QueryException(
                "batch collection include (has_many/has_one/ref_many) requires a single-column primary key" +
                " on the main entity (type=" + typeName + "); composite primary key / missing raw id extractor" +
                " not supported"
            )
        }
    }

    // 主查询映射循环内逐行收集主实体主键原始值（与实体列表按索引对齐）。前置守卫保证
    // needsCollectionAssembly() 为 true 时 rawIdExtractor 必然已挂载。
    private func collectRawId(result: QueryResult, columnMap: HashMap<String, Int64>): Any {
        this.rawIdExtractor.getOrThrow()(result, columnMap)
    }

    // 主查询映射循环：逐行 mapper + AfterFind hook + 收集 rawId（集合 include 需要主实体主键），
    // 返回 (entities, rawIds) 两个按索引对齐的数组；无集合 include 时 rawIds 为空。
    func mapMainResult(
        result: QueryResult,
        columnMap: HashMap<String, Int64>,
        mapper: (QueryResult, HashMap<String, Int64>) -> T
    ): (Array<T>, Array<Any>) {
        let collectIds = needsCollectionAssembly()
        var list = ArrayList<T>()
        var rawIds = ArrayList<Any>()
        while (result.next()) {
            let entity = mapper(result, columnMap)
            runAfterFindHooks(entity)
            list.add(entity)
            if (collectIds) { rawIds.add(collectRawId(result, columnMap)) }
        }
        (list.toArray(), rawIds.toArray())
    }

    // Task 4: has_one/has_many 批量装配。主查询返回实体后调用：
    //   1. 按 (目标表, fk) 分组（has_one 与 has_many 共享同一 fk 可合并一条批量查询）；
    //   2. 收集主实体主键原始值（rawIds，与 entities 按索引对齐），去重并过滤 0/""；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT <目标主键 + fk + 字段并集> FROM <目标表> WHERE <fk> IN (?, ...)` 批量取目标，
    //      fk 列不在字段子集里也必须强制选中（分组键）；
    //   5. 按 fk 值分组建 HashMap<FK, Array<TargetEntity>>；
    //   6. 回填：主实体按各自主键命中分组，has_many 逐个 add、has_one 取组内第一条。
    //      fk 不匹配任何主实体（脏数据/查询边界）的组不会被装配，主实体不受影响。
    // Task 6 扩展：返回各关系实际装配到的目标实体数组（has_many 取组内全部、has_one 取
    // 每条已装配实体的 ts[0]，按 target id 去重），供嵌套 include 递归装配下一层关联。
    // 去重理由：多个主实体命中同一目标分组（ref_to 共享目标、ref_many 共享目标的多副本
    // 实例）时，组内目标实例是同一个对象，重复收集会让递归层对该实例的嵌套 has_many
    // 跑两次、setter .add() 把子项追加成两份（同 assembleRefTo 的 targetSeen）。
    // rawIds 顶层来自 rawIdExtractor（主查询映射循环收集）、嵌套层来自父关系的
    // getTargetIdExtractor。
    // R-I2：三元组第三位 = 产生 targets 的批量查询 columnMap（供嵌套 ref_to fk 列守卫）。
    private func assembleCollections<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rawIds: Array<Any>,
        rels: Array<IRelation>
    ): ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)> {
        let result = ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)>()
        if (rels.size == 0 || entities.size == 0) { return result }
        if (rawIds.size != entities.size) {
            throw QueryException("internal error: rawId collection size mismatch in assembleCollections")
        }

        // 1. 按 (目标表, fk) 分组 has_one/has_many 关系
        var groups = ArrayList<(String, String, ArrayList<IRelation>)>()
        for (inc in rels) {
            let (kind, _, targetTable, fk, _, _) = inc.resolve()
            if (kind != RelationKind.HasManyRel && kind != RelationKind.HasOneRel) { continue }
            var found = false
            for (i in 0..groups.size) {
                if (groups[i][0] == targetTable && groups[i][1] == fk) {
                    groups[i][2].add(inc)
                    found = true
                    break
                }
            }
            if (!found) {
                let rels2 = ArrayList<IRelation>()
                rels2.add(inc)
                groups.add((targetTable, fk, rels2))
            }
        }
        if (groups.size == 0) { return result }

        // 2. 收集主实体 id（去重、过滤 0/"" 未设置值）
        var ids = ArrayList<Any>()
        var seen = HashMap<String, Bool>()
        for (id in rawIds) {
            if (isEmptyFk(id)) { continue }
            let key = fkKey(id)
            if (!seen.contains(key)) {
                seen[key] = true
                ids.add(id)
            }
        }
        if (ids.size == 0) { return result }

        for (i in 0..groups.size) {
            let targetTable = groups[i][0]
            let fk = groups[i][1]
            let rels2 = groups[i][2]

            // 3. 字段并集 + 强制目标主键 id + 强制 fk 分组键（fk 不在字段子集里也必须选中）
            let cols = buildBatchSelectCols(rels2, ["id", fk])

            // 4. 批量查询：SELECT <cols> FROM <table> WHERE <fk> IN (?, ...)
            let (inSQL, inParams) = buildInClause(dialect, fk, ids.toArray())
            let result2 = execBatchQuery(exec, dialect, targetTable, cols, inSQL, inParams)

            // 5. 按 fk 值分组成目标实体列表（fk 类型跟随主实体主键：Int64 或 String）。
            //    可空 fk 的脏行（驱动返回 NULL）用 getOrNull 判空跳过，不抛异常（旧 isNullId 防御）。
            let columnMap = buildColumnMap(result2.columnInfos, exec.getParamOffset())
            let fkIdx = columnMap.get(fk).getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels2[0].getTargetMapper()
            var groupMap = HashMap<String, ArrayList<Any>>()
            while (result2.next()) {
                let keyOpt: Option<String> = if (isStringPk) {
                    match (result2.getOrNull<String>(fkIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                } else {
                    match (result2.getOrNull<Int64>(fkIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                }
                match (keyOpt) {
                    case Some(key) =>
                        var group = match (groupMap.get(key)) {
                            case Some(g) => g
                            case None =>
                                let ng = ArrayList<Any>()
                                groupMap[key] = ng
                                ng
                        }
                        group.add(targetMapper(result2, columnMap))
                    case None => ()
                }
            }

            // 6. 回填：has_many 逐目标 add；has_one 取组内第一条（重复 fk 时取先读到的行）。
            //    同时收集该关系装配到的目标实体（has_many 取组内全部、has_one 取 ts[0]）。
            //    收集按 target id（getTargetIdExtractor → fkKey）去重：多个主实体命中同一
            //    目标分组时（如 ref_to 共享目标、或 ref_many 两个父实体共享同一 tag 的副本
            //    实例），组内目标实例是同一个对象，重复收集会让递归层对该实例的嵌套
            //    has_many 跑两次、setter .add() 把子项追加成两份。去重只影响递归层装配的
            //    目标列表，单层 setter 仍按主实体逐次执行（同 assembleRefTo 的 targetSeen）。
            for (rel in rels2) {
                let (kind, _, _, _, _, _) = rel.resolve()
                let setter = rel.getFieldSetter()
                let idExtractor = rel.getTargetIdExtractor()
                var targets = ArrayList<Any>()
                var targetSeen = HashMap<String, Bool>()
                for (ei in 0..entities.size) {
                    let rawId = rawIds[ei]
                    if (isEmptyFk(rawId)) { continue }
                    let key = fkKey(rawId)
                    match (groupMap.get(key)) {
                        case Some(ts) =>
                            if (kind == RelationKind.HasManyRel) {
                                for (t in ts) {
                                    setter(entities[ei], t)
                                    let tKey = fkKey(idExtractor(t))
                                    if (!targetSeen.contains(tKey)) {
                                        targetSeen[tKey] = true
                                        targets.add(t)
                                    }
                                }
                            } else {
                                setter(entities[ei], ts[0])
                                let tKey = fkKey(idExtractor(ts[0]))
                                if (!targetSeen.contains(tKey)) {
                                    targetSeen[tKey] = true
                                    targets.add(ts[0])
                                }
                            }
                        case None => ()
                    }
                }
                result.add((rel, targets.toArray(), columnMap))
            }
        }
        result
    }

    // Task 5: ref_many 批量装配（多对多，经 junction 中间表）。主查询返回实体后调用：
    //   1. 按 (via 中间表, 目标表) 分组，同组多个 ref_many 关系合并为一条批量查询；
    //   2. 复用主实体主键原始值（rawIds，与 entities 按索引对齐），去重并过滤 0/""；
    //   3. 空集合跳过（不产生额外查询）；
    //   4. `SELECT 目标表."id", 目标表.<字段...>, 中间表."<源表>_id" FROM 中间表 JOIN 目标表
    //      ON 中间表."<目标类>_id" = 目标表."id" WHERE 中间表."<源表>_id" IN (?, ...)` 批量取
    //      关联目标，目标列不带表限定（targetMapper 按列名读，中间表 schema 只有两列无同名列可裸读），
    //      中间表源 id 列强制选中（分组键）。反向同名情形：若目标实体恰好有名为
    //      `<源表>_id` 的字段，SELECT 中该目标列先于中间表源 id 列出现，buildColumnMap 对同名
    //      键「后写覆盖」（std HashMap.add 语义），分组键 srcCol 取到最后写入的中间表列索引、
    //      仍正确，但该假设的目标字段会错读到中间表源 id 值（target 表出现 `<源表>_id` 字段极罕见）；
    //   5. 按中间表源 id 值分组建 HashMap<srcId, Array<TargetEntity>>；跨源组按目标主键 id
    //      缓存实例（多个主实体共享同一目标时，所有父实体的关联列表持有同一个目标对象，
    //      语义同 assembleRefTo 的 targetMap 缓存，见本方法第 5 步注释）；
    //   6. 回填：主实体按各自主键命中分组，逐个 add。孤儿行（中间表行指向已删目标）
    //      由 INNER JOIN 天然排除，不装配、不抛错。
    // Task 6 扩展：返回各关系实际装配到的目标实体数组（逐目标 add 时收集、按 target id
    // 去重），供嵌套 include 递归装配下一层关联——共享目标只装配一次，避免递归层把
    // 嵌套 has_many 的 setter .add() 对同一目标重复追加（assembleCollections 同样去重）。
    // R-I2：三元组第三位 = 产生 targets 的批量查询 columnMap（供嵌套 ref_to fk 列守卫）。
    // 中间表列名与 buildJunctionSchema / relation_gen.cj 一致：
    //   源列 = <源表名>_id（sourceTable 由 assembleRecursive 传入：顶层为主查询 FROM 表，
    //     嵌套层为当前层级实体所在表 = 父关系 targetTable，见 assembleRecursive 注释），
    //   目标列 = lowerTableName(目标类) + "_id"（由宏层随 RefMany 构造传入，
    //           @Table 覆盖目标表名时目标列名仍基于类名，见 getJunctionTargetCol）。
    // SQL 手写（quoteIdentifier + 占位符，对齐 relation_gen.cj 的 ref_many 单行查询风格）：
    // junction JOIN 语义必须是 INNER JOIN（孤儿行跳过），而 Statement/方言渲染只支持
    // LEFT JOIN 且 FromClause 无别名，无法表达该 JOIN；IN 列带表限定也超出 buildInClause。
    private func assembleRefMany<E>(
        exec: ExecutionContext,
        dialect: Dialect,
        entities: Array<E>,
        rawIds: Array<Any>,
        rels: Array<IRelation>,
        sourceTable: String
    ): ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)> {
        let result = ArrayList<(IRelation, Array<Any>, HashMap<String, Int64>)>()
        if (rels.size == 0 || entities.size == 0) { return result }
        if (rawIds.size != entities.size) {
            throw QueryException("internal error: rawId collection size mismatch in assembleRefMany")
        }
        // 手写 Query 未设 FROM 却 include 了 ref_many 是用户错误：junction 源列
        // `<源表>_id` 无从推导，静默跳过会留下未装配的空关联列表，故 fail-fast
        // （风格同 requireCollectionIdSupport）。
        if (sourceTable == "") {
            throw QueryException(
                "ref_many include requires a source table. Call from() before executing the query."
            )
        }

        // 1. 按 (via 中间表, 目标表) 分组。分组键不含关系名/源表：若两个不同类 @Table
        //    映射到同一表且声明同一 via（极罕见），会误合并为一条批量查询——视为已知限制。
        var groups = ArrayList<(String, String, ArrayList<IRelation>)>()
        for (inc in rels) {
            let (kind, _, targetTable, _, via, _) = inc.resolve()
            if (kind != RelationKind.RefManyRel) { continue }
            let viaTable = via.getOrThrow()
            var found = false
            for (i in 0..groups.size) {
                if (groups[i][0] == viaTable && groups[i][1] == targetTable) {
                    groups[i][2].add(inc)
                    found = true
                    break
                }
            }
            if (!found) {
                let rels2 = ArrayList<IRelation>()
                rels2.add(inc)
                groups.add((viaTable, targetTable, rels2))
            }
        }
        if (groups.size == 0) { return result }

        // 2. 收集主实体 id（去重、过滤 0/"" 未设置值），同 assembleCollections
        var ids = ArrayList<Any>()
        var seen = HashMap<String, Bool>()
        for (id in rawIds) {
            if (isEmptyFk(id)) { continue }
            let key = fkKey(id)
            if (!seen.contains(key)) {
                seen[key] = true
                ids.add(id)
            }
        }
        if (ids.size == 0) { return result }

        let srcCol = sourceTable + "_id"

        for (i in 0..groups.size) {
            let viaTable = groups[i][0]
            let targetTable = groups[i][1]
            let rels2 = groups[i][2]

            // 3. 目标字段并集 + 强制目标主键 id；另强制中间表源 id 列（分组键）
            let cols = buildBatchSelectCols(rels2, ["id"])
            let tgtCol = rels2[0].getJunctionTargetCol()
            if (tgtCol == "") {
                throw QueryException("ref_many relation '" + rels2[0].resolve()[1] +
                    "' has empty junction target column; RefMany requires junctionTargetCol")
            }

            // 4. 手写 junction 批量查询（INNER JOIN 语义见方法注释）
            var selectParts = ArrayList<String>()
            for (c in cols) {
                match (c) {
                    case Expr.Column(name) =>
                        selectParts.add(dialect.quoteIdentifier(targetTable) + "." + dialect.quoteIdentifier(name))
                    case _ => throw QueryException("internal error: batch select contains non-column expr")
                }
            }
            selectParts.add(dialect.quoteIdentifier(viaTable) + "." + dialect.quoteIdentifier(srcCol))
            let srcColSQL = dialect.quoteIdentifier(viaTable) + "." + dialect.quoteIdentifier(srcCol)
            let (inSQL, inParams) = buildInClauseCol(srcColSQL, ids.toArray())
            let sql = "SELECT " + String.join(selectParts.toArray(), delimiter: ", ") +
                " FROM " + dialect.quoteIdentifier(viaTable) +
                " JOIN " + dialect.quoteIdentifier(targetTable) +
                " ON " + dialect.quoteIdentifier(viaTable) + "." + dialect.quoteIdentifier(tgtCol) +
                " = " + dialect.quoteIdentifier(targetTable) + "." + dialect.quoteIdentifier("id") +
                " WHERE " + inSQL
            Logger.logSQL(sql, inParams)
            let result2 = exec.query(sql, inParams)

            // 5. 按中间表源 id 值分组成目标实体列表（源 id 类型跟随主实体主键：Int64 或 String）。
            //    INNER JOIN 已排除孤儿行；中间表源 id 列非空，getOrNull 仅防御。
            //    跨源组按目标主键 id 缓存目标实例（targetInstanceCache）：多个主实体共享
            //    同一目标（两个 Post 都打同一 tag）时，各 junction 行映射的是同一目标的
            //    副本，若各自持有独立实例，嵌套递归对每个副本各跑一次，且下一层共享的
            //    嵌套目标会被 setter .add() 重复追加。缓存让共享目标在所有父实体的关联
            //    列表里是同一个对象（语义同 assembleRefTo 的 targetMap 缓存），配合第 6 步
            //    按 target id 去重后，递归层对每个目标 id 只装配一次即可让所有持有它的
            //    父实体都看到嵌套结果。缓存 key 用查询结果强制选中的目标主键列 "id"
            //    （值即目标 id），不依赖 getTargetIdExtractor：手工构造的 relation 若用
            //    dummy extractor（恒返回固定值）也不至于把不同目标误判为同一目标。
            //    目标主键可能是 Int64 或 String，统一取字符串 key：getOrNull<String> 在
            //    真实驱动（pgsql/mariadb）上对数值列也返回文本形式（Some），严格 mock
            //    返回 None 时回退 getOrNull<Int64>。同目标多行值一致，取先读到的实例。
            let columnMap = buildColumnMap(result2.columnInfos, exec.getParamOffset())
            let srcIdx = columnMap.get(srcCol).getOrThrow()
            let idIdx = columnMap.get("id").getOrThrow()
            let isStringPk = fkIsString(ids[0])
            let targetMapper = rels2[0].getTargetMapper()
            var groupMap = HashMap<String, ArrayList<Any>>()
            var targetInstanceCache = HashMap<String, Any>()
            // R-M9: 组内按目标 id 去重——重复 junction 行（同一 (源id, 目标id) 出现多行，
            // 只能由 DB 数据损坏或手工 INSERT 触发；正常 save 的 append 每次只写一行）会把
            // 同一目标实例 add 进组两次，单层 setter 对同一父实体 .add() 两次、目标列表出现
            // 同实例两份。用 targetInstanceCache 已保证同目标映射到同一实例，此处仅阻止该
            // 实例被重复 add 进同一源分组（跨源组共享实例的语义不变）。
            var groupTargetSeen = HashMap<String, HashSet<String>>()
            while (result2.next()) {
                let keyOpt: Option<String> = if (isStringPk) {
                    match (result2.getOrNull<String>(srcIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                } else {
                    match (result2.getOrNull<Int64>(srcIdx)) {
                        case Some(v) => Some(fkKey(v))
                        case None => None
                    }
                }
                match (keyOpt) {
                    case Some(key) =>
                        let tKey = match (result2.getOrNull<String>(idIdx)) {
                            case Some(v) => v
                            case None => result2.getOrNull<Int64>(idIdx).getOrThrow().toString()
                        }
                        var group = match (groupMap.get(key)) {
                            case Some(g) => g
                            case None =>
                                let ng = ArrayList<Any>()
                                groupMap[key] = ng
                                ng
                        }
                        var seenIds = match (groupTargetSeen.get(key)) {
                            case Some(s) => s
                            case None =>
                                let ns = HashSet<String>()
                                groupTargetSeen[key] = ns
                                ns
                        }
                        if (seenIds.contains(tKey)) { continue }
                        seenIds.add(tKey)
                        match (targetInstanceCache.get(tKey)) {
                            case Some(shared) => group.add(shared)
                            case None =>
                                let mapped = targetMapper(result2, columnMap)
                                targetInstanceCache[tKey] = mapped
                                group.add(mapped)
                        }
                    case None => ()
                }
            }

            // 6. 回填：逐目标 add；同时收集该关系装配到的目标实体。收集按 target id
            //    （getTargetIdExtractor → fkKey）去重：多个主实体共享同一目标时，第 5 步
            //    已让共享目标是同一个实例，targets 若不去重会收集同一实例两次，递归层
            //    （嵌套 include）会对该实例的嵌套 has_many 跑两次、setter .add() 把子项
            //    追加成两份。去重只影响递归层，单层 setter 仍按主实体逐次 add。
            for (rel in rels2) {
                let setter = rel.getFieldSetter()
                let idExtractor = rel.getTargetIdExtractor()
                var targets = ArrayList<Any>()
                var targetSeen = HashMap<String, Bool>()
                for (ei in 0..entities.size) {
                    let rawId = rawIds[ei]
                    if (isEmptyFk(rawId)) { continue }
                    let key = fkKey(rawId)
                    match (groupMap.get(key)) {
                        case Some(ts) =>
                            for (t in ts) {
                                setter(entities[ei], t)
                                let tKey = fkKey(idExtractor(t))
                                if (!targetSeen.contains(tKey)) {
                                    targetSeen[tKey] = true
                                    targets.add(t)
                                }
                            }
                        case None => ()
                    }
                }
                result.add((rel, targets.toArray(), columnMap))
            }
        }
        result
    }
}
