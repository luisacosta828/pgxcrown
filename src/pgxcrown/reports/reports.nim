import errcodes

template report*(log_strategy, msg: typed) =

  {. emit: [
      """ereport(""",
      log_strategy(),
      """, (errmsg("%s", """,
      msg.astToStr,
      """)));"""
    ].}

export errcodes
