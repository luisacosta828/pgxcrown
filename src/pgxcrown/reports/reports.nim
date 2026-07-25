import errcodes


template report*(log_strategy, msg: typed) =

  {. emit: [
      """ereport(""",
      log_strategy(),
      """, (errmsg(""",
      msg.astToStr,
      """)));"""
    ].}

export errcodes
