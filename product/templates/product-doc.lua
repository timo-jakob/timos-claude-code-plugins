-- product-doc.lua — the pandoc filter behind render-document.zsh (#3204).
--
-- One filter serves both outputs (Typst for the PDF, EPUB for the ePub). It
--
--   1. drops the machine block (a `<details>` element holding a fenced JSON
--      object with a `schema` key, and everything inside it) and every HTML
--      comment, the `charter:prose:*` / `personas:prose:*` sentinels included,
--      so neither reaches the output; any other `<details>` keeps its content,
--      its summary as a bold line;
--   2. appends each appendix after the main document, read with the same
--      reader, its identifiers prefixed so two documents never share one;
--   3. rewrites links: one into the main document or an appendix becomes an
--      internal link, one to any other file of the repository becomes an
--      absolute URL on the remote (or plain text when there is none) and always
--      shows the file's repo-relative path;
--   4. renders GitHub alerts (`> [!NOTE]`, `> [!IMPORTANT]` …) as callouts and,
--      in the PDF, starts a new page after a `Summary` section and before each
--      appendix.
--
-- render-document.zsh passes its facts as metadata and the filter removes them
-- again, so none of them reaches either output:
--   pd_root      absolute repository root
--   pd_doc       absolute path of the main document
--   pd_appendix  list of absolute appendix paths, in order
--   pd_remote    absolute URL prefix (`https://host/owner/repo/blob/<ref>`) or ""
--   pd_reader    the reader the script used, so appendices parse the same way

local stringify = pandoc.utils.stringify

local root, remote, reader
local docs = {}       -- absolute path -> { index, prefix, anchor }
local doc_list = {}   -- in output order, main document first

-- Lexically normalise an absolute path: collapse `//`, `.` and `..`.
local function normalise(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return "/" .. table.concat(parts, "/")
end

local function dirname(path)
  return (path:match("^(.*)/[^/]*$") or "")
end

-- The path relative to the repository root, or nil when it lies outside.
local function repo_relative(abs)
  if abs == root then return "" end
  if abs:sub(1, #root + 1) == root .. "/" then return abs:sub(#root + 2) end
  return nil
end

-- Percent-encode one URL path, keeping `/` and the unreserved characters.
local function encode_path(path)
  return (path:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function percent_decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function is_comment(text)
  return text:match("^%s*<!%-%-") ~= nil
end

-- True when a span of blocks holds the machine block: a `json` code block
-- whose text is an object with a `schema` key.
local function holds_machine_block(span)
  local found = false
  pandoc.Blocks(span):walk({
    CodeBlock = function(cb)
      if found or not cb.classes:includes("json") then return nil end
      local ok, value = pcall(pandoc.json.decode, cb.text, false)
      if ok and type(value) == "table" and value.schema ~= nil then found = true end
    end,
  })
  return found
end

-- Any other `<details>` is unwrapped: its tags go, its summary stays as a bold
-- line and everything else inside it stays, raw HTML read as HTML.
local function unwrap(span)
  local out = pandoc.Blocks({})
  for _, b in ipairs(span) do
    if b.t == "RawBlock" and b.format:match("html") then
      local summary = b.text:match("<summary[^>]*>(.-)</summary%s*>")
      if summary and summary:match("%S") then
        local inlines = pandoc.utils.blocks_to_inlines(pandoc.read(summary, "html").blocks)
        out:insert(pandoc.Para({ pandoc.Strong(inlines) }))
      end
      local rest = b.text:gsub("<summary[^>]*>.-</summary%s*>", "")
        :gsub("</?details[^>]*>", "")
      if rest:match("%S") then out:extend(pandoc.read(rest, "html").blocks) end
    else
      out:insert(b)
    end
  end
  return out
end

-- The machine block and the comments. A `<details>` element may arrive as one
-- raw block or split around the markdown pandoc parsed inside it, so the depth
-- is counted across blocks and the span between the outer tags is collected:
-- dropped when it holds the machine block, unwrapped otherwise.
local function strip(blocks)
  local out, depth, span = pandoc.Blocks({}), 0, {}
  for _, b in ipairs(blocks) do
    local opens, closes = 0, 0
    if b.t == "RawBlock" and b.format:match("html") then
      opens = select(2, b.text:gsub("<details[%s>]", ""))
      closes = select(2, b.text:gsub("</details%s*>", ""))
    end
    if depth > 0 or opens > 0 then
      span[#span + 1] = b
      depth = depth + opens - closes
      if depth <= 0 then
        depth = 0
        if not holds_machine_block(span) then out:extend(unwrap(span)) end
        span = {}
      end
    elseif not (b.t == "RawBlock" and b.format:match("html") and is_comment(b.text)) then
      out:insert(b)
    end
  end
  -- an unclosed `<details>` runs to the end of the document
  if #span > 0 and not holds_machine_block(span) then out:extend(unwrap(span)) end
  return out:walk({
    RawInline = function(r)
      if r.format:match("html") and is_comment(r.text) then return {} end
    end,
    RawBlock = function(r)
      if r.format:match("html") and is_comment(r.text) then return {} end
    end,
  })
end

-- Give every identifier in an appendix its document's prefix.
local function prefix_ids(blocks, prefix)
  local function rename(el)
    if el.identifier and el.identifier ~= "" then
      el.identifier = prefix .. el.identifier
      return el
    end
  end
  return blocks:walk({ Header = rename, Div = rename, Span = rename, Code = rename,
                       CodeBlock = rename, Link = rename, Image = rename, Table = rename })
end

-- The text a link to another repository file shows: its own text, followed by
-- the repo-relative path whenever the text does not already show it.
local function with_path(content, rel)
  if stringify(content):find(rel, 1, true) then return content end
  local out = pandoc.Inlines(content)
  out:extend({ pandoc.Space(), pandoc.Str("(" .. rel .. ")") })
  return out
end

-- Rewrite one link found in the document at `base` (its absolute path).
local function rewrite_link(link, base, doc)
  local target = link.target
  if target:match("^%a[%w+.%-]*:") or target:match("^//") then return nil end

  local path, fragment = target:match("^([^#]*)#?(.*)$")
  path = percent_decode(path or "")
  if path == "" then
    -- a fragment in the same document
    if fragment == "" then return nil end
    link.target = "#" .. doc.prefix .. fragment
    return link
  end

  local abs
  if path:sub(1, 1) == "/" then
    abs = normalise(root .. path)
  else
    abs = normalise(dirname(base) .. "/" .. path)
  end

  local into = docs[abs]
  if into then
    link.target = "#" .. (fragment ~= "" and (into.prefix .. fragment) or into.anchor)
    return link
  end

  local rel = repo_relative(abs)
  if rel == nil or rel == "" then
    -- outside the repository: nothing to point at, keep the words
    return pandoc.Span(link.content)
  end
  local shown = with_path(link.content, rel)
  if remote ~= "" then
    local url = remote .. "/" .. encode_path(rel)
    if fragment ~= "" then url = url .. "#" .. fragment end
    return pandoc.Link(shown, url, link.title)
  end
  return pandoc.Span(shown)
end

-- Resolve a relative image against its own document, so an appendix's images
-- load wherever the render runs.
local function rewrite_image(img, base)
  local src = img.src
  if src:match("^%a[%w+.%-]*:") or src:match("^/") then return nil end
  img.src = normalise(dirname(base) .. "/" .. percent_decode(src))
  return img
end

local function process(blocks, doc)
  blocks = strip(blocks)
  if doc.prefix ~= "" then blocks = prefix_ids(blocks, doc.prefix) end
  return blocks:walk({
    Link = function(l) return rewrite_link(l, doc.path, doc) end,
    Image = function(i) return rewrite_image(i, doc.path) end,
  })
end

-- Every document needs an anchor a link to the file itself can land on: its
-- first heading's identifier, or a fresh one on a heading-less document.
local function anchor_of(blocks, doc)
  for _, b in ipairs(blocks) do
    if b.t == "Header" and b.identifier ~= "" then return blocks, b.identifier end
  end
  local id = doc.prefix .. "document-start"
  local out = pandoc.Blocks({ pandoc.Div({}, pandoc.Attr(id)) })
  out:extend(blocks)
  return out, id
end

local is_typst = FORMAT:match("typst") ~= nil

local function pagebreak()
  return pandoc.RawBlock("typst", "#pagebreak(weak: true)")
end

local CALLOUTS = { note = true, tip = true, important = true, warning = true, caution = true }

-- A GitHub alert arrives as a Div with its kind as class and a `title` Div.
local function callout(div)
  local kind
  for _, c in ipairs(div.classes) do
    if CALLOUTS[c] then kind = c end
  end
  if not kind then return nil end
  if not is_typst then
    div.classes = { "callout", kind }
    return div
  end
  local title, body = "", pandoc.Blocks({})
  for _, b in ipairs(div.content) do
    if b.t == "Div" and b.classes:includes("title") then
      title = stringify(b)
    else
      body:insert(b)
    end
  end
  local out = pandoc.Blocks({
    pandoc.RawBlock("typst", string.format('#callout("%s", "%s")[', kind, title:gsub('[\\"]', "\\%0"))),
  })
  out:extend(body)
  out:insert(pandoc.RawBlock("typst", "]"))
  return out
end

-- A new page after a section headed `Summary`, at that heading's level.
local function summary_page(blocks)
  local out, level = pandoc.Blocks({}), nil
  for _, b in ipairs(blocks) do
    if b.t == "Header" then
      if level and b.level <= level then
        out:insert(pagebreak())
        level = nil
      end
      if stringify(b):lower() == "summary" then level = b.level end
    end
    out:insert(b)
  end
  return out
end

-- Internal links whose target no document defines would fail the Typst build;
-- they keep their words and lose the link.
local function drop_dangling(blocks)
  local ids = {}
  blocks:walk({
    Header = function(h) ids[h.identifier] = true end,
    Div = function(d) ids[d.identifier] = true end,
    Span = function(s) ids[s.identifier] = true end,
  })
  return blocks:walk({
    Link = function(l)
      local id = l.target:match("^#(.+)$")
      if id and not ids[id] then return pandoc.Span(l.content) end
    end,
  })
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then error("cannot read " .. path .. ": " .. tostring(err)) end
  local text = f:read("a")
  f:close()
  return text
end

function Pandoc(doc)
  local meta = doc.meta
  root = stringify(meta.pd_root or "")
  remote = stringify(meta.pd_remote or "")
  reader = stringify(meta.pd_reader or "gfm")
  local main = stringify(meta.pd_doc or "")
  local appendices = {}
  if meta.pd_appendix then
    local list = meta.pd_appendix
    if list.t ~= "MetaList" and type(list) ~= "table" then list = { list } end
    for _, a in ipairs(list) do appendices[#appendices + 1] = stringify(a) end
  end
  for _, k in ipairs({ "pd_root", "pd_doc", "pd_appendix", "pd_remote", "pd_reader" }) do
    meta[k] = nil
  end

  doc_list = { { path = main, prefix = "" } }
  for i, a in ipairs(appendices) do
    doc_list[#doc_list + 1] = { path = a, prefix = "appendix-" .. i .. "-" }
  end

  -- read every document and fix its anchor before any link is rewritten
  local bodies = {}
  for i, d in ipairs(doc_list) do
    local blocks
    if i == 1 then
      blocks = doc.blocks
    else
      blocks = pandoc.read(read_file(d.path), reader).blocks
    end
    local raw = strip(blocks)
    if d.prefix ~= "" then raw = prefix_ids(raw, d.prefix) end
    local _, anchor = anchor_of(raw, d)
    d.anchor = anchor
    docs[d.path] = d
    bodies[i] = blocks
  end

  local all = pandoc.Blocks({})
  for i, d in ipairs(doc_list) do
    local blocks = process(bodies[i], d)
    blocks = anchor_of(blocks, d)
    if i > 1 and is_typst then all:insert(pagebreak()) end
    all:extend(blocks)
  end

  all = drop_dangling(all)
  all = all:walk({ Div = callout })
  if is_typst then all = summary_page(all) end
  return pandoc.Pandoc(all, meta)
end
