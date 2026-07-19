local log = require("issuehub.util.log")

describe("log.redact", function()
  it("strips bearer tokens", function()
    local out = log.redact('header = "Authorization: Bearer abc123XYZ"')
    assert.is_nil(out:find("abc123XYZ", 1, true))
    assert.truthy(out:find("<redacted>", 1, true))
  end)

  it("strips basic credentials but keeps the user visible", function()
    local out = log.redact('user = "me@example.com:s3cretToken"')
    assert.is_nil(out:find("s3cretToken", 1, true))
    assert.truthy(out:find("me@example.com", 1, true))
  end)

  it("strips token-shaped key/value pairs", function()
    assert.is_nil(log.redact('token: "abc123"'):find("abc123", 1, true))
    assert.is_nil(log.redact("api_key=abc123"):find("abc123", 1, true))
  end)

  it("leaves ordinary text alone", function()
    assert.equals("GET https://example.com/rest/api/3/issue/PROJ-1", log.redact("GET https://example.com/rest/api/3/issue/PROJ-1"))
  end)
end)
