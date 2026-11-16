-- =============================================================================
-- Benchmark de Pagos: Tabla Transaccional y Carga Masiva (10,000 filas)
-- Framework: Pgxcrown (Background Worker - Pase a Histórico)
-- =============================================================================

-- 1. Tabla Transaccional Activa
DROP TABLE IF EXISTS payments_history CASCADE;
DROP TABLE IF EXISTS payments CASCADE;

CREATE TABLE payments (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference VARCHAR(64) NOT NULL UNIQUE,
    customer VARCHAR(100) NOT NULL,
    amount NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) NOT NULL DEFAULT 'USD',
    status VARCHAR(20) NOT NULL, -- 'PENDING', 'PROCESSED', 'FAILED', 'REFUNDED'
    payment_method VARCHAR(30) NOT NULL, -- 'CREDIT_CARD', 'BANK_TRANSFER', 'CRYPTO', 'DEBIT_CARD'
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Índices estratégicos para alto rendimiento de consulta y archivado
CREATE INDEX idx_payments_status ON payments (status);
CREATE INDEX idx_payments_created_at ON payments (created_at);

-- 2. Tabla de Histórico (Destino del Background Worker)
CREATE TABLE payments_history (
    id BIGINT PRIMARY KEY,
    reference VARCHAR(64) NOT NULL,
    customer VARCHAR(100) NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    currency VARCHAR(3) NOT NULL,
    status VARCHAR(20) NOT NULL,
    payment_method VARCHAR(30) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_payments_history_status ON payments_history (status);
CREATE INDEX idx_payments_history_archived_at ON payments_history (archived_at);

-- 3. Inserción Masiva de Volumen: 10,000 registros sintéticos realistas
INSERT INTO payments (reference, customer, amount, currency, status, payment_method, created_at)
SELECT
    'PAY-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || LPAD(s.id::text, 6, '0') AS reference,
    (ARRAY[
        'Acme Corp', 'Globex International', 'Soylent Inc', 'Initech LLC',
        'Umbrella Latin', 'Hooli Americas', 'Stark Industries', 'Wayne Enterprises',
        'Cyberdyne Systems', 'Massive Dynamic', 'Pied Piper', 'Dunder Mifflin'
    ])[1 + ((s.id * 7) % 12)] AS customer,
    ROUND((10.0 + (RANDOM() * 4990.0))::numeric, 2) AS amount,
    (ARRAY['USD', 'EUR', 'COP', 'MXN'])[1 + ((s.id * 3) % 4)] AS currency,
    -- Distribución realista: ~60% PROCESSED (candidatos a histórico), ~25% PENDING, ~10% FAILED, ~5% REFUNDED
    CASE 
        WHEN (s.id % 100) < 60 THEN 'PROCESSED'
        WHEN (s.id % 100) < 85 THEN 'PENDING'
        WHEN (s.id % 100) < 95 THEN 'FAILED'
        ELSE 'REFUNDED'
    END AS status,
    (ARRAY['CREDIT_CARD', 'BANK_TRANSFER', 'CRYPTO', 'DEBIT_CARD'])[1 + ((s.id * 5) % 4)] AS payment_method,
    clock_timestamp() - ((10000 - s.id) || ' seconds')::interval AS created_at
FROM generate_series(1, 10000) AS s(id);

-- 4. Métricas de Validación Inmediata
SELECT count(*) AS total_transaccionales FROM payments;
SELECT status, count(*) AS total, ROUND(count(*) * 100.0 / 10000, 1) AS porcentaje 
FROM payments 
GROUP BY status 
ORDER BY total DESC;
