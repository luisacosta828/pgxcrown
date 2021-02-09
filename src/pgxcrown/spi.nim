{. push header: "executor/spi.h".}

proc connect(): int {. importc: "SPI_connect", discardable .}
proc finish():  int {. importc: "SPI_finish", discardable .}

template spi_init*(statements: untyped) = 
    connect()
    statements
    finish()

{. pop .}