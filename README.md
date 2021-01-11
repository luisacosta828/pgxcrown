# pgxcrown

Build Postgres Extensions in Nim.

## Usage

```nim
import pgxcrown

PG_MODULE_MAGIC

proc pg_add_one(): Datum {.pgv1.} = returnInt32( getInt32(0) + 1)

PG_FUNCTION_INFO_V1(pg_add_one)
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)
