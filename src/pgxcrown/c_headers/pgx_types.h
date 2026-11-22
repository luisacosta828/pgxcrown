#ifndef PGXCROWN_PGX_TYPES_H
#define PGXCROWN_PGX_TYPES_H

#include "postgres.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif
#include "fmgr.h"
#include "access/genam.h"
#include "access/htup_details.h"
#include "access/skey.h"
#include "access/stratnum.h"
#include "access/table.h"
#include "catalog/namespace.h"
#include "catalog/pg_type.h"
#include "storage/lockdefs.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/fmgroids.h"
#include "utils/fmgrprotos.h"
#include "utils/lsyscache.h"
#include "utils/numeric.h"
#include "utils/syscache.h"
#include "utils/timestamp.h"
#include "utils/uuid.h"

#if defined(__GNUC__) || defined(__clang__)
__attribute__((weak)) Oid pgx_active_fn_nsp = InvalidOid;
#else
extern Oid pgx_active_fn_nsp;
#endif

/* Bytea zero-copy and allocation helpers (NUL-byte safe) */
static inline void *pgx_detoast_bytea(Datum d) {
    if (d == (Datum)0) return NULL;
    return (void *)PG_DETOAST_DATUM_PACKED(d);
}

static inline size_t pgx_bytea_len(const void *p) {
    if (p == NULL) return 0;
    return (size_t)VARSIZE_ANY_EXHDR(p);
}

static inline const uint8 *pgx_bytea_data(const void *p) {
    if (p == NULL) return NULL;
    return (const uint8 *)VARDATA_ANY(p);
}

static inline Datum pgx_alloc_bytea(const void *src, size_t len) {
    bytea *res = (bytea *)palloc(VARHDRSZ + len);
    SET_VARSIZE(res, VARHDRSZ + len);
    if (len > 0 && src != NULL) {
        memcpy(VARDATA(res), src, len);
    }
    return PointerGetDatum(res);
}

/* UUID 16-byte helpers */
static inline bool pgx_datum_to_uuid_bytes(Datum d, uint8 *out16) {
    const pg_uuid_t *u;
    if (d == (Datum)0 || out16 == NULL) return false;
    u = DatumGetUUIDP(d);
    if (u == NULL) return false;
    memcpy(out16, u->data, UUID_LEN);
    return true;
}

static inline Datum pgx_uuid_bytes_to_datum(const uint8 *in16) {
    pg_uuid_t *u = (pg_uuid_t *)palloc(sizeof(pg_uuid_t));
    if (in16 != NULL) {
        memcpy(u->data, in16, UUID_LEN);
    } else {
        memset(u->data, 0, UUID_LEN);
    }
    return UUIDPGetDatum(u);
}

/* Temporal helpers */
static inline int32 pgx_datum_to_date(Datum d) {
    return (int32)DatumGetDateADT(d);
}

static inline Datum pgx_date_to_datum(int32 v) {
    return DateADTGetDatum((DateADT)v);
}

static inline int64 pgx_datum_to_timestamp(Datum d) {
    return (int64)DatumGetTimestamp(d);
}

static inline Datum pgx_timestamp_to_datum(int64 v) {
    return TimestampGetDatum((Timestamp)v);
}

static inline int64 pgx_datum_to_timestamptz(Datum d) {
    return (int64)DatumGetTimestampTz(d);
}

static inline Datum pgx_timestamptz_to_datum(int64 v) {
    return TimestampTzGetDatum((TimestampTz)v);
}

static inline bool pgx_datum_to_interval(Datum d, int64 *usec, int32 *day, int32 *month) {
    const Interval *iv;
    if (d == (Datum)0 || usec == NULL || day == NULL || month == NULL) return false;
    iv = DatumGetIntervalP(d);
    if (iv == NULL) return false;
    *usec = (int64)iv->time;
    *day = iv->day;
    *month = iv->month;
    return true;
}

static inline Datum pgx_interval_to_datum(int64 usec, int32 day, int32 month) {
    Interval *iv = (Interval *)palloc(sizeof(Interval));
    iv->time = (TimeOffset)usec;
    iv->day = day;
    iv->month = month;
    return IntervalPGetDatum(iv);
}

/* Arbitrary-precision Numeric helpers */
static inline void *pgx_datum_get_numeric(Datum d) {
    if (d == (Datum)0) return NULL;
    return (void *)DatumGetNumeric(d);
}

static inline Datum pgx_numeric_get_datum(void *n) {
    return NumericGetDatum((Numeric)n);
}

static inline void *pgx_numeric_copy(void *n) {
    if (n == NULL) return NULL;
    return (void *)DatumGetNumericCopy(NumericGetDatum((Numeric)n));
}

static inline void *pgx_numeric_in(const char *s) {
    return (void *)DatumGetNumeric(
        DirectFunctionCall3(numeric_in,
                            CStringGetDatum(s),
                            ObjectIdGetDatum(InvalidOid),
                            Int32GetDatum(-1)));
}

static inline char *pgx_numeric_out(void *n) {
    if (n == NULL) return NULL;
    return DatumGetCString(DirectFunctionCall1(numeric_out, NumericGetDatum((Numeric)n)));
}

static inline void *pgx_int64_to_numeric(int64 v) {
    return (void *)int64_to_numeric(v);
}

