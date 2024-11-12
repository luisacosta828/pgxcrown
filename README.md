# pgxcrown

Build Postgres Extensions in Nim.

## Usage

### Create a pgxcrown project

```bash

# this command will create your project structure

pgxtool create-project test

```

### Write your code into main.nim
```nim
proc add_one*(a: int): int =
  a + 1

```
### Build a dynamic library
```bash

pgxtool build-extension test

cp *.so $(pg_config --pkglibdir)
```

### Call your library function from Postgresql
```sql
# Enter into psql and create a function to wrap your library function
# omit library extension.

create function function_name(params) return data_type as
'{libname}', '{function}'
language c strict;

#Example
create function nim_add_one(integer) return integer as
'libadd_one', 'pgx_add_one'
language c strict;

select nim_add_one(10); # -> 11

```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)
