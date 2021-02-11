include compiler
include datatypes/basic
include spi

{. push header: "executor/spi.h".}

{.emit: """ 
int spi_processed(){ return SPI_processed;} 
SPITupleTable* spi_tuptable(){ return SPI_tuptable;}
""" 
.}

proc lines_processed*(): int {.importc: "spi_processed".}
proc tuptable*(): PTupleTable {.importc: "spi_tuptable".}

{.pop.}