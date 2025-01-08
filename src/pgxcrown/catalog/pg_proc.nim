from ../datatypes/basic import NameData, Oid, oidvector, Pointer

{.push header: "catalog/pg_proc_d.h".}

var
  #This tells the function handler how to invoke the function. It might be the actual source code of the function for interpreted languages, a link symbol, a file name, or just about anything else, depending on the implementation language/call convention
  Anum_pg_proc_prosrc* {.importc.}: cuint

  #Name of the function
  Anum_pg_proc_proname* {.importc.}: cuint

  #Implementation language or call interface of this function
  Anum_pg_proc_prolang* {.importc.}: cuint

  #f for a normal function, p for a procedure, a for an aggregate function, or w for a window function
  Anum_pg_proc_prokind* {.importc.}: cuint
  
  #Function returns null if any call argument is null. In that case the function won't actually be called at all. Functions that are not “strict” must be prepared to handle null inputs
  Anum_pg_proc_proisstrict* {.importc.}: cuint

  #Number of input arguments
  Anum_pg_proc_pronargs* {.importc.}: cuint

  #Number of arguments that have defaults
  Anum_pg_proc_pronargdefaults* {.importc.}: cuint
  
  #Data type of the return value
  Anum_pg_proc_prorettype* {.importc.}: cuint

  #An array of the data types of the function arguments
  Anum_pg_proc_proargtypes* {.importc.}: cuint

  #An array of the names of the function arguments. Arguments without a name are set to empty strings in the array
  Anum_pg_proc_proargnames* {.importc.}: cuint

{.pop.}

template get_pg_proc_src*(ttuple: typed): cstring =
  var
    datum = SysCacheGetAttr(PROCOID, ttuple, Anum_pg_proc_prosrc, addr(is_null))
    content   = TextDatumGetCString(datum)
  content

template get_pg_proc_name*(ttuple: typed): cstring =
  var
    datum = SysCacheGetAttr(PROCOID, ttuple, Anum_pg_proc_proname, addr(is_null))
    fn_name = DatumGetName(datum)
  NameStr(fn_name[])

template get_pg_proc_kind*(ttuple: typed): char =
  var
    datum = SysCacheGetAttr(PROCOID, ttuple, Anum_pg_proc_prokind, addr(is_null))
    fn_kind = DatumGetChar(datum)
  fn_kind

template get_pg_proc_is_strict*(ttuple: typed): bool =
  var
    datum = SysCacheGetAttr(PROCOID, ttuple, Anum_pg_proc_proisstrict, addr(is_null))
    fn_is_strict = DatumGetBool(datum)
  fn_is_strict


template get_pg_proc_nargs*(ttuple: typed): int16 =
  var
    datum = SysCacheGetAttr(PROCOID, ttuple, Anum_pg_proc_pronargs, addr(is_null))
    fn_nargs = DatumGetInt16(datum)
  fn_nargs

template get_pg_proc_default_nargs*(ttuple: typed): int16 =
  var
    datum = SysCacheGetAttr(PROCOID, ttuple, Anum_pg_proc_pronargdefaults, addr(is_null))
    fn_default_nargs = DatumGetInt16(datum)
  fn_default_nargs

template get_pg_proc_argtypes*(ttuple: typed): ptr Oid =
  var
    datum = SysCacheGetAttr(PROCOID, ttuple, Anum_pg_proc_proargtypes, addr(is_null))
    fn_args_types = cast[ptr oidvector](DatumGetPointer(datum))
  fn_args_types.values

template asIntptr(vector: ptr Oid): int = cast[int](vector)

template asOid*(address: int): Oid =
  (cast[ptr Oid](address))[]

proc `+`*(vector: ptr Oid, offset: int): int {.inline.} = 
  vector.asIntptr + (sizeof(Oid) * offset)


