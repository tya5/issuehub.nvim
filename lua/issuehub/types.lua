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

---@class issuehub.Attachment
---@field id string          Stable within the issue; also the storage subdirectory.
---@field filename string    As the tracker reports it; sanitised before use as a path.
---@field url string         Where the bytes are; fetched with the provider's own auth.
---@field size integer?      nil when the tracker does not say (a parsed link).
---@field mime string?
---@field author string?
---@field created_at string?

---@class issuehub.Issue
---@field uri string
---@field provider string
---@field project string?   The tracker's own grouping: Jira project key,
---                         Redmine identifier, GitHub/GitLab repository.
---@field id string
---@field title string
---@field description string
---@field status issuehub.Status
---@field assignee string?
---@field reporter string?
---@field labels string[]
---@field url string?
---@field comments issuehub.Comment[]
---@field attachments issuehub.Attachment[]
---@field created_at string
---@field updated_at string
---@field closed_at string?    When it was resolved; nil while open.
---@field raw table

---@class issuehub.ViewItem
---@field uri string
---@field id string
---@field project string?
---@field title string
---@field status string      status.name, flattened for display
---@field closed boolean     status.closed; the only sortable/filterable semantic
---@field assignee string?
---@field updated_at string
---@field bookmarked boolean
---@field seen_at string?    The issue's updated_at when the user last opened it.
---@field matched_in string?  Which fields a local search matched, if any.
---@field notes string?      Memo and metadata text, matched but not displayed.

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
---Optional. Returns the HTTP request that fetches one attachment's bytes,
---including this instance's auth. A provider without it reports no attachments.
---@field attachment_request (fun(self, att: issuehub.Attachment): issuehub.HttpRequest?, string?)?

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
---@field type string?         Implementation to use; defaults to the config key.
---@field url string?          Required for jira/redmine; defaults for github/gitlab
---@field web_url string?      GitHub Enterprise: browser host, if it differs from the API host
---@field user string?
---@field token_env string?
---@field token_cmd string[]?
---@field token (fun(): string?)?
---@field default_query any?
---@field projects string[]?   Restrict this instance to these projects.
---@field default_project string?
---@field comment_limit integer?
---@field max_results integer?  Results to page through; defaults to one page.
---@field per_page integer?     Page size, capped at 100 by every provider.
---@field flavor string?
---@field http issuehub.HttpConfig?   Per-provider proxy/TLS overrides

---@class issuehub.Config
---@field workspace string
---@field index "auto"|"json"|"sqlite"
---@field providers table<string, issuehub.ProviderConfig>
---@field ui issuehub.UIConfig
---@field sync issuehub.SyncConfig
---@field export issuehub.ExportConfig
---@field translate issuehub.TranslateConfig
---@field backend string
---@field backends table<string, table>
---@field http issuehub.HttpConfig
---@field log_level integer

---@class issuehub.HttpConfig
---@field proxy string?                    "http://proxy.corp.example:8080"
---@field no_proxy string?                 "localhost,.internal.example"
---@field proxy_user string?
---@field proxy_password (string|fun():string?)?
---@field proxy_password_env string?
---@field proxy_password_cmd string[]?
---@field proxy_auth "basic"|"digest"|"ntlm"|"negotiate"|"anyauth"|nil
---@field cacert string?                   CA bundle for a corporate root
---@field capath string?
---@field ssl_verify boolean?              Default true; false disables verification
---@field client_cert string?              mTLS
---@field client_key string?
---@field client_key_password_env string?
---@field client_key_password_cmd string[]?
---@field timeout integer?
---@field retries integer?

---@class issuehub.UIConfig
---@field picker "auto"|"snacks"|"fzf"|"telescope"|"select"

---@class issuehub.SyncConfig
---@field on_open "always"|"stale"|"never"
---@field stale_after integer
---@field confirm_above integer   Ask before syncing more than this many issues.

---@class issuehub.ExportConfig
---@field dir string?             Output directory; defaults to the cwd.
---@field default_format string

---@class issuehub.TranslateConfig
---@field default_language string?
---@field languages string[]
---@field include_comments boolean

return {}
