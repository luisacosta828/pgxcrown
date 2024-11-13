type
  command {.importc: "const char*", used.} = distinct cstring

  QueryBuilder = object
    columns: seq[string]
    table: seq[string]
    where: seq[string]


proc From(query: var QueryBuilder, table: seq[string]): var QueryBuilder {.inline.} =
  query.table = table
  result = query


proc Select(query: var QueryBuilder, columns: seq[string]): QueryBuilder {.inline.} =
  query.columns = columns
  result = query


var query = QueryBuilder()
var column: seq[string] = @["one"]


echo query.From(@["pg_constraint"]).Select(column)
#proc build(query: QueryBuilder): const_char {. inline .} = const_char(query.table)
