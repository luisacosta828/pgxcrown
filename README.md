# Pgxcrown

Build Postgres Extensions in Nim.


# Requisites

- Postgres with CLI tools installed and running locally
- Nim


## Usage


### Install

```bash
nimble install
```


### Create a pgxcrown project

- This command will create your project structure:

```bash
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
```

Linux:

```bash
cp *.so $(pg_config --pkglibdir)
```

Windows:

- Windows may not add all CLI tools to PATH by default(?)
- Locate `pg_config.exe` in the folders `"C:\Program Files\PostgreSQL\"`.
- Run it in a terminal like so `pg_config.exe --pkglibdir` to get the pkglibdir path.
- See `pgconfigFinder()` function source code as hint.
- Check if you have development header files ("postgres.h", "spi.h", "analyze.h", "elog.h").


### Call your library function from Postgresql

```sql
-- Enter into psql and create a function to wrap your library function
-- omit library extension.

create function function_name(params) return data_type as
'{libname}', '{function}'
language c strict;

-- Example
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
