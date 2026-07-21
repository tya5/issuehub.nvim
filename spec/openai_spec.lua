local config = require("issuehub.config")

---A fake curl transport: records the request, replays a canned response.
local function fake_http(response)
  local captured = {}
  return captured,
    {
      request = function(req, cb)
        captured.req = req
        local body = response.body or { choices = { { message = { content = "ok" } } } }
        cb(response.err, {
          status = response.status or 200,
          body = vim.json.encode(body),
          json = function()
            return body
          end,
        })
      end,
    }
end

local function backend_with(opts, response)
  config.setup({ workspace = vim.fn.tempname(), backend = "openai", backends = { openai = opts } })
  local b = require("issuehub.backend.openai").new("openai")
  local captured, http = fake_http(response or {})
  b.http = http
  assert(b:setup(opts))
  return b, captured
end

local REQ = {
  kind = "analyze",
  resource = "jira://PROJ-1",
  prompt = "Summarise.",
  context = { issue = { id = "PROJ-1", title = "Timeout", status = { name = "Open" }, description = "slow" } },
}

describe("openai backend: setup", function()
  it("requires url and model", function()
    local b = require("issuehub.backend.openai").new("openai")
    assert.is_false((b:setup({ model = "m" })))
    assert.is_false((b:setup({ url = "http://x/v1" })))
    assert.is_true((b:setup({ url = "http://x/v1", model = "m" })))
  end)

  it("accepts either the /v1 base or the full endpoint", function()
    local b = require("issuehub.backend.openai").new("openai")
    b:setup({ url = "http://x/v1/", model = "m" })
    assert.equals("http://x/v1/chat/completions", b.endpoint)
    b:setup({ url = "http://x/v1/chat/completions", model = "m" })
    assert.equals("http://x/v1/chat/completions", b.endpoint)
  end)

  it("is rejected at config time without url and model", function()
    local errors = config.setup({ workspace = vim.fn.tempname(), backend = "openai", backends = { openai = {} } })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("requires backends.openai.url")
    end))
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("requires backends.openai.model")
    end))
  end)
end)

