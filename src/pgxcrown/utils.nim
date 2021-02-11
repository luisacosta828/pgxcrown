include compiler
include datatypes/basic
include spi

{.emit: """ 
int spi_processed(){ return SPI_processed;} 
SPITupleTable* spi_tuptable(){ return SPI_tuptable;}
""" 
.}