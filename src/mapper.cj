package refine

import std.collection.HashMap
import std.database.sql.{QueryResult as SqlQueryResult, ColumnInfo as SqlColumnInfo}

public func buildColumnMap(columnInfos: Array<SqlColumnInfo>): HashMap<String, Int64> {
    buildColumnMap(columnInfos, 0)
}

public func buildColumnMap(columnInfos: Array<SqlColumnInfo>, offset: Int64): HashMap<String, Int64> {
    let map = HashMap<String, Int64>()
    for (i in 0..columnInfos.size) {
        map.add(columnInfos[i].name, i + offset)
    }
    map
}

public func readField<T>(result: SqlQueryResult, index: Int64): T {
    result.get<T>(index)
}
