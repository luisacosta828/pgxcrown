when defined(windows):
  const HAVE_LONG_LONG_INT_64 = "HAVE_LONG_LONG_INT_64"
  {.passC: "-D" & HAVE_LONG_LONG_INT_64 & " -DWIN32 -DWINDOWS -D__WINDOWS__ -D__WIN32__ -D_CRT_SECURE_NO_DEPRECATE -D_CRT_NONSTDC_NO_DEPRECATE".}
  {.passC: "-include postgres.h -include fmgr.h -include funcapi.h".}

elif defined(linux):
  {.passC: "-include postgres.h -include fmgr.h -include funcapi.h".}
  {.emit: """/*INCLUDESECTION*/
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#undef sprintf
#undef vsprintf
#undef snprintf
#undef vsnprintf
#undef strerror

__attribute__((weak)) int pg_sprintf(char *str, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsprintf(str, fmt, args);
    va_end(args);
    return ret;
}

__attribute__((weak)) char *pg_strerror(int errnum) {
    return strerror(errnum);
}

__attribute__((weak)) int pg_snprintf(char *str, size_t count, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsnprintf(str, count, fmt, args);
    va_end(args);
    return ret;
}

__attribute__((weak)) int pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args) {
    return vsnprintf(str, count, fmt, args);
}
#endif
""".}
else:
  discard
