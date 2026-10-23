-- clingo_lsp.lua — real in-process LSP server for Clingo/ASP.
-- Runs via vim.lsp.start with `cmd` as a function (nvim 0.10+); no external
-- LSP binary. Diagnostics come from tree-sitter + `clingo --text` subprocess
-- and are pushed via textDocument/publishDiagnostics.

local M = {}

local timers = {}

local DIRECTIVES = {
  { label = "#show", snippet = "show ${1:p/n}.\n$0", doc = "Show atoms/terms in output" },
  { label = "#const", snippet = "const ${1:c} = ${2:t}.\n$0", doc = "Define constant" },
  { label = "#external", snippet = "external ${1:A}.\n$0", doc = "Declare external atom" },
  { label = "#program", snippet = "program ${1:p}.\n$0", doc = "Begin program part" },
  { label = "#include", snippet = 'include "${1:file}".\n$0', doc = "Include file" },
  { label = "#minimize", snippet = "minimize{${1:w}@${2:p},${3:t} : ${4:L}}.\n$0", doc = "Minimization constraint" },
  { label = "#maximize", snippet = "maximize{${1:w}@${2:p},${3:t} : ${4:L}}.\n$0", doc = "Maximization constraint" },
  { label = "#edge", snippet = "edge(${1:u},${2:v}).\n$0", doc = "Edge directive" },
  { label = "#heuristic", snippet = "heuristic ${1:A} : ${2:B}. [${3:w}@${4:p},${5:m}]$0", doc = "Domain-specific heuristic" },
  { label = "#project", snippet = "project ${1:p/n}.\n$0", doc = "Project atoms" },
  { label = "#defined", snippet = "defined ${1:p/n}.\n$0", doc = "Mark predicate as externally defined" },
  { label = "#script", snippet = "script ${1:python}\n$0\n#end.", doc = "Embedded script block" },
  { label = "#theory", snippet = "theory ${1:t} {\n$0\n}.\n", doc = "Theory atom specification" },
}

local BUILTINS = {
  { label = "#count", snippet = "count{${1:t} : ${2:L}}$0", doc = "Count aggregate" },
  { label = "#sum", snippet = "sum{${1:w},${2:t} : ${3:L}}$0", doc = "Sum aggregate" },
  { label = "#sum+", snippet = "sum+{${1:w},${2:t} : ${3:L}}$0", doc = "Sum positive aggregate" },
  { label = "#min", snippet = "min{${1:w},${2:t} : ${3:L}}$0", doc = "Min aggregate" },
  { label = "#max", snippet = "max{${1:w},${2:t} : ${3:L}}$0", doc = "Max aggregate" },
  { label = "#inf", snippet = "inf$0", doc = "Infimum constant" },
  { label = "#sup", snippet = "sup$0", doc = "Supremum constant" },
  { label = "#true", snippet = "true$0", doc = "Boolean true" },
  { label = "#false", snippet = "false$0", doc = "Boolean false" },
  { label = "not", snippet = "not $0", doc = "Default negation" },
}

-------------------------------------------------------------------------------
-- Tree-sitter helpers
-------------------------------------------------------------------------------

local function has_clingo()
  return vim.fn.executable("clingo") == 1
end

local function get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "clingo")
  if not ok then return nil end
  parser:parse()
  return parser
end

local function get_arity(symbolic_atom_node)
  local arity = 0
  local args = symbolic_atom_node:field("arguments")
  if args then
    for _, terms_node in ipairs(args) do
      arity = arity + terms_node:named_child_count()
    end
  end
  return arity
end

local function get_field_node(node, field_name)
  local fields = node:field(field_name)
  if fields and fields[1] then
    return fields[1]
  end
  return nil
end

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

