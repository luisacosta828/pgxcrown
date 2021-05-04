include compiler
include datatypes/basic
include spi

template fcinfo_data* =
    {.emit: """
FunctionCallInfo getFcinfoData(){ return fcinfo; }
""".}
    
    proc getFcinfoData():FunctionCallInfo {.importc.}
    

