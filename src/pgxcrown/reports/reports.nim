import errcodes

template report*(log_strategy, msg: typed) =
  {. emit: [
      """ereport(""",
      log_strategy(),
      """, (errmsg("%s", """,
      msg.astToStr,
      """)));"""
    ].}

template reportError*(msg: string) =
  let cs = cstring(msg)
  {. emit: [
      """ereport(ERROR, (errmsg("%s", """,
      cs,
      """)));"""
    ].}

export errcodes
