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
  {. emit: [
      """ereport(ERROR, (errmsg("%s", """,
      msg,
      """)));"""
    ].}

export errcodes
