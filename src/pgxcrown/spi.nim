from datatypes/basic import PDatum, POid

{. push header: "executor/spi.h".}

type 
    const_char* {.importc: "const char*".} = distinct cstring     
    pconst_char* = ptr const_char

    TupleTable*  {.importc: "SPITupleTable" .} = object
        free*: uint64
        alloced*: uint64

    PTupleTable* = ref TupleTable
    
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
                        values: PDatum, Nulls: pconst_char,
                        read_only: cchar, count: clong): int {. importc: "SPI_execute_with_args".}


template spi_init*(statements: untyped) = 
    var connection_status {.inject.} = connect()
    {.emit: """ /*TYPESECTION*/
    extern uint64 SPI_processed;
    extern SPITupleTable*  SPI_tuptable;
""" .}    
    {.emit: """ 
    int spi_processed(){ return SPI_processed;} 
    SPITupleTable* spi_tuptable(){ return SPI_tuptable;}
    """ .}
    proc lines_processed(): int {.importc: "spi_processed".}
    proc tuptable(): PTupleTable {.importc: "spi_tuptable".}

    statements

    var finish_status {. inject .} = finish()

{. pop .}