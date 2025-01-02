from ../datatypes/basic import NameData, Oid, oidvector

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

