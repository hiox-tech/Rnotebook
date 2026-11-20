-- Normalize editor file URLs before Quarto resolves image resources. This is
-- independent of Edmund syntax compatibility and never rewrites the source.
local function local_image(image)
  local scheme, rest = image.src:match('^([%a][%w+.-]*):(.*)$')
  if not scheme or scheme:lower() ~= 'file' then return nil end
  local path = rest
  if rest:sub(1, 2) == '//' then
    local host
    host, path = rest:match('^//([^/]*)(/.*)$')
    if not host or (host ~= '' and host:lower() ~= 'localhost') then return nil end
  end
  if path:sub(1, 1) ~= '/' then return nil end
  -- Decode once: %25 in a filename must remain a literal percent sign.
  path = path:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  if path:find('\0', 1, true) then return nil end
  local relative = pandoc.path.make_relative(path, pandoc.system.get_working_directory(), true)
  -- Pandoc interprets image sources as URIs; preserve literal %, # and spaces
  -- in filenames rather than letting a second URI parse change the target.
  -- Explicit ASCII ranges: Lua's %w is locale-dependent and can classify
  -- individual UTF-8 bytes as letters, producing partially encoded Unicode.
  image.src = relative:gsub('([^a-zA-Z0-9%-%._~/])', function(char)
    return string.format('%%%02X', string.byte(char))
  end)
  return image
end

return {Image = local_image}
