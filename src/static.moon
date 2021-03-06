--
-- static file server
--

UV = require 'uv'
import format from require 'string'
import get_type from require 'mime'
import stat, create_read_stream from require 'fs'
import date from require 'os'
import resolve from require 'path'

--
-- open file `path`, seek to `offset` octets from beginning and
-- read `size` subsequent octets.
-- call `progress` on each read chunk
--
CHUNK_SIZE = 4096
noop = () ->

stream_file = (path, offset, size, progress, callback) ->
  UV.fs_open path, 'r', '0666', (err, fd) ->
    return callback err if err
    readchunk = () ->
      chunk_size = size < CHUNK_SIZE and size or CHUNK_SIZE
      UV.fs_read fd, offset, chunk_size, (err, chunk) ->
        if err or #chunk == 0
          callback err
          UV.fs_close fd, noop
        else
          chunk_size = #chunk
          offset = offset + chunk_size
          size = size - chunk_size
          if progress
            progress chunk, readchunk
          else
            readchunk()
    readchunk()
  return

--
-- setup request handler
--
return (mount, options = {}) ->

  -- given Range: header, return start, end numeric pair
  parse_range = (range, size) ->
    partial, start, stop = false
    if range
      -- parse bytes=start-stop
      start, stop = range\match('bytes=(%d*)-?(%d*)')
      partial = true
    start = tonumber(start) or 0
    stop = tonumber(stop) or size - 1
    start, stop, partial

  -- cache entries table
  cache = {}

  -- handler for 'change' event of all file watchers
  invalidate_cache_entry = (status, event, path) ->
    -- invalidate cache entry and free the watcher
    if cache[path]
      cache[path].watch\close()
      cache[path] = nil
    return

  -- given file, serve contents, honor Range: header
  serve = (file, range, cache_it) =>
    -- adjust headers
    headers = extend {}, file.headers
    --
    size = file.size
    start = 0
    stop = size - 1
    -- range specified? adjust headers and http status for response
    if range
      start, stop = parse_range range, size
      -- limit range by file size
      stop = size - 1 if stop >= size
      -- check range validity
      return @serve_invalid_range(file.size) if stop < start
      -- adjust Content-Length:
      headers['Content-Length'] = stop - start + 1
      -- append Content-Range:
      headers['Content-Range'] = format('bytes=%d-%d/%d', start, stop, size)
      @write_head 206, headers
    else
      @write_head 200, headers
    -- serve from cache, if available
    if file.data
      -- FIXME: safe
      @finish range and file.data.sub(start + 1, stop - start + 1) or file.data
    -- otherwise stream and possibly cache
    else
      -- N.B. don't cache if range specified
      cache_it = false if range
      index, parts = 1, {}
      -- progress
      progress = (chunk, cb) ->
        if cache_it
          parts[index] = chunk
          index = index + 1
        -- FIXME: safe
        @write(chunk, cb)
      -- eof
      eof = (err) ->
        @finish()
        if cache_it
          file.data = join parts, ''
      stream_file file.name, start, stop - start + 1, progress, eof

  -- cache some locals
  mount_point_len = #mount + 1
  max_age = options.max_age or 0

  --
  -- request handler
  --
  return (req, res, continue) ->

    -- none of our business unless method is GET
    -- and url starts with `mount`
    return continue() if req.method != 'GET' or req.url\find(mount) != 1

    -- map url to local filesystem filename
    -- TODO: Path.normalize(req.url)
    filename = resolve options.directory, req.uri.pathname\sub(mount_point_len)

    -- stream file, possibly caching the contents for later reuse
    file = cache[filename]

    -- no need to serve anything if file is cached at client side
    if file and file.headers['Last-Modified'] == req.headers['if-modified-since']
      return res\serve_not_modified file.headers

    if file
      serve res, file, req.headers.range, false
    else
      stat filename, (err, stat) ->
        if err
          res\serve_not_found()
          return
        -- create cache entry, even for files which contents are not
        -- gonna be cached
        -- collect information on file
        file = {
          name: filename
          size: stat.size
          mtime: stat.mtime
          -- FIXME: finer control client-side caching
          headers:
            ['Content-Type']: get_type(filename)
            ['Content-Length']: stat.size
            ['Cache-Control']: 'public, max-age=' .. (max_age / 1000)
            ['Last-Modified']: date('%c', stat.mtime)
            ['Etag']: stat.size .. '-' .. stat.mtime
        }
        -- allocate cache entry
        cache[filename] = file
        -- should any changes in this file occur, invalidate cache entry
        file.watch = UV.new_fs_watcher filename
        file.watch\set_handler 'change', invalidate_cache_entry
        -- shall we cache file contents?
        cache_it = options.is_cacheable and options.is_cacheable(file)
        serve res, file, req.headers.range, cache_it
