from datatypes/basic import PDatum, POid

{. push header: "executor/spi.h".}

type 
    const_char* {.importc: "const char*".} = cstring

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

proc fname*(tupdesc: TupleDesc, fnumber: int): const_char {.importc: "SPI_fname" .}
proc gettype*(tupdesc: TupleDesc, fnumber: int): const_char {.importc: "SPI_gettype" .}
proc getvalue*(tupl: HeapTuple, tupdesc: TupleDesc, fnumber: int): const_char {.importc: "SPI_getvalue" .}

template spi_init*(statements: untyped) =

    var connection_status  = connect()

    var SPI_processed {. codegenDecl: "extern $# $#", inject.} : uint64
    var SPI_tuptable  {. codegenDecl:  "extern $# $#", inject .} : ref TupleTable

    {.emit: """ HeapTuple getHeapIdx(SPITupleTable* tuptable){
                static int j = 0;
                if(j < SPI_processed){
                   return tuptable->vals[j++];
                }else{
                  j = 0;
                }
    }
    """ .}

    proc gettuple(tuptable: ref TupleTable):HeapTuple {.importc: "getHeapIdx".}

    statements

    var finish_status = finish()

{. pop .}