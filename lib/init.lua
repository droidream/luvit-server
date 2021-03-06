require('./util')
require('./request')
require('./response')
local Http = require('http')
local Stack = require('stack')
local Path = require('path')
local parse_url = require('url').parse
local parse_query = require('querystring').parse
Stack.errorHandler = function(req, res, err)
  if err then
    local reason = err
    print('\n' .. reason .. '\n')
    return res:fail(reason)
  else
    return res:send(404)
  end
end
local use
use = function(plugin_name)
  return require(Path.join(__dirname, plugin_name))
end
local run
run = function(layers, port, host)
  local handler = Stack.stack(unpack(layers))
  local server = Http.create_server(host or '127.0.0.1', port or 80, function(req, res)
    res.req = req
    if not req.uri then
      req.uri = parse_url(req.url)
      req.uri.query = parse_query(req.uri.query)
    end
    handler(req, res)
    return 
  end)
  return server
end
local standard
standard = function(port, host, options)
  extend(options, { })
  local layers = {
    use('health')(),
    use('static')('/public/', options.static),
    use('session')(options.session),
    use('body')(),
    use('route')(options.routes),
    use('auth')('/rpc/auth', options.session),
    use('rest')('/rpc/'),
    use('websocket')('/ws/')
  }
  return run(layers, port, host)
end
local Application = { }
local _ = [[--require('utils').inherits Application, require('emitter')

Application.prototype:setup = (options) ->
  @options = options

Application.prototype:run = (port, host) ->
  standard port, host, @options
--]]
return {
  use = use,
  run = run,
  Application = Application
}
