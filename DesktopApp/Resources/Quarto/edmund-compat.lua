-- Rnotebook's export-only Edmund compatibility layer. No source rewrites,
-- file discovery, code evaluation, or metadata traversal. See docs/Edmund-Quarto-*.
local stringify = pandoc.utils.stringify
local function trim(s) return s:match('^%s*(.-)%s*$') end
local function slice(xs, a, b)
  local out = {}
  for i = a, b or #xs do out[#out + 1] = xs[i] end
  return out
end

-- Keep parsed inline nodes (including code/math) intact between delimiters.
-- Only Str nodes are split; coalesce them again before returning to Pandoc.
local function tokens(inlines)
  local out = {}
  for _, el in ipairs(inlines) do
    if el.t == 'Str' then
      for _, cp in utf8.codes(el.text) do out[#out + 1] = utf8.char(cp) end
    else out[#out + 1] = el end
  end
  return out
end
local function pack(xs)
  local out, text = pandoc.Inlines({}), {}
  local function flush()
    if #text > 0 then out:insert(pandoc.Str(table.concat(text))); text = {} end
  end
  for _, el in ipairs(xs) do
    if type(el) == 'string' then text[#text + 1] = el
    else flush(); out:insert(el) end
  end
  flush()
  return out
end
local function pair(xs, i, a, b) return xs[i] == a and xs[i + 1] == (b or a) end
local function newline(x)
  return type(x) ~= 'string' and (x.t == 'SoftBreak' or x.t == 'LineBreak')
end
local function whitespace(x)
  return x == nil or (type(x) == 'string' and x:match('^%s$'))
    or (type(x) ~= 'string' and (x.t == 'Space' or newline(x)))
end
local function find_pair(xs, start, a, b, single_line)
  for i = start, #xs - 1 do
    if single_line and newline(xs[i]) then return nil end
    if pair(xs, i, a, b) then return i end
  end
end

-- Comments can cross emphasis/link-label boundaries. Match against prose text
-- with opaque placeholders, then remove the ranges from the original tree;
-- never stringify and reparse the surviving Markdown or code.
local inline_containers = {Emph=true, Strong=true, Strikeout=true, Underline=true,
  Superscript=true, Subscript=true, SmallCaps=true, Quoted=true, Cite=true, Span=true, Link=true}
local function strip_inline_comments(inlines)
  local parts = {}
  local function flatten(xs)
    for _, el in ipairs(xs) do
      if el.t == 'Str' then parts[#parts + 1] = el.text
      elseif el.t == 'Space' then parts[#parts + 1] = ' '
      elseif newline(el) then parts[#parts + 1] = '\n'
      elseif inline_containers[el.t] then flatten(el.content)
      else parts[#parts + 1] = '\0' end
    end
  end
  flatten(inlines)
  local text, ranges, offset = table.concat(parts), {}, 1
  while true do
    local open = text:find('%%', offset, true)
    if not open then break end
    local close = text:find('%%', open + 2, true)
    if not close then break end
    ranges[#ranges + 1] = {open, close + 1}
    offset = close + 2
  end
  if #ranges == 0 then return inlines end
  local position, current = 1, 1
  local function hidden(at)
    while ranges[current] and at > ranges[current][2] do current = current + 1 end
    return ranges[current] and at >= ranges[current][1]
  end
  local function remove(xs)
    local out = pandoc.Inlines({})
    for _, el in ipairs(xs) do
      if el.t == 'Str' then
        local kept = {}
        for i = 1, #el.text do
          if not hidden(position) then kept[#kept + 1] = el.text:sub(i, i) end
          position = position + 1
        end
        if #kept > 0 then out:insert(pandoc.Str(table.concat(kept))) end
      elseif inline_containers[el.t] then
        local before = position
        el.content = remove(el.content)
        if #el.content > 0 or (position == before and not hidden(position)) then out:insert(el) end
      else
        if not hidden(position) then out:insert(el) end
        position = position + 1
      end
    end
    return out
  end
  return remove(inlines)
end

local image_extensions = {png=true, jpg=true, jpeg=true, gif=true, svg=true,
  webp=true, bmp=true, tiff=true, tif=true, avif=true}
local function dimensions(s)
  local label, w, h = s:match('^(.*)|%s*(%d+)x(%d+)%s*$')
  if not w then label, w = s:match('^(.*)|%s*(%d+)%s*$') end
  if w and tonumber(w) > 0 and (not h or tonumber(h) > 0) then return label, w, h end
  return s
end
local function size_image(el, w, h)
  if w and not el.attributes.width then el.attributes.width = w .. 'px' end
  if h and not el.attributes.height then el.attributes.height = h .. 'px' end
  return el
end

local headings = {}
local function destination(target)
  if target:sub(1, 2) == '#^' then return '#' .. target:sub(3) end
  if target:sub(1, 1) == '#' then
    return '#' .. (headings[pandoc.text.lower(trim(target:sub(2)))] or target:sub(2))
  end
  return target
end
local function wiki(inner, embed)
  local target, label = inner:match('^(.-)|(.*)$')
  target = trim(target or inner)
  if target == '' then return nil end
  if embed then
    local ext = target:match('%.([^./]+)$')
    if not ext or not image_extensions[ext:lower()] then return nil end
    local _, w, h = dimensions(inner)
    return size_image(pandoc.Image({}, target), w, h)
  end
  if not label or label == '' then label = target end
  return pandoc.Link({pandoc.Str(label)}, destination(target))
end

local html_wrappers = {
  u = pandoc.Underline, sub = pandoc.Subscript, sup = pandoc.Superscript,
  mark = function(xs) return pandoc.Span(xs, pandoc.Attr('', {'mark'})) end,
  kbd = function(xs) return pandoc.Span(xs, pandoc.Attr('', {'kbd'})) end,
  small = function(xs) return pandoc.Span(xs, pandoc.Attr('', {'small'})) end,
}
local function raw_tag(el)
  if type(el) == 'string' or el.t ~= 'RawInline' or el.format ~= 'html' then return nil end
  return el.text:lower():match('^<([a-z]+)%s*[^>]*>$')
end

local convert_inlines
convert_inlines = function(inlines)
  local text = stringify(inlines)
  if text:find('%%', 1, true) then
    inlines = strip_inline_comments(inlines)
    text = stringify(inlines)
  end
  local has_raw = false
  for _, el in ipairs(inlines) do if el.t == 'RawInline' then has_raw = true; break end end
  if not has_raw and not text:find('==', 1, true) and not text:find('%%', 1, true)
      and not text:find('[[', 1, true) then return inlines end
  local xs, out, i = tokens(inlines), {}, 1
  local has_wiki_end = text:find(']]', 1, true) ~= nil
  while i <= #xs do
    local finish, replacement
    if pair(xs, i, '%') then
      local close = find_pair(xs, i + 2, '%')
      if close then finish, replacement = close + 2, {} end
    elseif pair(xs, i, '=') and not whitespace(xs[i + 2]) then
      local close = find_pair(xs, i + 2, '=', nil, true)
      if close and close > i + 2 and not whitespace(xs[close - 1]) then
        local body = pack(slice(xs, i + 2, close - 1))
        body = convert_inlines(body) or body
        finish, replacement = close + 2, {html_wrappers.mark(body)}
      end
    elseif has_wiki_end and (pair(xs, i, '[', '[') or (xs[i] == '!' and pair(xs, i + 1, '[', '['))) then
      local embed = xs[i] == '!'
      local start = i + (embed and 3 or 2)
      local close = find_pair(xs, start, ']', ']', true)
      if close then
        -- Raw targets/aliases must not be reconstructed from interpreted nodes.
        local plain = true
        for j = start, close - 1 do
          if type(xs[j]) ~= 'string' and xs[j].t ~= 'Space' then plain = false; break end
        end
        if plain then
          local node = wiki(stringify(pack(slice(xs, start, close - 1))), embed)
          if node then finish, replacement = close + 2, {node}
          else finish, replacement = close + 2, slice(xs, i, close + 1) end
        end
      end
    else
      local tag = raw_tag(xs[i])
      if tag and html_wrappers[tag] then
        local depth, close = 1, nil
        for j = i + 1, #xs do
          if raw_tag(xs[j]) == tag then depth = depth + 1 end
          local node = xs[j]
          if type(node) ~= 'string' and node.t == 'RawInline' and node.format == 'html'
              and node.text:lower():match('^</' .. tag .. '%s*>$') then
            depth = depth - 1
            if depth == 0 then close = j; break end
          end
        end
        if close then
          local body = pack(slice(xs, i + 1, close - 1))
          body = convert_inlines(body) or body
          finish, replacement = close + 1, {html_wrappers[tag](body)}
        end
      elseif tag == 'img' then
        -- Pandoc's HTML reader handles quoting, entities and dimensions.
        local parsed = pandoc.read(xs[i].text, 'html').blocks
        if #parsed == 1 and (parsed[1].t == 'Plain' or parsed[1].t == 'Para')
            and #parsed[1].content == 1 and parsed[1].content[1].t == 'Image' then
          finish, replacement = i + 1, {parsed[1].content[1]}
        end
      end
    end
    if finish then
      for _, node in ipairs(replacement) do out[#out + 1] = node end
      i = finish
    else out[#out + 1] = xs[i]; i = i + 1 end
  end
  return pack(out)
end

-- Remove line-start comments across sibling blocks before converting their
-- contents. State is local to each Blocks list (never leaks out of a quote/list).
local function strip_block_comments(blocks)
  local out, hiding = pandoc.Blocks({}), false
  for _, block in ipairs(blocks) do
    local prose = block.t == 'Para' or block.t == 'Plain'
    local starts_comment = prose and stringify(block.content):sub(1, 2) == '%%'
    local xs = prose and (hiding or starts_comment) and tokens(block.content) or nil
    if hiding then
      local close = xs and find_pair(xs, 1, '%')
      if close then
        hiding = false
        block.content = pack(slice(xs, close + 2))
        if #block.content > 0 then out:insert(block) end
      elseif not prose and stringify(block):find('%%', 1, true) then
        -- The closing line can itself parse as a heading/code/raw block.
        hiding = false
      end
    elseif xs and pair(xs, 1, '%') and not find_pair(xs, 3, '%') then
      hiding = true
    else out:insert(block) end
  end
  return out
end

local callout_types = {
  note='note', tip='tip', important='important', warning='warning', caution='caution',
  hint='tip', abstract='note', summary='note', tldr='note', info='note', todo='note',
  success='tip', check='tip', done='tip', question='warning', help='warning', faq='warning',
  attention='warning', failure='caution', fail='caution', missing='caution',
  danger='caution', error='caution', bug='caution', example='note', quote='note', cite='note',
}
local function callout(block)
  local first = block.content[1]
  if not first or (first.t ~= 'Para' and first.t ~= 'Plain') then return nil end
  local xs = tokens(first.content)
  local line_end = #xs + 1
  for i, x in ipairs(xs) do if newline(x) then line_end = i; break end end
  local line = stringify(pack(slice(xs, 1, line_end - 1)))
  local kind, fold, marker_end = line:match('^%[!([A-Za-z][A-Za-z0-9_-]*)%]([+-]?)()')
  if not kind then return nil end
  kind = kind:lower()
  local mapped = callout_types[kind]
  if not mapped then return nil end
  -- Marker is ASCII, so byte count equals token count. Preserve title markup.
  local title = pack(slice(xs, marker_end, line_end - 1))
  while #title > 0 and title[1].t == 'Space' do title:remove(1) end
  if #title == 0 then title = pandoc.Inlines({pandoc.Str(kind:sub(1, 1):upper() .. kind:sub(2))}) end
  local body = pandoc.Blocks({pandoc.Header(2, title)})
  if line_end <= #xs then
    first.content = pack(slice(xs, line_end + 1))
    if #first.content > 0 then body:insert(first) end
  end
  body:extend(slice(block.content, 2))
  local attrs = {['data-edmund-callout'] = kind}
  if fold ~= '' then attrs.collapse = fold == '-' and 'true' or 'false' end
  return pandoc.Div(body, pandoc.Attr('', {'callout-' .. mapped}, attrs))
end

local function sized_caption(inlines)
  local caption = stringify(inlines)
  local label, w, h = dimensions(caption)
  if not w then return nil end
  -- Preserve rich caption nodes; remove only the trailing plain size suffix.
  local xs = tokens(inlines)
  local count = utf8.len(caption) - utf8.len(label)
  -- A formatted/code/math suffix is content, not a literal Edmund size token.
  if count > #xs then return nil end
  for i = #xs - count + 1, #xs do
    if type(xs[i]) ~= 'string' and xs[i].t ~= 'Space' then return nil end
  end
  for _ = 1, count do table.remove(xs) end
  return pack(xs), w, h
end
local function image(el)
  local caption, w, h = sized_caption(el.caption)
  if not caption then return nil end
  el.caption = caption
  return size_image(el, w, h)
end
local function figure(el)
  -- implicit_figures duplicates the original image alt into a Figure caption.
  -- Clean that copy as well, without changing arbitrary table/figure captions.
  local images = {}
  pandoc.Pandoc(el.content):walk({Image=function(img) images[#images + 1] = img end})
  if #images ~= 1 then return nil end
  for _, block in ipairs(el.caption.long) do
    if block.t == 'Plain' or block.t == 'Para' then
      local caption = sized_caption(block.content)
      if caption then block.content = caption end
    end
  end
  return el
end
local function block_reference(el)
  if not stringify(el.content):match('%^[A-Za-z0-9-]+%s*$') then return nil end
  local xs = tokens(el.content)
  local end_at = #xs
  while end_at > 0 and whitespace(xs[end_at]) do end_at = end_at - 1 end
  local start = end_at
  while start > 0 and type(xs[start]) == 'string' and xs[start]:match('^[A-Za-z0-9-]$') do start = start - 1 end
  if xs[start] ~= '^' or start == end_at or (start > 1 and not whitespace(xs[start - 1])) then return nil end
  local id = stringify(pack(slice(xs, start + 1, end_at)))
  local out = slice(xs, 1, start - 1)
  out[#out + 1] = pandoc.Span({}, pandoc.Attr(id))
  el.content = pack(out)
  return el
end

function Pandoc(doc)
  -- Walk only document blocks; metadata titles, variables and user filter config
  -- must not acquire Edmund interpretation or be removed as comments.
  local body = pandoc.Pandoc(doc.blocks)
  body = body:walk({traverse='topdown', Blocks=strip_block_comments})
  headings = {}
  body:walk({Header=function(el)
    local display = convert_inlines(el.content) or el.content
    local key = pandoc.text.lower(stringify(display))
    if not headings[key] then headings[key] = el.identifier end
  end})
  body = body:walk({BlockQuote=callout})
  body = body:walk({Inlines=convert_inlines, Image=image, Figure=figure})
  body = body:walk({Para=block_reference, Plain=block_reference})
  doc.blocks = body.blocks
  return doc
end