local function parse_clingo_stderr(stderr)
  local diags = {}
  local pattern = "^(.-):(%d+):(%d+)-(%d+):%s*(%a+):%s*(.+)$"
  for line in stderr:gmatch("[^\n]+") do
    local _, lineno, scol, ecol, severity, msg = line:match(pattern)
    if lineno then
      local l = tonumber(lineno) - 1
      local sc = tonumber(scol) - 1
      local ec = tonumber(ecol) - 1
      local sev
      if severity == "error" then
        sev = vim.diagnostic.severity.ERROR
      elseif severity == "warning" then
        sev = vim.diagnostic.severity.WARN
      else
        sev = vim.diagnostic.severity.INFO
      end
      table.insert(diags, {
        lnum = l, col = sc, end_lnum = l, end_col = ec,
        severity = sev, message = msg, source = "clingo",
      })
    end
  end
  return diags
end

local function walk_ts_errors(node, diags)
  if not node:has_error() then return end
  -- Comments are freeform text; grammar ERROR nodes inside them are grammar
  -- limitations (e.g. Args: sections in %*! doc blocks), not user syntax errors.
  local t = node:type()
  if t == "doc_comment" or t == "line_comment" or t == "block_comment" then return end
  if node:type() == "ERROR" then
    local sr, sc, er, ec = node:range()
    table.insert(diags, {
      lnum = sr, col = sc, end_lnum = er, end_col = ec,
      severity = vim.diagnostic.severity.ERROR,
      message = "syntax error", source = "tree-sitter",
    })
  elseif node:missing() then
    local sr, sc, er, ec = node:range()
    table.insert(diags, {
      lnum = sr, col = sc, end_lnum = er, end_col = ec,
      severity = vim.diagnostic.severity.ERROR,
      message = "expected: " .. node:type(), source = "tree-sitter",
    })
  end
  for i = 0, node:named_child_count() - 1 do
    walk_ts_errors(node:named_child(i), diags)
  end
end

local function ts_diagnostics(bufnr)
  local parser = get_parser(bufnr)
  if not parser then return {} end
  local root = parser:trees()[1]:root()
  local diags = {}
  walk_ts_errors(root, diags)
  return diags
end

-- publish: function(diags) receiving vim-style diagnostic list
local function run_clingo(bufnr, publish)
  if not has_clingo() or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(table.concat(lines, "\n"))
  f:close()
  vim.system({ "clingo", "--text", tmp }, { stdout = false, stderr = true }, function(obj)
    os.remove(tmp)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      local clingo_diags = parse_clingo_stderr(obj.stderr or "")
      -- Re-fetch TS diags now (buffer may have changed since spawn).
      local merged = ts_diagnostics(bufnr)
      for _, d in ipairs(clingo_diags) do table.insert(merged, d) end
      publish(merged)
    end)
  end)
end

local function debounce_diagnostics(bufnr, publish)
  if timers[bufnr] then
    timers[bufnr]:stop()
    timers[bufnr]:close()
  end
  timers[bufnr] = vim.uv.new_timer()
  timers[bufnr]:start(300, 0, vim.schedule_wrap(function()
    if timers[bufnr] then timers[bufnr]:close() end
    timers[bufnr] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local diags = ts_diagnostics(bufnr)
    publish(diags)
    if has_clingo() then
      run_clingo(bufnr, publish)
    end
  end))
end

local function stop_diagnostics(bufnr)
  if timers[bufnr] then
    timers[bufnr]:stop()
    timers[bufnr]:close()
    timers[bufnr] = nil
  end
end

-------------------------------------------------------------------------------
-- Language model
-------------------------------------------------------------------------------

local function get_predicates(bufnr)
  local parser = get_parser(bufnr)
  if not parser then return {} end
  local root = parser:trees()[1]:root()
  local preds = {}
  local seen = {}
  local ok, query = pcall(vim.treesitter.query.parse, "clingo", [[
    (symbolic_atom name: (identifier) @name)
  ]])
  if not ok then return {} end
  for _, node in query:iter_captures(root, bufnr) do
    local name = vim.treesitter.get_node_text(node, bufnr)
    local parent = node:parent()
    if parent and parent:type() == "symbolic_atom" then
      local arity = get_arity(parent)
      local key = name .. "/" .. arity
      if not seen[key] then
        seen[key] = true
        table.insert(preds, { name = name, arity = arity })
      end
    end
  end
  return preds
