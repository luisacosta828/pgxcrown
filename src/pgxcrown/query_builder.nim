import std/strutils
import std/tables
import std/sequtils

type
  ColumnKind = enum
    single
    custom
    subquery

  JoinKind = enum
    LeftJoin
    RightJoin
    InnerJoin

  SelectBuilder = object
    columns: seq[Column]

  FromBuilder = object
    stmt: SelectBuilder
    table: string
    alias: string
    join_cols: TableRef[string, bool]

  JoinBuilder = object
    table: string
    alias: string
    join_cols: TableRef[string, bool]
     
  SingleColumn = object
    prop: string

  CustomColumn = object
    prop: (string, string)

  Column = object
    case kind: ColumnKind
    of single: single: SingleColumn
    of custom: custom: CustomColumn
    of subquery: 
      subquery: SelectBuilder
      name: string

  Builders = SelectBuilder | FromBuilder | JoinBuilder
  
template single(name: string): Column = 
  Column(kind: single, single: SingleColumn(prop: name)) 

template custom(name: (string, string)): Column = 
  Column(kind: custom, custom: CustomColumn(prop: name)) 

proc subquery*(query: SelectBuilder, name: string = ""): Column =
  assert query.columns.len == 1, "Syntax Error: Subquery cannot return more than one column."
  Column(kind: subquery, subquery: query, name: name) 

proc `$`*(s: SelectBuilder): string =
  result = "SELECT "
  var col_seq:seq[string]
  for col in s.columns:
    col_seq.add case col.kind:
    of single: col.single.prop
    of custom: col.custom.prop[0] & " " & col.custom.prop[1]
    of subquery: 
      "( " & $col.subquery & " ) " & col.name

  result.add col_seq.join(", ")

proc `$`*(f: FromBuilder): string =
  result = $f.stmt & "\nFROM " & f.table & " " & f.alias


converter stringToColumn(col:string):Column =
  if " as " in col:
    var tup = col.split(" as ")
    custom((tup[0].strip, tup[1].strip))
  else:
    single(col.strip)

converter intToColumn(col: int): Column = $col
converter floatToColumn(col: float): Column = $col

converter SelectBuilderToColumn(col: SelectBuilder): Column =
  subquery(col)

proc `as`*(col: SelectBuilder, subquery_name: string): Column =
  subquery(col, subquery_name)

proc Select*(cols: varargs[Column]): SelectBuilder = 
  result = SelectBuilder(columns: cols.toSeq)

proc From*(stmt: SelectBuilder, table: string, alias: string = ""): FromBuilder =
  var col_name: string

  result = FromBuilder(stmt: stmt, table: table, alias: alias, join_cols: newTable[string, bool]())

  if alias.strip.len != 0:
    for c in stmt.columns:
      col_name = case c.kind:
      of single: c.single.prop
      of custom: c.custom.prop[0]
      else: ""

      if "." in col_name:
        # it must be a column defined from a join clause
        if (alias & ".") notin col_name:
          result.join_cols[col_name] = false
        
proc Join*(stmt: FromBuilder | JoinBuilder, kind: JoinKind, table: string, alias: string): JoinBuilder =
  for k,v in stmt.join_cols.mpairs:
    if (alias & ".") in k:
      stmt.join_cols[k] = true
    else:
      stmt.join_cols[k] = false

  echo $stmt.join_cols      
  result = JoinBuilder()

proc on*(stmt: JoinBuilder, predicate: string):string = discard

proc Where*(stmt: FromBuilder | JoinBuilder): string = discard

proc execute*(stmt: Builders) =
  discard

proc my_proc() =
  var 
    result = Select(
      1,
      3.1415,
      "'a'"
    )
    
 #   Select(single("j.r"), single("m.m"), single("jara"))
 #   .From("results", "r")
 #   .Join(InnerJoin, "results", "j")

 # result.execute()
  echo result

my_proc()
