package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

import http "../vendor/odin-http"
import http_client "../vendor/odin-http/client"

GITHUB_API_URL :: "https://api.github.com"

create_github_request :: proc(
	allocator: mem.Allocator,
	access_token: string,
) -> ^http_client.Request {
	req := new(http_client.Request, allocator)
	http_client.request_init(req, .Get, allocator)
	http.headers_set(
		&req.headers,
		"Authorization",
		fmt.aprintf("Bearer %s", access_token, allocator = allocator),
	)
	http.headers_set(&req.headers, "Accept", "application/vnd.github+json")
	http.headers_set(&req.headers, "X-GitHub-Api-Version", "2026-03-10")
	return req
}

Commit :: struct {
	sha:     string,
	commit:  struct {
		author:  struct {
			name: string,
		},
		message: string,
	},
	parents: []struct {
		sha: string,
	},
}

Commit_File :: struct {
	sha:       string,
	filename:  string,
	status:    string,
	additions: i32,
	deletions: i32,
	changes:   i32,
	raw_url:   string,
	patch:     string,
}

Commit_Details :: struct {
	commit: struct {
		author:  struct {
			name:  string,
			email: string,
			date:  string,
		},
		message: string,
	},
	stats:  struct {
		total:     i32,
		additions: i32,
		deletions: i32,
	},
	files:  []Commit_File,
}

minify_patch :: proc(patch, status: string, allocator: mem.Allocator) -> string {
	if patch == "" || status == "removed" {
		return ""
	}

	patch_lines := strings.split_lines(patch, allocator)
	defer delete(patch_lines, allocator)

	switch status {
	case "added":
		// NOTE: ignore the first line, that's hunk header
		patch_lines_without_header := patch_lines[1:]

		out: strings.Builder
		strings.builder_init(&out, allocator)

		for line, i in patch_lines_without_header {
			strings.write_string(&out, line[1:])
			if i != len(patch_lines_without_header) - 1 {
				strings.write_byte(&out, '\n')
			}
		}
		return string(out.buf[:])
	case "modified", "renamed":
		out: strings.Builder
		strings.builder_init(&out, allocator)

		change_line_start: int
		first_change_line: bool

		for line in patch_lines {
			switch {
			case strings.has_prefix(line, "@@"):
				// hunk header
				n: int
				if change_line_start, _ = strconv.parse_int(line[4:], 10, &n); n == 0 {
					assert(
						false,
						fmt.aprintf(
							"unable to parse int: \"%s\"",
							line[4:],
							allocator = allocator,
						),
					)
				}
				first_change_line = true
			case line[0] == '-', line[0] == '+':
				if first_change_line {
					line_num := fmt.aprintf("L%d:\n", change_line_start, allocator = allocator)
					defer delete(line_num, allocator)
					strings.write_string(&out, line_num)
					first_change_line = false
				}

				if line[0] == '-' {
					change_line_start += 1
				}

				strings.write_string(&out, line)
				strings.write_byte(&out, '\n')
			case:
				// context line
				change_line_start += 1
				first_change_line = true
			}
		}

		out_without_nl := make([]byte, len = len(out.buf) - 1, allocator = allocator)
		copy(out_without_nl, out.buf[:len(out.buf) - 1])
		strings.builder_destroy(&out)

		return string(out_without_nl)
	}

	assert(false, fmt.aprintf("invalid status: %s", status, allocator = allocator))
	return ""
}