static inline void *pgx_float8_to_numeric(double v) {
    return (void *)DatumGetNumeric(DirectFunctionCall1(float8_numeric, Float8GetDatum(v)));
}

static inline int64 pgx_numeric_to_int64(void *n) {
    return DatumGetInt64(DirectFunctionCall1(numeric_int8, NumericGetDatum((Numeric)n)));
}

static inline double pgx_numeric_to_float8(void *n) {
    return DatumGetFloat8(DirectFunctionCall1(numeric_float8, NumericGetDatum((Numeric)n)));
}

static inline bool pgx_numeric_is_nan(void *n) {
    return n != NULL && numeric_is_nan((Numeric)n);
}

static inline bool pgx_numeric_is_inf(void *n) {
    return n != NULL && numeric_is_inf((Numeric)n);
}

static inline void *pgx_numeric_add(void *a, void *b, bool *err) {
    return (void *)numeric_add_opt_error((Numeric)a, (Numeric)b, err);
}

static inline void *pgx_numeric_sub(void *a, void *b, bool *err) {
    return (void *)numeric_sub_opt_error((Numeric)a, (Numeric)b, err);
}

static inline void *pgx_numeric_mul(void *a, void *b, bool *err) {
    return (void *)numeric_mul_opt_error((Numeric)a, (Numeric)b, err);
}

static inline void *pgx_numeric_div(void *a, void *b, bool *err) {
    return (void *)numeric_div_opt_error((Numeric)a, (Numeric)b, err);
}

static inline void *pgx_numeric_mod(void *a, void *b, bool *err) {
    return (void *)numeric_mod_opt_error((Numeric)a, (Numeric)b, err);
}

static inline int32 pgx_numeric_cmp(void *a, void *b) {
    return DatumGetInt32(DirectFunctionCall2(numeric_cmp,
                                             NumericGetDatum((Numeric)a),
                                             NumericGetDatum((Numeric)b)));
}

static inline void *pgx_numeric_abs(void *a) {
    return (void *)DatumGetNumeric(DirectFunctionCall1(numeric_abs, NumericGetDatum((Numeric)a)));
}

static inline void *pgx_numeric_uminus(void *a) {
    return (void *)DatumGetNumeric(DirectFunctionCall1(numeric_uminus, NumericGetDatum((Numeric)a)));
}

static inline void *pgx_numeric_round(void *a, int32 scale) {
    return (void *)DatumGetNumeric(DirectFunctionCall2(numeric_round,
                                                       NumericGetDatum((Numeric)a),
                                                       Int32GetDatum(scale)));
}

static inline void *pgx_numeric_trunc(void *a, int32 scale) {
    return (void *)DatumGetNumeric(DirectFunctionCall2(numeric_trunc,
                                                       NumericGetDatum((Numeric)a),
                                                       Int32GetDatum(scale)));
}

/* Dynamic type and PostgreSQL enum helpers */
static inline Oid pgx_lookup_type_oid(const char *typname) {
    Oid oid;
    Relation rel;
    ScanKeyData skey[1];
    SysScanDesc scan;
    HeapTuple tup;
    NameData tname;

    if (typname == NULL || typname[0] == '\0')
        return InvalidOid;

    if (OidIsValid(pgx_active_fn_nsp)) {
        oid = GetSysCacheOid2(TYPENAMENSP,
                              Anum_pg_type_oid,
                              CStringGetDatum(typname),
                              ObjectIdGetDatum(pgx_active_fn_nsp));
        if (OidIsValid(oid))
            return oid;
    }

    oid = TypenameGetTypid(typname);
    if (OidIsValid(oid))
        return oid;

    namestrcpy(&tname, typname);
    rel = table_open(TypeRelationId, AccessShareLock);
    ScanKeyInit(&skey[0],
                Anum_pg_type_typname,
                BTEqualStrategyNumber,
                F_NAMEEQ,
                NameGetDatum(&tname));
    scan = systable_beginscan(rel, TypeNameNspIndexId, true, NULL, 1, skey);
    tup = systable_getnext(scan);
    if (HeapTupleIsValid(tup)) {
        Form_pg_type typform = (Form_pg_type)GETSTRUCT(tup);
        oid = typform->oid;
    }
    systable_endscan(scan);
    table_close(rel, AccessShareLock);
    return oid;
}

static inline Oid pgx_get_array_type_oid(Oid elem_oid) {
    return OidIsValid(elem_oid) ? get_array_type(elem_oid) : InvalidOid;
}

static inline Oid pgx_enum_label_to_oid(const char *typname, const char *label) {
    Oid typoid;
    if (typname == NULL || label == NULL) return InvalidOid;
    typoid = pgx_lookup_type_oid(typname);
    if (!OidIsValid(typoid)) return InvalidOid;
    return DatumGetObjectId(DirectFunctionCall2(enum_in,
                                                CStringGetDatum(label),
                                                ObjectIdGetDatum(typoid)));
}

static inline char *pgx_enum_oid_to_label(Oid enum_oid) {
    if (!OidIsValid(enum_oid)) return NULL;
    return DatumGetCString(DirectFunctionCall1(enum_out, ObjectIdGetDatum(enum_oid)));
}

#endif /* PGXCROWN_PGX_TYPES_H */
