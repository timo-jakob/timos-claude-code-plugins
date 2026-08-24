--[[
break-long-tokens.lua — give LaTeX somewhere to wrap long unbreakable tokens.

LaTeX never hyphenates typewriter text, and it finds no break opportunity
inside a path like `development/skills/bootstrap/docs/APPROVER.md` or a prose
token like `actions_requiring_review`. Such a token does not wrap: it runs past
its line, and in a table it prints straight over the neighbouring column. That
is the "Doc | Covers" table in docs/index.md rendering as overlapping text in
manual.pdf.

This filter inserts zero-width `\allowbreak` break opportunities:

  * inside every inline code span, after each ASCII punctuation character and
    at each camelCase hump, and
  * inside long prose words, after the separators an identifier is built from.

`\allowbreak` is invisible unless the line actually needs to wrap there, so a
token that already fits is typeset exactly as before.

Break points are produced by splitting the element into several `Code` / `Str`
inlines rather than by emitting raw LaTeX, which keeps pandoc in charge of
escaping the content — `100%`, `$HOME`, `a{b}c` and `back\slash` all survive.

Two deliberate restrictions:

  * only single-byte ASCII characters are break points, so a multi-byte UTF-8
    character is never split down the middle, and
  * no break is inserted when the next character is a separator too, so `--flag`,
    `://` and `->` stay intact.

LaTeX output only; every other writer (the ePub, notably) is left untouched.
]]

-- Inline code: any ASCII punctuation is a place to wrap.
local CODE_SEPARATORS = [[/-_.:=,;()[]{}<>|&?!@#%+*~^$"'`\]]

-- Prose: the separators that show up inside a long identifier quoted as plain
-- text — `/development-python:maintenance`, `actions_requiring_review`.
local PROSE_SEPARATORS = [[/_-:.]]

-- The same set as a Lua character class. Spelled separately because `-` has to
-- be escaped here (unescaped it would open a range) but must stay literal in
-- the plain-text `find` above.
local PROSE_SEPARATORS_CLASS = "[/_:.%-]"

-- Below this length a word wraps fine on its own, and breaking it only makes
-- the generated LaTeX harder to read.
local PROSE_MIN_LENGTH = 12

local function is_separator(char, separators)
  if char == "" then
    return false
  end
  return char:byte() < 128 and separators:find(char, 1, true) ~= nil
end

-- A camelCase hump: `requireAllDeclaredGuarded` carries no punctuation at all,
-- so without this it stays one unbreakable 25-character token. Code spans only
-- — prose does not have identifiers like that.
local function is_camel_hump(char, next_char)
  if char == "" or next_char == "" then
    return false
  end
  -- ASCII only, for the same reason as is_separator: `%u` is locale-dependent
  -- on bytes above 127, and a match there would split a UTF-8 character.
  if char:byte() >= 128 or next_char:byte() >= 128 then
    return false
  end
  return char:match("[%l%d]") ~= nil and next_char:match("%u") ~= nil
end

--- Split `text` at each break opportunity, returning the pieces in order.
-- Returns nil when there is nothing to split, so the caller can leave the
-- element alone.
local function split_into_pieces(text, separators, camel_case)
  local pieces = {}
  local buffer = ""

  for i = 1, #text do
    local char = text:sub(i, i)
    buffer = buffer .. char
    local next_char = text:sub(i + 1, i + 1)
    local at_separator = is_separator(char, separators) and not is_separator(next_char, separators)
    local at_hump = camel_case and is_camel_hump(char, next_char)
    if i < #text and (at_separator or at_hump) then
      table.insert(pieces, buffer)
      buffer = ""
    end
  end
  if buffer ~= "" then
    table.insert(pieces, buffer)
  end

  if #pieces < 2 then
    return nil
  end
  return pieces
end

local function interleave(pieces, build)
  local inlines = {}
  for i, piece in ipairs(pieces) do
    if i > 1 then
      table.insert(inlines, pandoc.RawInline("latex", "\\allowbreak{}"))
    end
    table.insert(inlines, build(piece))
  end
  return inlines
end

function Code(el)
  if not FORMAT:match("latex") then
    return nil
  end

  local pieces = split_into_pieces(el.text, CODE_SEPARATORS, true)
  if not pieces then
    return nil
  end

  -- Reuse the span's classes and attributes but drop its identifier: an id
  -- repeated across the pieces would be a duplicate anchor.
  local attr = pandoc.Attr("", el.attr.classes, el.attr.attributes)
  return interleave(pieces, function(piece)
    return pandoc.Code(piece, attr)
  end)
end

function Str(el)
  if not FORMAT:match("latex") then
    return nil
  end

  -- A run written `name/description/model` puts each separator in a Str of its
  -- own between the code spans, so the break has to go AFTER this element
  -- rather than inside it. Such a Str is below the length gate but is exactly
  -- where the line wants to wrap.
  if el.text:match("^" .. PROSE_SEPARATORS_CLASS .. "+$") then
    return { el, pandoc.RawInline("latex", "\\allowbreak{}") }
  end

  if #el.text < PROSE_MIN_LENGTH then
    return nil
  end

  local pieces = split_into_pieces(el.text, PROSE_SEPARATORS, false)
  if not pieces then
    return nil
  end

  return interleave(pieces, pandoc.Str)
end
