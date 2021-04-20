from datatypes/basic import PDatum, POid

import tables

{. push header: "executor/spi.h".}

type
#   const_char* {.importc: "const char*".} = cstring

   Column = Table[string,string]
   Row = seq[Column]
   ResultSet = seq[Row]

   HeapTuple  {. importc: "HeapTuple" .} = ref object
   TupleDesc  {. importc: "TupleDesc" .} = ref object
       natts*: int

   TupleTable*  {.importc: "SPITupleTable" .} = object
       vals*: ref HeapTuple
       tupdesc*: TupleDesc

   OK* {. pure .} = enum
       CONNECT = 1,
       FINISH, FETCH, UTILITY,
       SELECT, SELINTO, INSERT,
       DELETE, UPDATE, CURSOR
       INSERT_RETURNING, DELETE_RETURNING, UPDATE_RETURNING,
       REWRITTEN, REL_REGISTER, REL_UNREGISTER, TD_REGISTER

   ERROR* {. pure .} = enum
       CONNECT = 1,
       COPY, OPUNKNOWN, UNCONNECTED, 
       #CURSOR not used anymore
       ARGUMENT = 6,
       PARAM, TRANSACTION, NOATTRIBUTE, NOOUTFUNC,
       TYPEUNKNOWN, REL_DUPLICATE, REL_NOT_FOUND

proc connect(): int {. importc: "SPI_connect".}
proc finish():  int {. importc: "SPI_finish".}

proc exec*(c: const_char, count: clong): int {. importc: "SPI_exec".}
proc execute*(c: const_char, read_only: cchar, count: clong): int {. importc: "SPI_execute".}
proc execute_with_args*(c: const_char, nargs: cint, argtypes: POid,
                        values: PDatum, Nulls: const_char,
                        read_only: cchar, count: clong): int {. importc: "SPI_execute_with_args".}

#Return column name
proc fname*(tupdesc: TupleDesc, fnumber: int): const_char {.importc: "SPI_fname" .}
#Return column type
proc gettype*(tupdesc: TupleDesc, fnumber: int): const_char {.importc: "SPI_gettype" .}
#Return column value
proc getvalue*(tupl: HeapTuple, tupdesc: TupleDesc, fnumber: int): const_char {.importc: "SPI_getvalue" .}


template spi_init*(statements: untyped) =

    var connection_status  = connect()

    {.emit: """ HeapTuple getHeapIdx(SPITupleTable* tuptable){
                static int j = 0;
                if(j < SPI_processed){
                   return tuptable->vals[j++];
                }else{
                  j = 0;
                }
    }
    """.}

    var SPI_processed {. codegenDecl: "extern $# $#", inject.} : uint64
    var SPI_tuptable  {. codegenDecl:  "extern $# $#", inject .} : ref TupleTable
    proc gettuple(tuptable: ref TupleTable):HeapTuple {.importc: "getHeapIdx".}

    statements
    
    var finish_status = finish()

template get_info_schema*(table_name: string) =
       var info_schema {. inject .} = initTable[cstring,string]()
       var last_column:cstring
       echo "getting information schema... ", table_name
       discard 0.getInt32
       var ret  = exec(const_char("select column_name, data_type from information_schema.columns where table_name='"&table_name&"';"),0)
       var tupdesc = SPI_tuptable[].tupdesc
       if SPI_processed > cast[uint64](0):
          for lines in 0 .. SPI_processed:
              var values = gettuple(SPI_tuptable)
              for i in 1..tupdesc.natts:
                  var ttype:cstring = gettype(tupdesc,i)
                  var colname:cstring = fname(tupdesc,i)
                  var value:cstring = getvalue(values,tupdesc,i)
                  if ttype == "sql_identifier" and last_column != value:
                     info_schema[value] = "not defined"
                     last_column = value
                  if ttype == "character_data":
                     info_schema[last_column] = $value
       else:
           info_schema[cstring("error")] = "table_not_found"

template query*(c: const_char, obj: untyped) =
    discard exec(const_char(c),0)

    var obj{. inject .}: ResultSet = @[]

    var row: Row

    var tupdesc = SPI_tuptable[].tupdesc

    for lines in 0 .. SPI_processed:
        row = @[]
        var values = gettuple(SPI_tuptable)
        for i in 1..tupdesc.natts:
        # Catching N+1 problem!
            if lines != (SPI_processed - 1):
                  #var ttype:cstring = gettype(tupdesc,i)
                  var colname:cstring = fname(tupdesc,i)
                  var value:cstring = getvalue(values,tupdesc,i)
                  row.add([($colname, $value)].toTable)
        if row != @[]:
           obj.add(row)    

template getFrom*(property:string, table: ResultSet) =
    for row in table:
        for item in row:
            if item.contains(property):
               echo item

template SelectFrom*(table: ResultSet, props:seq[string]) =
    for row in table:
        for item in row:
            for p in props:
                if item.contains(p):
                   echo p

{. pop .}
