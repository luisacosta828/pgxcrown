#ifndef PGXCROWN_PGX_SPI_H
#define PGXCROWN_PGX_SPI_H

#include "postgres.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif
#include "executor/spi.h"
#include "catalog/pg_type_d.h"
#include "access/tupdesc.h"
#include "access/xact.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"

/* SPITupleTable & TupleDesc metadata accessors (zero palloc) */
static inline TupleDesc pgx_spi_get_tupdesc(SPITupleTable *tuptable) {
    if (tuptable == NULL) return NULL;
    return tuptable->tupdesc;
}

static inline int pgx_spi_get_natts(TupleDesc tupdesc) {
    if (tupdesc == NULL) return 0;
    return tupdesc->natts;
}

static inline HeapTuple pgx_spi_get_tuple(SPITupleTable *tuptable, uint64 idx) {
    if (tuptable == NULL || tuptable->vals == NULL) return NULL;
    return tuptable->vals[idx];
}

static inline const char *pgx_spi_attname(TupleDesc td, int attnum) {
    Form_pg_attribute attr;
    if (td == NULL || attnum < 1 || attnum > td->natts) return NULL;
    attr = TupleDescAttr(td, attnum - 1);
    if (attr == NULL) return NULL;
    return NameStr(attr->attname);
}

static inline Oid pgx_spi_atttypid(TupleDesc td, int attnum) {
    Form_pg_attribute attr;
    if (td == NULL || attnum < 1 || attnum > td->natts) return InvalidOid;
    attr = TupleDescAttr(td, attnum - 1);
    if (attr == NULL) return InvalidOid;
    return attr->atttypid;
}

static inline bool pgx_spi_attisdropped(TupleDesc td, int attnum) {
    Form_pg_attribute attr;
    if (td == NULL || attnum < 1 || attnum > td->natts) return true;
    attr = TupleDescAttr(td, attnum - 1);
    if (attr == NULL) return true;
    return attr->attisdropped;
}

/* Direct binary Datum extraction */
static inline Datum pgx_spi_getbinval(HeapTuple tuple, TupleDesc tupdesc, int attnum, bool *isnull) {
    bool local_null = true;
    if (isnull != NULL) *isnull = true;
    if (tuple == NULL || tupdesc == NULL || attnum < 1 || attnum > tupdesc->natts) {
        return (Datum)0;
    }
    return SPI_getbinval(tuple, tupdesc, attnum, isnull != NULL ? isnull : &local_null);
}

static inline int pgx_spi_non_atomic_opt(void) {
    return SPI_OPT_NONATOMIC;
}

static inline bool pgx_spi_effective_readonly(bool query_read_only) {
    Snapshot snap;
    if (!query_read_only) return false;
    if (!ActiveSnapshotSet()) return false;
    snap = GetActiveSnapshot();
    if (snap == NULL) return false;
    return snap->curcid == GetCurrentCommandId(false);
}

static inline int pgx_spi_get_result(void) {
    return SPI_result;
}

static inline int pgx_spi_execute(const char *src, bool read_only, long tcount) {
    return SPI_execute(src, read_only, tcount);
}

static inline int pgx_spi_execute_with_args(const char *src,
                                            int nargs,
                                            Oid *argtypes,
                                            Datum *values,
                                            const char *nulls,
                                            bool read_only,
                                            long tcount) {
    return SPI_execute_with_args(src, nargs, argtypes, values, nulls, read_only, tcount);
}

static inline int pgx_spi_execute_plan(SPIPlanPtr plan,
                                       Datum *values,
                                       const char *nulls,
                                       bool read_only,
                                       long tcount) {
    return SPI_execute_plan(plan, values, nulls, read_only, tcount);
}

static inline Portal pgx_spi_cursor_open_with_args(const char *name,
                                                   const char *src,
                                                   int nargs,
                                                   Oid *argtypes,
                                                   Datum *values,
                                                   const char *nulls,
                                                   bool read_only,
                                                   int cursorOptions) {
    return SPI_cursor_open_with_args(name, src, nargs, argtypes, values, nulls, read_only, cursorOptions);
}

