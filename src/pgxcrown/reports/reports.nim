import errcodes

template report*(log_strategy, msg: typed, detail_msg: typed = "", hint_msg: typed = "") =
   var strategy_code = log_strategy()
   if len(detail_msg) == 0 and (strategy_code != 19 or strategy_code != 20):
       echo "strategy: ", strategy_code
       {. emit: [
           """ereport(""",log_strategy(),
           """,(errmsg(""", msg.astToStr ,")));"
       ].}
   elif strategy_code == 19 or strategy_code == 20:
       {. emit: [
           """ereport(""",log_strategy(),
           """,( 
               errmsg(""", msg.astToStr ,"""),
               errdetail(""", detail_msg.astToStr, """),
               errhint(""", hint_msg.astToStr, """)
               )
              );"""
       ].}
      
export errcodes