describe("openai backend: request shape", function()
  it("sends the model, a user message built from the request, and no null knobs", function()
    local b, cap = backend_with({ url = "http://x/v1", model = "gpt-4o-mini" })
    b:send(REQ, {}, function() end)

    assert.equals("gpt-4o-mini", cap.req.body.model)
    assert.is_false(cap.req.body.stream)
    -- The shared renderer's task section must be present in the user turn.
    local user = cap.req.body.messages[#cap.req.body.messages]
    assert.equals("user", user.role)
    assert.truthy(user.content:find("## Task", 1, true))
    assert.truthy(user.content:find("Summarise.", 1, true))
    -- Unset tuning knobs are omitted, not sent as null, so a strict endpoint
    -- does not reject them.
    assert.is_nil(cap.req.body.temperature)
    assert.is_nil(cap.req.body.max_tokens)
  end)

  it("adds a system message from config", function()
    local b, cap = backend_with({ url = "http://x/v1", model = "m", system = "Be terse." })
    b:send(REQ, {}, function() end)
    assert.equals("system", cap.req.body.messages[1].role)
    assert.equals("Be terse.", cap.req.body.messages[1].content)
  end)

  it("lets metadata carry a per-request system prompt", function()
    local b, cap = backend_with({ url = "http://x/v1", model = "m" })
    b:send(vim.tbl_extend("force", REQ, { metadata = { system = "One line only." } }), {}, function() end)
    assert.equals("One line only.", cap.req.body.messages[1].content)
  end)

  it("puts the api key in the Authorization bearer, never in argv", function()
    vim.env.OAI_SPEC_KEY = "sk-secret"
    local b, cap = backend_with({ url = "http://x/v1", model = "m", token_env = "OAI_SPEC_KEY" })
    b:send(REQ, {}, function() end)
    assert.same({ bearer = "sk-secret" }, cap.req.auth)

    -- ...and it actually lands in the curl config body (stdin), not the command.
    local conf = require("issuehub.util.http")._build_config({ url = "http://x", auth = cap.req.auth })
    assert.truthy(conf:find("Authorization: Bearer sk-secret", 1, true))
  end)

  it("uses a named key header and query passthrough for Azure-style gateways", function()
    vim.env.OAI_SPEC_KEY = "azkey"
    local b, cap = backend_with({
      url = "http://azure/openai/deployments/x",
      model = "m",
      token_env = "OAI_SPEC_KEY",
      api_key_header = "api-key",
      query = { ["api-version"] = "2024-02-01" },
    })
    b:send(REQ, {}, function() end)
    assert.equals("azkey", cap.req.headers["api-key"])
    assert.is_nil(cap.req.auth) -- not bearer in this mode
    assert.equals("2024-02-01", cap.req.query["api-version"])
  end)

  it("sends nothing but model, messages, and stream by default (GPT-5 safe)", function()
    -- Reasoning models reject a non-default temperature and the old max_tokens;
    -- the default request must carry neither.
    local b, cap = backend_with({ url = "http://x/v1", model = "gpt-5.6" })
    b:send(REQ, {}, function() end)
    assert.same({ "messages", "model", "stream" }, (function()
      local keys = vim.tbl_keys(cap.req.body)
      table.sort(keys)
      return keys
    end)())
  end)

  it("uses max_completion_tokens and drops the legacy max_tokens", function()
    local b, cap = backend_with({ url = "http://x/v1", model = "gpt-5.6", max_completion_tokens = 4000 })
    b:send(REQ, {}, function() end)
    assert.equals(4000, cap.req.body.max_completion_tokens)
    assert.is_nil(cap.req.body.max_tokens)
  end)

  it("still sends legacy max_tokens for an older endpoint that wants it", function()
    local b, cap = backend_with({ url = "http://x/v1", model = "gpt-4o-mini", max_tokens = 500 })
    b:send(REQ, {}, function() end)
    assert.equals(500, cap.req.body.max_tokens)
    assert.is_nil(cap.req.body.max_completion_tokens)
  end)

  it("lets metadata override the model per request", function()
    local b, cap = backend_with({ url = "http://x/v1", model = "default-model" })
    b:send(vim.tbl_extend("force", REQ, { metadata = { model = "override" } }), {}, function() end)
    assert.equals("override", cap.req.body.model)
  end)
end)

describe("openai backend: responses", function()
  it("returns the message content and the model", function()
    local b = backend_with({ url = "http://x/v1", model = "m" }, {
      body = { model = "gpt-4o-mini", choices = { { message = { content = "the answer" } } } },
    })
    local out
    b:send(REQ, {}, function(err, res)
      out = { err = err, res = res }
    end)
    assert.is_nil(out.err)
    assert.equals("the answer", out.res.text)
    assert.equals("gpt-4o-mini", out.res.model)
  end)

  it("delivers the whole reply as one chunk for streaming callers", function()
    local b = backend_with({ url = "http://x/v1", model = "m" }, {
      body = { choices = { { message = { content = "whole reply" } } } },
    })
    local chunks = {}
    b:send(REQ, { on_chunk = function(c)
      chunks[#chunks + 1] = c
    end }, function() end)
    assert.same({ "whole reply" }, chunks)
  end)

  it("surfaces an OpenAI error object rather than a bare status", function()
    local b = backend_with({ url = "http://x/v1", model = "m" }, {
      err = "HTTP 400",
      status = 400,
      body = { error = { message = "model not found", code = "model_not_found" } },
    })
    local out
    b:send(REQ, {}, function(err)
      out = err
    end)
    assert.truthy(out:find("model not found", 1, true))
  end)

  it("reports missing content clearly", function()
    local b = backend_with({ url = "http://x/v1", model = "m" }, { body = { choices = {} } })
    local out
    b:send(REQ, {}, function(err)
      out = err
    end)
    assert.truthy(out:find("no message content", 1, true))
  end)
end)

describe("openai backend: capabilities and health", function()
  it("advertises all three kinds so translate is one action", function()
    local b = backend_with({ url = "http://x/v1", model = "m" })
    local kinds = b:capabilities().kinds
    for _, k in ipairs({ "analyze", "complete", "translate" }) do
      assert.is_true(vim.tbl_contains(kinds, k))
    end
  end)

  it("reports the key resolved without revealing it", function()
    vim.env.OAI_SPEC_KEY = "sk-do-not-print"
    local b = backend_with({ url = "http://x/v1", model = "gpt", token_env = "OAI_SPEC_KEY" })
    local ok, msg = b:health()
    assert.is_true(ok)
    assert.truthy(msg:find("key resolved", 1, true))
    assert.is_nil(msg:find("sk-do-not-print", 1, true))
  end)
end)