end

local function get_variables(bufnr, row)
  local parser = get_parser(bufnr)
  if not parser then return {} end
  local root = parser:trees()[1]:root()
  local node = root:descendant_for_range(row, 0, row, 999)
  if not node then return {} end
  while node and node:parent() and node:type() ~= "rule" and node:type() ~= "weak_constraint" and node:type() ~= "integrity_constraint" do
    node = node:parent()
  end
  if not node then return {} end
  local vars = {}
  local seen = {}
  local ok, query = pcall(vim.treesitter.query.parse, "clingo", [[
    (variable) @var
  ]])
  if not ok then return {} end
  for _, var_node in query:iter_captures(node, bufnr) do
    local name = vim.treesitter.get_node_text(var_node, bufnr)
    if not seen[name] then
      seen[name] = true
      table.insert(vars, name)
    end
  end
  return vars
end

local function get_doc_comments(bufnr)
  local parser = get_parser(bufnr)
  if not parser then return {} end
  local root = parser:trees()[1]:root()
  local docs = {}

  -- %*! block doc comments (Potassco official format) — highest precedence.
  -- Format: %*!\n predicate(Var1, Var2)\n Description.\n\n Args:\n  Var1: desc\n *%
  local ok_dc, dc_query = pcall(vim.treesitter.query.parse, "clingo", [[
    (doc_comment) @doc
  ]])
  if ok_dc then
    for _, node in dc_query:iter_captures(root, bufnr) do
      local raw = vim.treesitter.get_node_text(node, bufnr)
      -- Strip %*! wrapper and *% closer
      local body = raw:gsub("^%%%*!%s*\n", ""):gsub("\n%s*%%%*%%%s*$", "")
      -- First line = predicate signature; extract name from raw text because
      -- tree-sitter's doc_predicate mis-parses compound-term arguments
      -- (e.g. died(month(M)) grabs "month" instead of "died").
      local sig = body:match("^([^\n]*)") or ""
      local name = sig:match("^%s*(%a[%w_]*)")
      if name then
        -- Skip first line (predicate signature)
        local nl = body:find("\n")
        local rest = nl and body:sub(nl + 1) or ""
        -- Split description from Args: section
        local desc, args_text = rest, ""
        local s, e = rest:find("\n%s*Args:%s*\n")
        if s then
          desc = rest:sub(1, s - 1)
          args_text = rest:sub(e + 1)
        end
        desc = desc:gsub("^%s+", ""):gsub("%s+$", "")
        local args = {}
        for arg_line in args_text:gmatch("[^\n]+") do
          local an, ad = arg_line:match("^%s*(%a[%w_]*)%s*:%s*(.*)$")
          if an then table.insert(args, { name = an, desc = ad or "" }) end
        end
        docs[name] = { description = desc, args = args }
      end
    end
  end

  -- %! line doc comments
  local ok, query = pcall(vim.treesitter.query.parse, "clingo", [[
    (line_comment) @comment
  ]])
  if not ok then return docs end
  local current_pred = nil
  for _, node in query:iter_captures(root, bufnr) do
    local text = vim.treesitter.get_node_text(node, bufnr)
    local doc_line = text:match("^%%!%s*(.*)$")
    if doc_line then
      local name, desc = doc_line:match("^(%a[%w_]*)%s*:%s*(.*)$")
      if name and name:match("^%u") then
        if current_pred and docs[current_pred] then
          table.insert(docs[current_pred].args, { name = name, desc = desc })
        end
      elseif name and not docs[name] then
        current_pred = name
        docs[name] = { description = desc, args = {} }
      end
    else
      current_pred = nil
    end
  end
  -- Trailing comments: `fact(...). % description` documents the head predicate.
  -- In the tree these are line_comment siblings following a rule on the same row.
  -- A comment on its own line directly above a rule also documents it,
  -- unless it looks like a section separator (% --- x ---, % ====).
  for i = 0, root:named_child_count() - 2 do
    local node = root:named_child(i)
    if node:type() == "rule" then
      local head = get_field_node(node, "head")
      local name_node = head and (function()
        local atom = get_field_node(head, "atom")
        if atom then return get_field_node(atom, "name") end
        -- choice/aggregate heads: use first symbolic_atom descendant
        local function find_atom(n)
          if n:type() == "symbolic_atom" then return n end
          for j = 0, n:named_child_count() - 1 do
            local f = find_atom(n:named_child(j))
            if f then return f end
          end
        end
        local sym = find_atom(head)
        return sym and get_field_node(sym, "name")
      end)()
      if name_node then
        local name = vim.treesitter.get_node_text(name_node, bufnr)
        local srow, _, erow = node:range()
        if not docs[name] then
          local sib = root:named_child(i + 1)
          if sib and sib:type() == "line_comment" then
            local crow = sib:range()
            if crow == erow then
              local desc = vim.treesitter.get_node_text(sib, bufnr):match("^%%%s*(.*)$") or ""
              docs[name] = { description = desc, args = {} }
            end
          end
        end
        if not docs[name] and i > 0 then
          local prev = root:named_child(i - 1)
          if prev:type() == "line_comment" then
            local pcrow, _, pcerow = prev:range()
            if pcrow == pcerow and pcerow == srow - 1 then
              local desc = vim.treesitter.get_node_text(prev, bufnr):match("^%%%s*(.*)$") or ""
              if desc ~= "" and not desc:match("^%-") and not desc:match("^=") then
                docs[name] = { description = desc, args = {} }
              end
            end
          end
        end
      end
    end
  end
  return docs
