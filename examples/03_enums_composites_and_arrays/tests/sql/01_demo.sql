-- Ejemplo 03: Enums {.pure.}, tipos compuestos (object) y arrays (seq[T] / PgVector[T])

-- 1. ENUM {.pure.} mapeado a PostgreSQL ENUM
SELECT enum_range(NULL::ex03_order_state) AS order_states;
SELECT ex03_next_state() AS from_default,
       ex03_next_state('pending'::ex03_order_state) AS after_pending,
       ex03_next_state('confirmed'::ex03_order_state) AS after_confirmed;

-- 2. Tipo compuesto devuelto y recibido por funciones
SELECT (ex03_make_item('  sku-101 ', 3, 450)).* ;
SELECT ex03_item_total_cents(ex03_make_item('sku-202', 4, 1250, 'confirmed'::ex03_order_state)) AS item_total;

-- 3. Arrays de compuestos (seq[ex03_line_item] entrada) y SETOF compuesto (salida)
SELECT ex03_sum_order_cents(ARRAY[
  ROW('SKU-A', 2, 500, 'pending')::ex03_line_item,
  ROW('SKU-B', 5, 300, 'confirmed')::ex03_line_item,
  ROW('SKU-C', 1, 1200, 'shipped')::ex03_line_item
]) AS order_total_cents;

SELECT sku, qty, unit_cents, state
FROM ex03_build_order(ARRAY['  kbd-01', 'mouse-02 '], ARRAY[2, 0], 1990)
ORDER BY sku;

-- 4. Arrays primitivos seq[int32], seq[string] y zero-copy PgVector[int32]
SELECT ex03_sum_i32(ARRAY[10, 20, 30, 40]::int4[]) AS sum_i32,
       ex03_join_tags(ARRAY['nim', 'postgres', 'pgxcrown'], ' / ') AS joined_tags,
       ex03_scale_vector(ARRAY[2, -3, 5, 8]::int4[], 10) AS scaled_vec;
