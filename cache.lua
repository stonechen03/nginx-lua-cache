	 -- Check required variable "key", which must be trasferred as GET parameter
        local cacheKey = ngx.var.arg_key
        if (cacheKey == nil or cacheKey == '') then
            ngx.say ('{error: "Cache key must be specified"}')
            return
        end

        -- Declare local link to shared Nginx cache
        local cache = ngx.shared.SharedCache

        -- Try load data from shared dictionary
        local cacheValue = cache:get(cacheKey)
        
        if cacheValue == nil then

            -- Shared dictionary return "not found", we gotta check Redis Server
            local redis = require "resty.redis"
            local red = redis:new()
            red:set_timeout(1000) -- 1 second

            -- Try connect to Redis Server
            local ok, err = red:connect("127.0.0.1", 6379)
            if not ok then
                ngx.say('{error: "failed to connect: ' .. err .. '"}')
                ngx.log(ngx.ERR, 'Failed to connect to Redis Server ' .. err);
                return
            end

            local res, err = red:get(cacheKey)

            cacheValue = res

            if cacheValue == ngx.null then

                -- If Redis Server cache empty - we'll try load data bu typical wal - GET request to another location, served by process manager, like php-fpm
                local capturedLocation = "/" .. cacheKey

                ngx.req.read_body()
                ngx.req.set_uri(capturedLocation)

                local renderedResult = ngx.location.capture(capturedLocation, {args = {uri = ngx.var.uri}})
                if renderedResult.status ~= 200 then
                   ngx.log(ngx.INFO, "NGINX-LUA-CACHE:[RENDERING] Required cached location [" .. capturedLocation .. "] return status code " .. renderedResult.status)
                   return
                else
                   ngx.log(ngx.INFO, "NGINX-LUA-CACHE:[RENDERING] Required cached location [" .. capturedLocation .. "] rendered successfully")
                end

                local smartCacheTTL = renderedResult.header['X-Smart-Cache-TTL']
                if smartCacheTTL == nil then
                    smartCacheTTL = 0
                end

                cacheValue = renderedResult.body

                -- Store rendered result to Redis Server cache
                ok, err = red:set(cacheKey, cacheValue)
                if not ok then
                    ngx.log(ngx.INFO, "NGINX-LUA-CACHE: Redis Server SET error: " .. err)
                end

                red:expire(cacheKey, smartCacheTTL)
            end

            -- Store cache data from Redis Server to shared cache provided by Nginx
            -- Default lifetime for data on shared Nginx cache - 5 seconds
            cache:set(cacheKey, cacheValue, 5)
            ngx.log(ngx.INFO, "NGINX-LUA-CACHE: Cache from Redis Server stored to shared memory");

            -- Release redis server connection
            red:set_keepalive()
        end

        ngx.say(cacheValue)

