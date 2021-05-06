type Form_pg_proc* {.importc, header: "catalog/pg_proc.h".} = object

template fcinfo_data* =
    {.emit: """FunctionCallInfo getFcinfoData(){ return fcinfo; }""".}

    proc getFcinfoData():FunctionCallInfo {.importc.}

    var fn_oid {. inject .} = getFcinfoData()[].flinfo[].fn_oid 
    
    var ht = SearchSysCache(ord(SysCacheIdentifier.PROCOID),ObjectIdGetDatum(fn_oid),0,0,0)

    var is_null = false
   
    var lang_datum {. inject .} = SysCacheGetAttr(ord(SysCacheIdentifier.PROCOID), ht, AttrNumber(4), addr(is_null))
    var prosrc_datum = SysCacheGetAttr(ord(SysCacheIdentifier.PROCOID), ht, AttrNumber(25), addr(is_null))
    var argnames_datum = SysCacheGetAttr(ord(SysCacheIdentifier.PROCOID), ht, AttrNumber(22), addr(is_null))

