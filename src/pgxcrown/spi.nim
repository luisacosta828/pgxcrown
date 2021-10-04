from datatypes/basic import PDatum, POid

import tables

{. push header: "executor/spi.h".}

type
   const_string* {.importc: "const char*".} = cstring

   Column = Table[string,string]
   Row = seq[Column]
   ResultSet = seq[Row]

   HeapTupleHeader {.importc: "HeapTupleHeader", incompleteStruct.} = ptr object
       t_hoff*: cuint
   HeapTuple*  {. importc: "HeapTuple", incompleteStruct .} = ptr object
       t_data*: HeapTupleHeader
   TupleDesc*  {. importc: "TupleDesc" .} = ref object
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

proc IsValid*(t: HeapTuple): bool {.importc: "HeapTupleIsValid".}

proc connect(): int {. importc: "SPI_connect".}
proc finish():  int {. importc: "SPI_finish".}

proc exec*(c: const_string, count: clong): int {. importc: "SPI_exec".}
proc execute*(c: const_string, read_only: cchar, count: clong): int {. importc: "SPI_execute".}
proc execute_with_args*(c: const_string, nargs: cint, argtypes: POid,
                        values: PDatum, Nulls: const_string,
                        read_only: cchar, count: clong): int {. importc: "SPI_execute_with_args".}

#Return column name
proc fname*(tupdesc: TupleDesc, fnumber: int): const_string {.importc: "SPI_fname" .}
#Return column type
proc gettype*(tupdesc: TupleDesc, fnumber: int): const_string {.importc: "SPI_gettype" .}
#Return column value
proc getvalue*(tupl: HeapTuple, tupdesc: TupleDesc, fnumber: int): const_string {.importc: "SPI_getvalue" .}


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
       var ret  = exec(const_string("select column_name, data_type from information_schema.columns where table_name='"&table_name&"';"),0)
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

template query*(c: const_string, obj: untyped) =
    discard exec(const_string(c),0)

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

template getPLSourceCode*(fn_oid, lang_datum: cuint): tuple[name: string,src: string,nargs: string,argtypes: string, rettype: string] = 
    spi_init:
        var q = "select proname,prosrc,pronargs, proargtypes, prorettype from pg_proc where prolang = "& $lang_datum & " and oid = "& $fn_oid 
        query(q, Code)
    (Code[0][0]["proname"], Code[0][1]["prosrc"], Code[0][2]["pronargs"], Code[0][3]["proargtypes"], Code[0][4]["prorettype"])


template getFunctionHeader*(fn_oid, lang_datum: cuint): tuple[func_name: string, category: string, p1: string, nargs:string ] =
    spi_init:
        var nargs_inner = " (select pronargs from pg_proc where prolang = " & $lang_datum & " and oid = " & $fn_oid & ") as nargs"
        var proname_inner = " (select proname from pg_proc where prolang = " & $lang_datum & " and oid = " & $fn_oid & ")"

        var q = "select func_name, category, p1, " & nargs_inner & " from nim_proc_header where func_name = " & proname_inner
        query(q,Code)

    (Code[0][0]["func_name"], Code[0][1]["category"], Code[0][2]["p1"], Code[0][3]["nargs"])

{. pop .}

