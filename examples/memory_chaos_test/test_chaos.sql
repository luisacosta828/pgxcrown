-- =============================================================================
-- 💥 Script de Prueba de Fuego: Chaos Memory & Cancelation Test
-- =============================================================================

-- 1. Crear la extensión
CREATE EXTENSION IF NOT EXISTS memory_chaos_test;

-- 2. Conocer el PID del backend de esta sesión
SELECT pg_backend_pid() AS mi_pid, get_current_pid() AS pid_desde_nim;

-- =============================================================================
-- PRUEBA 1: Cancelación abrupta a mitad de ejecución (pg_cancel_backend)
-- Asigna 150 MB de memoria real en Nim y duerme 15 segundos.
-- Mientras duerme, en la otra terminal cancelaremos la consulta.
-- =============================================================================
SELECT allocate_and_sleep(150, 15);


-- =============================================================================
-- PRUEBA 2: 50 abortos transaccionales consecutivos
-- Cada iteración asigna 20 MB y aborta inmediatamente.
-- Si hubiera fuga: 50 iteraciones * 20 MB = 1 GB de fuga.
-- Con el Custom Allocator: El RSS permanece estable en ~30-40 MB.
-- =============================================================================
DO $$
BEGIN
  FOR i IN 1..50 LOOP
    BEGIN
      PERFORM allocate_and_fail(20);
    EXCEPTION WHEN OTHERS THEN
      -- Capturamos el error para continuar el bucle dentro de la misma conexión
    END;
  END LOOP;
  RAISE NOTICE '¡50 transacciones fallidas completadas!';
END $$;
