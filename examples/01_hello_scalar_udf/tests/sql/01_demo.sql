-- Ejemplo 01: UDFs escalares basicas, volatilidad y paralelismo
SELECT ex01_greet('PostgreSQL') AS greeting;
SELECT ex01_add(19, 23) AS sum_42;
SELECT ex01_slugify('  Hola   Pgxcrown   2026  ') AS slug;

-- Funcion STABLE con calculo en punto flotante
SELECT ex01_discount(120.0, 25.0) AS discounted_exact,
       round(ex01_discount(199.90, 15.0)::numeric, 2) AS discounted_rounded;

-- Funcion VOLATILE con estado por sesion (no puede plegarse como constante)
SELECT ex01_next_seq() AS seq_1;
SELECT ex01_next_seq() AS seq_2;
SELECT ex01_next_seq() AS seq_3;

-- Verificacion determinista en el catalogo pg_proc (provolatile / proparallel / proisstrict)
SELECT proname, provolatile, proparallel, proisstrict
FROM pg_proc
WHERE proname IN ('ex01_greet', 'ex01_add', 'ex01_slugify', 'ex01_discount', 'ex01_next_seq')
ORDER BY proname;
