local encode = require('json').stringify
local parse_query = require('querystring').parse

local function handler(self, options, sid)
  self:handle_balancer_cookie()
  self.auto_chunked = false
  local query = parse_query(self.req.uri.query)
  local callback = query.c or query.callback
  if not callback then
    return self:fail('"callback" parameter required')
  end
  self:send(200, nil, {
    ['Content-Type'] = 'application/javascript; charset=UTF-8',
    ['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
  }, false)
  self.protocol = 'jsonp'
  self.curr_size, self.max_size = 0, 1
  self.send_frame = function(self, payload, continue)
    return self:write_frame(callback .. '(' .. encode(payload) .. ');\r\n', continue)
  end
  self:create_session(self.req, self, sid, options)
end

return {
  GET = handler
}
