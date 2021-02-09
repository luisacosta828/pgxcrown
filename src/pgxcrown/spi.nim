{. push header: "executor/spi.h".}

var SPI_processed* {. codegenDecl: "$# $#" .}: int 

type 
    command* {.importc: "const char*".} = distinct cstring     
    PTupleTable* {.importc: "SPITupleTable" .} = ptr object

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


proc tupletable*(): PTupleTable {. importc: "spinim_tupletable" .}
proc processed_rows*(): int {. importc: "spinim_processed_rows" .}

proc connect(): int {. importc: "SPI_connect".}
proc finish():  int {. importc: "SPI_finish".}
proc exec*(c: command, count: clong): int {. importc: "SPI_exec".}

template spi_init*(statements: untyped) = 
    var connection_status {.inject.} = connect()
    statements
    var finish_status {. inject .} = finish()

{. pop .}