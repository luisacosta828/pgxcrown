import std/[unittest, tables, options, strutils, json]
import ../src/pgxcrown/query_builder
import ../src/pgxcrown/spi

suite "pgxcrown v0.16.0 - Type-Safe SQL Query Builder & SPI Execution Suite":

  setup:
    let u = table("users", "u")
    let o = table("orders", "o")
    let p = table("profiles", "p")

  test "Basic SELECT with Table Proxies & inFix as":
    let q = Select(u.id, u.name as "user_name", 100 as "score")
      .From(u)
      .Where(u.status == "active" and u.age >= 18)
      .OrderBy(u.created_at.desc.nullsLast)
      .Limit(10)
      .Offset(20)

    let sql = $q
    check "SELECT \"u\".\"id\", \"u\".\"name\" AS \"user_name\", 100 AS \"score\"" in sql
    check "FROM \"users\" \"u\"" in sql
    check "WHERE \"u\".\"status\" = 'active' AND \"u\".\"age\" >= 18" in sql
    check "ORDER BY \"u\".\"created_at\" DESC NULLS LAST" in sql
    check "LIMIT 10" in sql
    check "OFFSET 20" in sql

  test "SQL Injection Immunity":
    let evilString = "admin'); DROP TABLE Users;--"
    let q = Select(u.id).From(u).Where(u.name == evilString)
    let sql = $q
    check "WHERE \"u\".\"name\" = 'admin''); DROP TABLE Users;--'" in sql

  test "Joins with ON condition and LATERAL Joins":
    let subLateral = Select(o.id, o.amount)
      .From(o)
      .Where(o.user_id == u.id)
      .OrderBy(o.amount.desc)
      .Limit(1)

    let q = Select(u.id, u.name, "latest_order.amount")
      .From(u)
      .LeftJoin(p).On(p.user_id == u.id)
      .LeftJoinLateral(subLateral, "latest_order").On("true")

    let sql = $q
    check "LEFT JOIN \"profiles\" \"p\" ON \"p\".\"user_id\" = \"u\".\"id\"" in sql
    check "LEFT JOIN LATERAL (SELECT \"o\".\"id\", \"o\".\"amount\"" in sql
    check "ON true" in sql

  test "Common Table Expressions (CTEs) & Window Functions":
    let regSales = Select(o.region, sum(o.amount) as "total_sales")
      .From(o)
      .GroupBy(o.region)

    let q = WithCte("regional_sales", regSales)
      .Select(
        u.name as "user_name",
        rowNumber().over(partitionBy = u.dept, orderBy = u.salary.desc) as "dept_rank"
      )
      .From(u)

    let sql = $q
    check "WITH \"regional_sales\" AS (" in sql
    check "SELECT \"u\".\"name\" AS \"user_name\", ROW_NUMBER() OVER (PARTITION BY \"u\".\"dept\" ORDER BY \"u\".\"salary\" DESC) AS \"dept_rank\"" in sql

  test "PostgreSQL UPSERT (ON CONFLICT DO UPDATE ... RETURNING)":
    let q = InsertInto("counters", "key", "count")
      .Values("'page_views'", "1")
      .OnConflict("key").DoUpdate("count = counters.count + 1")
      .Returning("count")

    let sql = $q
    check "INSERT INTO \"counters\" (\"key\", \"count\")" in sql
    check "VALUES\n  ('page_views', 1)" in sql
    check "ON CONFLICT (\"key\") DO UPDATE SET count = counters.count + 1" in sql
    check "RETURNING \"count\"" in sql

  test "Set Operations (UNION, INTERSECT, EXCEPT)":
    let q1 = Select(u.id, u.name).From(u).Where(u.role == "admin")
    let q2 = Select(u.id, u.name).From(u).Where(u.role == "editor")
    
    let qUnion = q1.Union(q2)
    check "UNION" in $qUnion

    let qIntersect = q1.Intersect(q2)
    check "INTERSECT" in $qIntersect

    let qExcept = q1.Except(q2)
    check "EXCEPT" in $qExcept

  test "Conditional CASE WHEN THEN ELSE END":
    let roleDesc = caseWhen(u.role == "admin").then("Administrator")
      .when(u.role == "editor").then("Content Manager")
      .elseEnd("Regular User")

    let q = Select(u.name, roleDesc as "role_title").From(u)
    let sql = $q
    check "CASE WHEN \"u\".\"role\" = 'admin' THEN 'Administrator' WHEN \"u\".\"role\" = 'editor' THEN 'Content Manager' ELSE 'Regular User' END AS \"role_title\"" in sql

  test "Standalone SELECT & VALUES":
    let qSelect = Select(raw("NOW()") as "server_time", 42 as "answer")
    check $qSelect == "SELECT NOW() AS \"server_time\", 42 AS \"answer\""

    let qValues = Values(
      Row("1", quoteLiteral("Alice")),
      Row("2", quoteLiteral("Bob"))
    ).Limit(5)
    check "VALUES\n  (1, 'Alice'),\n  (2, 'Bob')\nLIMIT 5" == $qValues

  test "Strongly typed row mapping":
    type UserDto = object
      id: int
      name: string
      active: bool
      score: float

    let mockRow1 = {"id": "10", "name": "Charlie", "active": "true", "score": "98.5"}.toTable
    let user: UserDto = mapRowTo[UserDto](mockRow1)

    check user.id == 10
    check user.name == "Charlie"
    check user.active == true
    check user.score == 98.5

  test "Collection reducers and stream helpers":
    type Item = object
      id: int
      category: string

    let items = @[
      Item(id: 1, category: "books"),
      Item(id: 2, category: "electronics"),
      Item(id: 3, category: "books")
    ]

    check items.firstOption().isSome
    check items.firstOption().get.id == 1

    check items.any(proc(x: Item): bool = x.category == "books") == true
    check items.any(proc(x: Item): bool = x.category == "clothing") == false
    check items.all(proc(x: Item): bool = x.id > 0) == true

    let categoryMap = items.toTable(proc(x: Item): int = x.id, proc(x: Item): string = x.category)
    check categoryMap[1] == "books"
    check categoryMap[2] == "electronics"

  test "Object Schema Inspection & createTableFrom with Local Types":
    type Product = object
      id: int
      title: string
      price: float
      in_stock: bool
      tags: seq[string]
      discount_code: Option[string]

    # 1. DDL generation from local type
    let ddl = createTableFrom(Product)
    check "CREATE TABLE IF NOT EXISTS \"product\" (" in ddl
    check "\"id\" INTEGER PRIMARY KEY" in ddl
    check "\"title\" TEXT NOT NULL" in ddl
    check "\"price\" DOUBLE PRECISION NOT NULL" in ddl
    check "\"in_stock\" BOOLEAN NOT NULL" in ddl
    check "\"tags\" TEXT[] NOT NULL" in ddl
    check "\"discount_code\" TEXT" in ddl
    # discount_code is Option[string] so it shouldn't have NOT NULL
    check "\"discount_code\" TEXT NOT NULL" notin ddl

    # 2. DDL generation from local instance with custom table name
    let sampleProd = Product(
      id: 101,
      title: "Mechanical Keyboard",
      price: 149.99,
      in_stock: true,
      tags: @["gaming", "hardware"],
      discount_code: some("SUMMER25")
    )
    let ddlCustom = createTableFrom(sampleProd, tableName = "inventory_items", ifNotExists = false)
    check "CREATE TABLE \"inventory_items\" (" in ddlCustom

    # 3. Inspect properties (columnsOf and columnTypesOf)
    let cols = columnsOf(Product)
    check cols == @["id", "title", "price", "in_stock", "tags", "discount_code"]

    let typeMap = columnTypesOf(sampleProd)
    check typeMap["id"] == "INTEGER PRIMARY KEY"
    check typeMap["title"] == "TEXT NOT NULL"
    check typeMap["price"] == "DOUBLE PRECISION NOT NULL"

    # 4. Table Proxy from local type
    let pTable = tableFrom(Product, alias = "p")
    check $pTable.title == "\"p\".\"title\""

    # 5. Insert statement generated directly from local instance
    let insertQ = insertFrom(sampleProd, tableName = "inventory_items")
    let insertSql = $insertQ
    check "INSERT INTO \"inventory_items\" (\"id\", \"title\", \"price\", \"in_stock\", \"tags\", \"discount_code\")" in insertSql
    check "101, 'Mechanical Keyboard', 149.99, TRUE, ARRAY['gaming', 'hardware'], 'SUMMER25'" in insertSql

  test "JSON & JSONB Query Operators":
    # 1. Field extraction as JSON (-> 'profile') and nested chaining
    let qJson = Select(u.data["profile"]["avatar"] as "avatar_json")
      .From(u)
      .Where(u.data.asText("role") == "admin" and u.settings.hasJsonKey("theme"))
    
    let sqlJson = $qJson
    check "\"u\".\"data\" -> 'profile' -> 'avatar' AS \"avatar_json\"" in sqlJson
    check "\"u\".\"data\" ->> 'role' = 'admin'" in sqlJson
    check "\"u\".\"settings\" ? 'theme'" in sqlJson

    # 2. JSON Array Indexing (-> 0 and ->> 0)
    let qArray = Select(u.tags[0] as "first_tag", u.tags.asText(1) as "second_tag_str").From(u)
    check "\"u\".\"tags\" -> 0 AS \"first_tag\"" in $qArray
    check "\"u\".\"tags\" ->> 1 AS \"second_tag_str\"" in $qArray

    # 3. JSON Path extractions (#> and #>>)
    let qPath = Select(u.data.jsonPath("a", "b", "c") as "nested_obj",
                       u.data.jsonPathText("a", "b", "title") as "nested_title").From(u)
    check "\"u\".\"data\" #> '{a,b,c}' AS \"nested_obj\"" in $qPath
    check "\"u\".\"data\" #>> '{a,b,title}' AS \"nested_title\"" in $qPath

    # 4. JSON Containment (@>, <@) and key checks (?|, ?&)
    let qContains = Select(u.id).From(u).Where(
      u.metadata.containsJson(%*{"active": true}) and
      u.flags.hasAnyJsonKey(["flag_a", "flag_b"]) and
      u.permissions.hasAllJsonKeys(["read", "write"])
    )
    let sqlContains = $qContains
    check "\"u\".\"metadata\" @> '{\"active\":true}'" in sqlContains
    check "\"u\".\"flags\" ?| ARRAY['flag_a', 'flag_b']" in sqlContains
    check "\"u\".\"permissions\" ?& ARRAY['read', 'write']" in sqlContains

  test "JSON Schema Introspection & createTableFrom with JsonNode":
    type Account = object
      id: int
      username: string
      payload: JsonNode
      settings: Option[JsonNode]
      extra_payloads: seq[JsonNode]

    let ddl = createTableFrom(Account)
    check "CREATE TABLE IF NOT EXISTS \"account\" (" in ddl
    check "\"id\" INTEGER PRIMARY KEY" in ddl
    check "\"username\" TEXT NOT NULL" in ddl
    check "\"payload\" JSONB NOT NULL" in ddl
    check "\"settings\" JSONB" in ddl
    check "\"settings\" JSONB NOT NULL" notin ddl
    check "\"extra_payloads\" JSONB[] NOT NULL" in ddl

    let sampleAccount = Account(
      id: 1,
      username: "luis",
      payload: %*{"role": "admin", "score": 99},
      settings: some(%*{"dark_mode": true}),
      extra_payloads: @[%*{"step": 1}]
    )
    let insertQ = insertFrom(sampleAccount)
    let insertSql = $insertQ
    check "INSERT INTO \"account\" (\"id\", \"username\", \"payload\", \"settings\", \"extra_payloads\")" in insertSql
    check "'{\"role\":\"admin\",\"score\":99}'" in insertSql
    check "'{\"dark_mode\":true}'" in insertSql

  test "Strongly typed row mapping with JsonNode and Option[JsonNode]":
    type ConfigDto = object
      id: int
      meta: JsonNode
      extra: Option[JsonNode]

    let mockRow = {
      "id": "77",
      "meta": "{\"env\":\"prod\",\"replicas\":3}",
      "extra": "{\"debug\":false}"
    }.toTable

    let cfg: ConfigDto = mapRowTo[ConfigDto](mockRow)
    check cfg.id == 77
    check cfg.meta["env"].getStr == "prod"
    check cfg.meta["replicas"].getInt == 3
    check cfg.extra.isSome
    check cfg.extra.get["debug"].getBool == false


