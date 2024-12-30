include compiler
include datatypes/basic
include spi


proc getFnOid*(fcinfo: FunctionCallInfo): Oid {. inline .} = 
  fcinfo[].flinfo[].fn_oid
