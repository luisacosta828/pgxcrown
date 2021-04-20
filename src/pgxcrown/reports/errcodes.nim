type ErrorCodes* = enum
     LOG_CLIENT_ONLY = 15,
     LOG_SERVER_ONLY = 16,
     INFO = 17,
     NOTICE = 18,
     WARNING = 19,
     ERROR = 20

proc log_client_only*(): cint {. inline .} = ord(ErrorCodes.LOG_CLIENT_ONLY)
proc log_server_only*(): cint {. inline .} = ord(ErrorCodes.LOG_SERVER_ONLY)
proc info*(): cint {. inline .} = ord(ErrorCodes.INFO)
proc notice*(): cint {. inline .} = ord(ErrorCodes.NOTICE)
proc warning*(): cint {. inline .} = ord(ErrorCodes.WARNING)
proc error*(): cint {. inline .} = ord(ErrorCodes.ERROR)