end

local function find_predicate_ref(bufnr, row, col)
  local parser = get_parser(bufnr)
  if not parser then return nil end
  local root = parser:trees()[1]:root()
  local node = root:descendant_for_range(row, col, row, col)
  while node and node:type() ~= "symbolic_atom" and node:type() ~= "signature" do
    node = node:parent()
  end
  if not node then return nil end
  local name_node = get_field_node(node, "name")
  if not name_node then return nil end
  local name = vim.treesitter.get_node_text(name_node, bufnr)
  local arity
  if node:type() == "signature" then
    local arity_node = get_field_node(node, "arity")
    arity = arity_node and tonumber(vim.treesitter.get_node_text(arity_node, bufnr)) or 0
  else
    arity = get_arity(node)
  end
  return { name = name, arity = arity }
end

local function hover_markdown(bufnr, ref)
  local docs = get_doc_comments(bufnr)
  local doc = docs[ref.name]
  local lines = { "**" .. ref.name .. "/" .. ref.arity .. "**", "" }
  if doc then
    if doc.description and doc.description ~= "" then
      for line in doc.description:gmatch("[^\n]+") do
        table.insert(lines, line)
      end
    end
    if #doc.args > 0 then
      table.insert(lines, "")
      table.insert(lines, "Parameters:")
      for _, arg in ipairs(doc.args) do
        local line = "- `" .. arg.name .. "`"
        if arg.desc and arg.desc ~= "" then
          line = line .. ": " .. arg.desc
        end
        table.insert(lines, line)
      end
    end
  else
    table.insert(lines, "No documentation available.")
  end
  return table.concat(lines, "\n")
end

local function range_of(node)
  local sr, sc, er, ec = node:range()
  return { start = { line = sr, character = sc }, ["end"] = { line = er, character = ec } }
end

