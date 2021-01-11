# pgxcrown

Build Postgres Extensions in Nim.

## Usage

### 1- Write your module
```nim
import pgxcrown

PG_MODULE_MAGIC

proc pg_add_one(): Datum {.pgv1.} = returnInt32( getInt32(0) + 1)

PG_FUNCTION_INFO_V1(pg_add_one)
```
### 2- Build a dynamic library
```bash
nim c --d:release --app:lib pg_add_one.nim

#Linux
#Copy your dynlib to postgres library directory
cp *.so $(pg_config --pgklibdir)
```

### 3- Call your library function from Postgresql
```sql
# Enter into psql and create a function to wrap your library function
# omit library extension.

create function function_name(params) return data_type as
'{libname}', '{function}'
language c strict;

#Example
create function nim_add_one(integer) return integer as
'libadd_one', 'pg_add_one'
language c strict;

select nim_add_one(10); # -> 11

```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)