static inline void pgx_spi_freetuptable_if_set(void) {
    if (SPI_tuptable != NULL) {
        SPI_freetuptable(SPI_tuptable);
        SPI_tuptable = NULL;
    }
}

/* Varlena direct reader (PG 14-18 safe; uses varatt.h on PG 16+) */
static inline void *pgx_spi_detoast_packed(Datum d) {
    if (d == (Datum)0) return NULL;
    return (void *)PG_DETOAST_DATUM_PACKED(d);
}

static inline size_t pgx_spi_varlena_len(const void *p) {
    if (p == NULL) return 0;
    return (size_t)VARSIZE_ANY_EXHDR(p);
}

static inline const char *pgx_spi_varlena_data(const void *p) {
    if (p == NULL) return NULL;
    return (const char *)VARDATA_ANY(p);
}

static inline bool pgx_spi_is_detoasted_copy(Datum orig, const void *detoasted) {
    return detoasted != NULL && PointerGetDatum(detoasted) != orig;
}

/* Built-in PostgreSQL OID helpers (backed by catalog/pg_type_d.h) */
static inline Oid pgx_oid_bool(void) { return BOOLOID; }
static inline Oid pgx_oid_int2(void) { return INT2OID; }
static inline Oid pgx_oid_int4(void) { return INT4OID; }
static inline Oid pgx_oid_int8(void) { return INT8OID; }
static inline Oid pgx_oid_float4(void) { return FLOAT4OID; }
static inline Oid pgx_oid_float8(void) { return FLOAT8OID; }
static inline Oid pgx_oid_text(void) { return TEXTOID; }
static inline Oid pgx_oid_varchar(void) { return VARCHAROID; }
static inline Oid pgx_oid_bpchar(void) { return BPCHAROID; }
static inline Oid pgx_oid_bytea(void) { return BYTEAOID; }
static inline Oid pgx_oid_uuid(void) { return UUIDOID; }
static inline Oid pgx_oid_date(void) { return DATEOID; }
static inline Oid pgx_oid_timestamp(void) { return TIMESTAMPOID; }
static inline Oid pgx_oid_timestamptz(void) { return TIMESTAMPTZOID; }
static inline Oid pgx_oid_interval(void) { return INTERVALOID; }
static inline Oid pgx_oid_numeric(void) { return NUMERICOID; }
static inline Oid pgx_oid_json(void) { return JSONOID; }
static inline Oid pgx_oid_jsonb(void) { return JSONBOID; }
static inline Oid pgx_oid_oid(void) { return OIDOID; }

static inline Oid pgx_oid_int2_array(void) { return INT2ARRAYOID; }
static inline Oid pgx_oid_int4_array(void) { return INT4ARRAYOID; }
static inline Oid pgx_oid_int8_array(void) { return INT8ARRAYOID; }
static inline Oid pgx_oid_float4_array(void) { return FLOAT4ARRAYOID; }
static inline Oid pgx_oid_float8_array(void) { return FLOAT8ARRAYOID; }
static inline Oid pgx_oid_bool_array(void) { return BOOLARRAYOID; }
static inline Oid pgx_oid_text_array(void) { return TEXTARRAYOID; }
static inline Oid pgx_oid_bytea_array(void) { return BYTEAARRAYOID; }
static inline Oid pgx_oid_uuid_array(void) { return UUIDARRAYOID; }
static inline Oid pgx_oid_jsonb_array(void) { return JSONBARRAYOID; }
static inline Oid pgx_oid_numeric_array(void) { return NUMERICARRAYOID; }

static inline bool pgx_spi_is_text_like_oid(Oid typid) {
    return typid == TEXTOID || typid == VARCHAROID || typid == BPCHAROID;
}

#endif /* PGXCROWN_PGX_SPI_H */
