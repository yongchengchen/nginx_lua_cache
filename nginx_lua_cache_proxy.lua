local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local req = ngx.req
local ngx_var = ngx.var
local str_lower = string.lower

local redis_lib = require "resty.redis"

local redis = redis_lib:new()
function init()
    local ok, err = redis:connect("127.0.0.1", 6379)
    if not ok then
        ngx.header.content_type = 'text/html'
        ngx.say('redis connection failed')
        --ngx.status = 305
        --ngx.exit(ngx.status)
        return 
    end
end

function blacklist_check()
    if ngx_var.uri == '/phone/call/index/' then
        return true
    end
    if ngx_var.uri == '/customer/account/' then
        return true
    end
    if ngx_var.uri == '/customer/account/login/' then
        return true
    end
    if ngx_var.uri == '/customer/account/logout/' then
        return true
    end
    if ngx_var.uri == '/facebook/customer_account/connect/' then
        return true
    end
    return false
end

function hit()
    local method = req.get_method()
    if blacklist_check() or method ~= 'GET' then
        ngx.status = 305
        ngx.exit(ngx.status)
        do return end
    end    

    local prefix = 'n:'
    if ngx.var.scheme == "https" then
        prefix = 's:'
    end

    local path = (prefix .. ngx_var.uri .. ngx_var.is_args .. (ngx_var.args or ""))
    local res, err = redis:get(path)
    if res == ngx.null then
        --call prox_pass
        local body = proxy_pass()
        redis:set(path, body)
        ngx.say(body)
    else 
        ngx.header.content_type = 'text/html; charset=UTF-8'
        ngx.header.content_encoding = 'gzip'
        ngx.header['x-cache-server'] = 'nginx-lua'
        ngx.header['x-nginx-cached'] = 600
        ngx.say(res)
    end
end

function handle_header(headers)
    local res_header = ngx.header
    local HOP_BY_HOP_HEADERS = {
        ["connection"]          = true,
        ["keep-alive"]          = true,
        ["proxy-authenticate"]  = true,
        ["proxy-authorization"] = true,
        ["te"]                  = true,
        ["trailers"]            = true,
        ["transfer-encoding"]   = true,
        ["upgrade"]             = true,
        ["set-cookie"]          = true,
    }

    for k,v in pairs(headers) do
        if not HOP_BY_HOP_HEADERS[str_lower(k)] then
            res_header[k] = v
        end
    end
end

function proxy_pass()
    local httpc = http_upstream
    local upstream = upstream

    if ngx.var.scheme == "https" then
        httpc = https_upstream
        upstream = upstream_ssl
    end

    local client_body_reader, err = httpc:get_client_body_reader()
    if not client_body_reader then
        if err == "chunked request bodies not supported yet" then
            ngx.status = 411
            ngx.say("411 Length Required")
            ngx.exit(ngx.status)
            return
        elseif err ~= nil then
            ngx_log(ngx_ERR, "Error getting client body reader: ", err)
        end
    end

    local res, conn_info = httpc:request{
        method = req.get_method(),
        path = (ngx_var.uri .. ngx_var.is_args .. (ngx_var.args or "")),
        body = client_body_reader,
        headers = req.get_headers(),
    }

    if not res then
        ngx.status = conn_info.status
        ngx.say(conn_info.err)
        return ngx.exit(ngx.status)
    end

    ngx.status = res.status
    handle_header(res.headers)

    local reader = res.body_reader
    local body = ''
    if reader then
        repeat
          local chunk, err = reader(65536)
          if err then
            ngx_log(ngx_ERR, "Read Error: "..(err or ""))
            break
          end

            if chunk then
              body = body..chunk
            end
        until not chunk
    end
  local ok,err = httpc:set_keepalive()
  upstream:process_failed_hosts()
  return body
end
init()
hit()
