package main

import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import http "../vendor/odin-http"
import http_client "../vendor/odin-http/client"

OPEN_AI_API_URL :: "https://api.openai.com/v1"

FILE_TEMPL :: `        %s:
            - status: %s
            - changes +%d/-%d
            - patch: %s
`
COMMIT_TEMPL :: `%s:
    - author: %s
    - message: %s
    - changes: +%d/-%d
    - files:
        %s
`

BLOG_PROMPT_TEMPL :: `You are a technical blog writer. You will be given technical project data (commit history) and based on that you will write a blog post about building this project.

Patch format explanation:
- Added files show the full file content
- Modified files show only changed lines
- Lines starting with - were removed
- Lines starting with + were added
- L<number>: indicates the line number where the change occurs
- Separate L markers within one file mean changes in different parts of the file

Write the blog post with somewhat following structure (you can modifiy the structure however you want if it fits the blog post more):

## Introduction
- What is this project?
- What problem does it solve?

## Tech Stack
- What languages/frameworks/libraries were used and why?

## The Build Process
- Walk through the development chronologically
- Group related commits into phases (e.g. "Setting up the project", "Core logic", "Polish")
- For each phase, explain what was done and why
- Do not reference the commits directly, like "first commit was...", incorporate it naturally

## Interesting Code
- Pick 2-3 interesting snippets from the patches and explain them
- Use code blocks with the correct language

## Challenges
- What was tricky? (look for commits that revert, refactor, or fix things)

## Final Architecture
- How is the codebase structured?
- How do the pieces fit together?

Write as if you're explaining to a fellow developer over coffee. Don't be overly formal. Don't use phrases like "In conclusion" or "It's worth noting". Don't use filler. Be direct. Use the author's note if it was provided to inform the blog post's narrative. Incorporate them naturally — don't just quote them verbatim. Write the blog in first person, as if you are describing your project.

Do NOT:
- Make up information that isn't in the commit data
- Guess at motivation unless it's obvious from the commits
- Use generic filler like "This was a great learning experience"
- Explain basic programming concepts
- Write an introduction that starts with "In today's world..."
- Use phrases like "it's not x, it's y"`

build_blog_prompt :: proc(
	project_name, commits, authors_note: string,
	allocator: mem.Allocator,
) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)

	strings.write_string(&sb, BLOG_PROMPT_TEMPL)
	strings.write_string(&sb, "\nProject name: ")
	strings.write_string(&sb, project_name)
	strings.write_string(&sb, "\n")

	if len(authors_note) > 0 {
		strings.write_string(&sb, "\nAuthor's note: ")
		strings.write_string(&sb, authors_note)
		strings.write_string(&sb, "\n")
	}

	strings.write_string(&sb, "\nCommits:\n")
	strings.write_string(&sb, commits)

	return string(sb.buf[:])
}

README_PROMPT_TEMPL :: `You are a technical writer. You will be given the contents of a project's source files and based on that you will write a README.md for the project.

File format explanation:
- Each file is listed with its path and full content
- Files are in no particular order

Write the README with somewhat following structure (you can modify the structure however you want if it fits the project more):

## Project Title
- Clear, concise project name and one-liner description

## About
- What is this project?
- What problem does it solve?

## Features
- Key features / capabilities of the project

## Tech Stack
- What languages/frameworks/libraries are used?

## Getting Started
- Prerequisites (runtime, tools, etc.)
- Installation steps
- How to run the project
- Environment variables if any (.env, config files)

## Usage
- Basic usage examples
- CLI arguments if applicable
- API endpoints if applicable

## Project Structure
- Brief overview of the directory layout and what each part does

Write clearly and concisely. Target audience is a developer who just found this repo and wants to understand what it does and how to run it in under 2 minutes.

Do NOT:
- Make up information that isn't in the source files
- Invent features that don't exist in the code
- Add badges, contribution guidelines, or license sections unless obvious from the files
- Explain basic programming concepts
- Write marketing fluff

If the author provided notes, use them to inform the README's narrative. Incorporate them naturally — don't just quote them verbatim.`

Readme_File :: struct {
	path: string,
	data: []byte,
}

build_readme_prompt :: proc(
	project_name, authors_note: string,
	files: []Readme_File,
	allocator: mem.Allocator,
) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)

	strings.write_string(&sb, README_PROMPT_TEMPL)
	strings.write_string(&sb, "\n\nProject name: ")
	strings.write_string(&sb, project_name)
	strings.write_string(&sb, "\n")

	if len(authors_note) > 0 {
		strings.write_string(&sb, "\nAuthor's note: ")
		strings.write_string(&sb, authors_note)
		strings.write_string(&sb, "\n")
	}

	strings.write_string(&sb, "\nFiles:\n")
	for file in files {
		strings.write_string(&sb, "--- ")
		strings.write_string(&sb, file.path)
		strings.write_string(&sb, " ---\n")
		strings.write_bytes(&sb, file.data)
		strings.write_string(&sb, "\n")
	}

	return string(sb.buf[:])
}

create_open_ai_request :: proc(
	allocator: mem.Allocator,
	api_key, prompt: string,
) -> (
	req: ^http_client.Request,
	err: json.Marshal_Error,
) {
	req = new(http_client.Request, allocator)
	http_client.request_init(req, .Post, allocator)
	http.headers_set(&req.headers, "content-type", "application/json")
	http.headers_set(
		&req.headers,
		"authorization",
		fmt.aprintf("Bearer %s", api_key, allocator = allocator),
	)

	MODEL :: "gpt-5.1"
	Data :: struct {
		model: string,
		input: string,
	}

	data_json := json.marshal(Data{model = MODEL, input = prompt}, allocator = allocator) or_return
	bytes.buffer_init(&req.body, data_json)

	return
}