local function definition_locations(bufnr, ref, uri)
  local parser = get_parser(bufnr)
  if not parser then return {} end
  local root = parser:trees()[1]:root()
  local ok, query = pcall(vim.treesitter.query.parse, "clingo", [[
    (rule head: (literal atom: (symbolic_atom name: (identifier) @head_name)))
  ]])
  if not ok then return {} end
  local locs = {}
  for _, head_node in query:iter_captures(root, bufnr) do
    if vim.treesitter.get_node_text(head_node, bufnr) == ref.name then
      local atom = head_node:parent()
      if atom and atom:type() == "symbolic_atom" and get_arity(atom) == ref.arity then
        table.insert(locs, { uri = uri, range = range_of(head_node) })
      end
    end
  end
  return locs
end

local function reference_locations(bufnr, ref, uri, include_declaration)
  local parser = get_parser(bufnr)
  if not parser then return {} end
  local root = parser:trees()[1]:root()
  local ok, query = pcall(vim.treesitter.query.parse, "clingo", [[
    [
      (symbolic_atom name: (identifier) @ref_name)
      (signature name: (identifier) @ref_name)
    ]
  ]])
  if not ok then return {} end
  local def_heads = {}
  if not include_declaration then
    for _, loc in ipairs(definition_locations(bufnr, ref, uri)) do
      def_heads[loc.range.start.line .. ":" .. loc.range.start.character] = true
    end
  end
  local locs = {}
  for _, node in query:iter_captures(root, bufnr) do
    local parent = node:parent()
    if parent then
      local arity
      if parent:type() == "signature" then
        local arity_node = get_field_node(parent, "arity")
        arity = arity_node and tonumber(vim.treesitter.get_node_text(arity_node, bufnr)) or 0
      else
        arity = get_arity(parent)
      end
      if vim.treesitter.get_node_text(node, bufnr) == ref.name and arity == ref.arity then
        local range = range_of(node)
        if include_declaration or not def_heads[range.start.line .. ":" .. range.start.character] then
          table.insert(locs, { uri = uri, range = range })
        end
      end
    end
  end
  return locs
end

local function get_completion_items(bufnr, base, row)
  local items = {}
  if base:match("^#") then
    for _, kw in ipairs(DIRECTIVES) do
      if kw.label:find(base, 1, true) then
        table.insert(items, {
          label = kw.label,
          insertText = kw.snippet,
          insertTextFormat = 2,
          kind = 14,
          detail = kw.doc,
        })
      end
    end
    for _, kw in ipairs(BUILTINS) do
      if kw.label:find(base, 1, true) then
        table.insert(items, {
          label = kw.label,
          insertText = kw.snippet,
          insertTextFormat = 2,
          kind = 14,
          detail = kw.doc,
        })
      end
    end
  end
  for _, pred in ipairs(get_predicates(bufnr)) do
    if pred.name:find(base, 1, true) then
      local args = {}
      for i = 1, pred.arity do
        table.insert(args, "${" .. i .. ":arg" .. i .. "}")
      end
      table.insert(items, {
        label = pred.name,
        insertText = pred.name .. "(" .. table.concat(args, ", ") .. ")$0",
        insertTextFormat = 2,
        kind = 3,
        detail = pred.name .. "/" .. pred.arity,
      })
    end
  end
  for _, var in ipairs(get_variables(bufnr, row)) do
    if var:find(base, 1, true) then
      table.insert(items, {
        label = var,
        kind = 6,
        detail = "variable",
      })
    end
  end
  return items
end

local function to_lsp_diagnostic(d)
  return {
    range = {
      start = { line = d.lnum, character = d.col },
      ["end"] = { line = d.end_lnum, character = d.end_col },
    },
    severity = d.severity, -- vim.diagnostic.severity matches LSP numbering 1..4
    source = d.source,
    message = d.message,
  }
end

-------------------------------------------------------------------------------
-- In-process LSP server
-------------------------------------------------------------------------------

