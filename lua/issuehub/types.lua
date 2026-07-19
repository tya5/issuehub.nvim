---@brief LuaCATS type definitions. No runtime code lives here.

---@class issuehub.Status
---@field id string          Provider-stable identifier, e.g. "in_review", "3".
---@field name string        Display label, verbatim from the provider.
---@field closed boolean     The only semantic the core interprets (§4.1).

---@class issuehub.Comment
---@field id string
---@field author string?
---@field body string
---@field created_at string

---@class issuehub.Issue
---@field uri string
---@field provider string
---@field id string
---@field title string
---@field description string
---@field status issuehub.Status
---@field assignee string?
---@field reporter string?
---@field labels string[]
---@field url string?
---@field comments issuehub.Comment[]
---@field created_at string
---@field updated_at string
---@field raw table

---@class issuehub.ViewItem
---@field uri string
---@field id string
---@field title string
---@field status string      status.name, flattened for display
---@field closed boolean     status.closed; the only sortable/filterable semantic
---@field assignee string?
---@field updated_at string
---@field bookmarked boolean

---@class issuehub.View
---@field source string      "query"|"collection"|"find"|"bookmarks"
---@field label string       Human-readable; used in export filenames.
---@field items issuehub.ViewItem[]

---@class issuehub.Provider
---@field name string
---@field setup fun(self, opts: table): boolean, string?
---@field list fun(self, query: any?, cb: fun(err: string?, issues: issuehub.Issue[]?))
---@field get fun(self, id: string, cb: fun(err: string?, issue: issuehub.Issue?))
---@field search fun(self, query: string, cb: fun(err: string?, issues: issuehub.Issue[]?))
---@field health fun(self): boolean, string

---@class issuehub.PickerCaps
---@field preview boolean
---@field multi_select boolean
---@field actions boolean

---@class issuehub.Picker
---@field name string
---@field caps issuehub.PickerCaps
---@field available fun(): boolean
---@field pick fun(view: issuehub.View, opts: table)

---@class issuehub.ProviderConfig
---@field url string
---@field user string?
---@field token_env string?
---@field token_cmd string[]?
---@field token (fun(): string?)?
---@field default_query any?
---@field comment_limit integer?
---@field flavor string?

---@class issuehub.Config
---@field workspace string
---@field index "auto"|"json"|"sqlite"
---@field providers table<string, issuehub.ProviderConfig>
---@field ui issuehub.UIConfig
---@field sync issuehub.SyncConfig
---@field log_level integer

---@class issuehub.UIConfig
---@field picker "auto"|"snacks"|"fzf"|"telescope"|"select"

---@class issuehub.SyncConfig
---@field on_open "always"|"stale"|"never"
---@field stale_after integer

return {}
