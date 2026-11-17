package lsp

import "../buffer"

// ols JSON-RPC client: completion, diagnostics, go-to-def.
// Owner: Agent F.  Contract: ARCHITECTURE.md §5.9

Diagnostic :: struct { range: buffer.Range, severity: int, message: string }
Completion :: struct { label: string, insert: string, kind: int }

Client :: struct {
	// child process stdio, request-id map, pending callbacks
}

start      :: proc(ols_path: string, root_uri: string) -> (^Client, bool) { return nil, false }
did_open   :: proc(c: ^Client, uri: string, text: string) {}
did_change :: proc(c: ^Client, uri: string, text: string, version: int) {}
request_completion :: proc(c: ^Client, uri: string, at: buffer.Pos) -> []Completion { return {} }
poll       :: proc(c: ^Client) {}
on_diagnostics :: proc(c: ^Client, cb: proc(uri: string, diags: []Diagnostic)) {}
shutdown   :: proc(c: ^Client) {}
