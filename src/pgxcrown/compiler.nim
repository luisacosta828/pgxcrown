when defined(windows):
  const HAVE_LONG_LONG_INT_64 = "HAVE_LONG_LONG_INT_64"
  {.passC: "-D" & HAVE_LONG_LONG_INT_64 & " -DWIN32 -DWINDOWS -D__WINDOWS__ -D__WIN32__ -D_CRT_SECURE_NO_DEPRECATE -D_CRT_NONSTDC_NO_DEPRECATE".}
  {.passC: "-include postgres.h -include fmgr.h -include funcapi.h".}

elif defined(linux):
  {.passC: "-include postgres.h -include fmgr.h -include funcapi.h".}
else:
  discard
