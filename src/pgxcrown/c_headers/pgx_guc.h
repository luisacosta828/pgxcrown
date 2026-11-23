#ifndef PGXCROWN_PGX_GUC_H
#define PGXCROWN_PGX_GUC_H

#include "postgres.h"
#include "utils/guc.h"
#include "miscadmin.h"

/* ============================================================================
 * ABI-Safe GUC Flag Getters
 * GUC_SUPERUSER_ONLY and neighboring flags shifted bit positions in PG 16+.
 * Never hardcode PostgreSQL GUC flag bitmasks in Nim.
 * ============================================================================ */

static inline int pgx_guc_flag_superuser_only(void) {
    return (int)GUC_SUPERUSER_ONLY;
}

static inline int pgx_guc_flag_no_show_all(void) {
    return (int)GUC_NO_SHOW_ALL;
}

static inline int pgx_guc_flag_no_reset_all(void) {
    return (int)GUC_NO_RESET_ALL;
}

static inline int pgx_guc_flag_report(void) {
    return (int)GUC_REPORT;
}

static inline int pgx_guc_flag_not_while_sec_rest(void) {
    return (int)GUC_NOT_WHILE_SEC_REST;
}

static inline int pgx_guc_flag_disallow_in_file(void) {
    return (int)GUC_DISALLOW_IN_FILE;
}

static inline int pgx_guc_flag_disallow_in_auto_file(void) {
#ifdef GUC_DISALLOW_IN_AUTO_FILE
    return (int)GUC_DISALLOW_IN_AUTO_FILE;
#else
    return 0;
#endif
}

/* ============================================================================
 * ABI-Safe GucContext Getters
 * ============================================================================ */

static inline int pgx_guc_ctx_postmaster(void) {
    return (int)PGC_POSTMASTER;
}

static inline int pgx_guc_ctx_sighup(void) {
    return (int)PGC_SIGHUP;
}

static inline int pgx_guc_ctx_su_backend(void) {
    return (int)PGC_SU_BACKEND;
}

static inline int pgx_guc_ctx_backend(void) {
    return (int)PGC_BACKEND;
}

static inline int pgx_guc_ctx_suset(void) {
    return (int)PGC_SUSET;
}

static inline int pgx_guc_ctx_userset(void) {
    return (int)PGC_USERSET;
}

/* ============================================================================
 * Preload & Security State Helpers
 * ============================================================================ */

static inline bool pgx_guc_is_shared_preload_in_progress(void) {
    return process_shared_preload_libraries_in_progress;
}

static inline bool pgx_guc_in_security_restricted_operation(void) {
    return InSecurityRestrictedOperation();
}

static inline bool pgx_guc_is_superuser(void) {
    return superuser();
}

/* ============================================================================
 * Cross-Version Custom GUC Definition Wrappers
 * ============================================================================ */

static inline void pgx_define_custom_bool(
    const char *name,
    const char *short_desc,
    const char *long_desc,
    void *value_addr,
    bool boot_value,
    int context,
    int flags
) {
    DefineCustomBoolVariable(
        name, short_desc, long_desc, (bool *)value_addr, boot_value,
        (GucContext)context, flags, NULL, NULL, NULL
    );
}

static inline void pgx_define_custom_int(
    const char *name,
    const char *short_desc,
    const char *long_desc,
    void *value_addr,
    int boot_value,
    int min_value,
    int max_value,
    int context,
    int flags
) {
    DefineCustomIntVariable(
        name, short_desc, long_desc, (int *)value_addr, boot_value,
        min_value, max_value, (GucContext)context, flags, NULL, NULL, NULL
    );
}

static inline void pgx_define_custom_real(
    const char *name,
    const char *short_desc,
    const char *long_desc,
    void *value_addr,
    double boot_value,
    double min_value,
    double max_value,
    int context,
    int flags
) {
    DefineCustomRealVariable(
        name, short_desc, long_desc, (double *)value_addr, boot_value,
        min_value, max_value, (GucContext)context, flags, NULL, NULL, NULL
    );
}

static inline void pgx_define_custom_string(
    const char *name,
    const char *short_desc,
    const char *long_desc,
    void *value_addr,
    const char *boot_value,
    int context,
    int flags
) {
    DefineCustomStringVariable(
        name, short_desc, long_desc, (char **)value_addr, boot_value,
        (GucContext)context, flags, NULL, NULL, NULL
    );
}

static inline void pgx_define_custom_enum(
    const char *name,
    const char *short_desc,
    const char *long_desc,
    void *value_addr,
    int boot_value,
    const struct config_enum_entry *options,
    int context,
    int flags
) {
    DefineCustomEnumVariable(
        name, short_desc, long_desc, (int *)value_addr, boot_value,
        options, (GucContext)context, flags, NULL, NULL, NULL
    );
}

/* ============================================================================
 * PG 14 vs PG 15+ Prefix Reservation, Restricted Read & RBAC Mutation
 * ============================================================================ */

static inline void pgx_mark_guc_prefix_reserved(const char *prefix) {
#if PG_VERSION_NUM >= 150000
    MarkGUCPrefixReserved(prefix);
#else
    EmitWarningsOnPlaceholders(prefix);
#endif
}

static inline const char *pgx_get_config_option_restricted(const char *name, bool missing_ok) {
    return GetConfigOption(name, missing_ok, true);
}

static inline int pgx_set_config_option_rbac(const char *name, const char *value, bool is_local) {
    GucContext ctx = (!InSecurityRestrictedOperation() && superuser()) ? PGC_SUSET : PGC_USERSET;
    GucAction act = is_local ? GUC_ACTION_LOCAL : GUC_ACTION_SET;
#if PG_VERSION_NUM >= 150000
    return set_config_option_ext(name, value, ctx, PGC_S_SESSION, GetUserId(), act, true, ERROR, false);
#else
    return set_config_option(name, value, ctx, PGC_S_SESSION, act, true, ERROR, false);
#endif
}

#endif /* PGXCROWN_PGX_GUC_H */