local function make_server(dispatchers)
  local closing = false
  local pending = 0
  local handlers = {}

  local function publish_for(bufnr)
    return function(diags)
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      local lsp_diags = {}
      for _, d in ipairs(diags) do
        table.insert(lsp_diags, to_lsp_diagnostic(d))
      end
      dispatchers.notification("textDocument/publishDiagnostics", {
        uri = vim.uri_from_bufnr(bufnr),
        diagnostics = lsp_diags,
      })
    end
  end

  handlers["initialize"] = function(_, cb)
    cb(nil, {
      capabilities = {
        hoverProvider = true,
        definitionProvider = true,
        referencesProvider = true,
        completionProvider = { triggerCharacters = { "#" }, resolveProvider = false },
        textDocumentSync = { openClose = true, change = 1, save = false },
      },
      serverInfo = { name = "clingo-lsp" },
    })
  end

  handlers["initialized"] = function(_, cb) if cb then cb(nil, nil) end end
  handlers["shutdown"] = function(_, cb) cb(nil, nil) end

  handlers["textDocument/didOpen"] = function(params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    debounce_diagnostics(bufnr, publish_for(bufnr))
  end

  handlers["textDocument/didChange"] = function(params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    debounce_diagnostics(bufnr, publish_for(bufnr))
  end

  handlers["textDocument/didClose"] = function(params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    stop_diagnostics(bufnr)
    publish_for(bufnr)({})
  end

  handlers["textDocument/hover"] = function(params, cb)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local pos = params.position
    local ref = find_predicate_ref(bufnr, pos.line, pos.character)
    if not ref then cb(nil, nil) return end
    cb(nil, { contents = { kind = "markdown", value = hover_markdown(bufnr, ref) } })
  end

  handlers["textDocument/definition"] = function(params, cb)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local pos = params.position
    local ref = find_predicate_ref(bufnr, pos.line, pos.character)
    if not ref then cb(nil, nil) return end
    local locs = definition_locations(bufnr, ref, params.textDocument.uri)
    if #locs == 0 then cb(nil, nil) return end
    cb(nil, locs)
  end

  handlers["textDocument/references"] = function(params, cb)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local pos = params.position
    local ref = find_predicate_ref(bufnr, pos.line, pos.character)
    if not ref then cb(nil, nil) return end
    local include_decl = not params.context or params.context.includeDeclaration ~= false
    local locs = reference_locations(bufnr, ref, params.textDocument.uri, include_decl)
    cb(nil, locs)
  end

  handlers["textDocument/completion"] = function(params, cb)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local pos = params.position
    local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
    local base = line:sub(1, pos.character):match("[%w_#]*$") or ""
    cb(nil, { isIncomplete = false, items = get_completion_items(bufnr, base, pos.line) })
  end

  local srv = {}

  function srv.request(method, params, callback)
    local h = handlers[method]
    if h then
      local ok, err = pcall(h, params, callback)
      if not ok then
        pending = pending - 1
        callback({ code = -32603, message = tostring(err) }, nil)
        return false, pending
      end
    else
      callback({ code = -32601, message = "method not found: " .. method }, nil)
    end
    return true, pending
  end

  function srv.notify(method, params)
    local h = handlers[method]
    if h then pcall(h, params) end
    return true
  end

  function srv.is_closing() return closing end
  function srv.terminate() closing = true end

  return srv
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function M.setup(bufnr)
  vim.lsp.start({
    name = "clingo",
    cmd = make_server,
    root_dir = vim.fs.root(bufnr, ".git") or vim.uv.cwd(),
  }, {
    bufnr = bufnr,
    reuse_client = function(client, _)
      return client.name == "clingo"
    end,
  })
end

-- Exported for tests
M._get_predicates = get_predicates
M._get_doc_comments = get_doc_comments
M._make_server = make_server
M._find_predicate_ref = find_predicate_ref

return M
