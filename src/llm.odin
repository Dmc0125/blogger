package main

import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"

import http "../vendor/odin-http"
import http_client "../vendor/odin-http/client"

OPEN_AI_API_URL :: "https://api.openai.com/v1"
ANTHROPIC_API_URL :: "https://api.anthropic.com/v1"

OPEN_AI_MODEL :: "gpt-5.4"
ANTHROPIC_AI_MODEL :: "claude-sonnet-4-6"

LLM_Provider :: enum {
	Open_Ai,
	Anthropic,
}

LLM_Provider_Get_Token_Count :: #type proc(
	config: ^LLM_Provider_Config,
	api_key, input: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	token_count: int,
	err: Error,
)

LLM_Provider_Send_Prompt :: #type proc(
	config: ^LLM_Provider_Config,
	api_key, input: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	message: string,
	output_tokens: int,
	err: Error,
)

LLM_Provider_Config :: struct {
	api_url_token_count:    string,
	api_url_create_message: string,
	model:                  string,
	get_token_count:        LLM_Provider_Get_Token_Count,
	send_prompt:            LLM_Provider_Send_Prompt,
}

@(rodata)
llm_providers := [LLM_Provider]LLM_Provider_Config {
	.Open_Ai = {
		api_url_token_count    = OPEN_AI_API_URL + "/responses/input_tokens", //
		api_url_create_message = OPEN_AI_API_URL + "/responses",
		model                  = OPEN_AI_MODEL,
		get_token_count        = open_ai_get_token_count,
		send_prompt            = open_ai_send_prompt,
	},
	.Anthropic = {
		api_url_token_count    = ANTHROPIC_API_URL + "/messages/count_tokens", //
		api_url_create_message = ANTHROPIC_API_URL + "/messages",
		model                  = ANTHROPIC_AI_MODEL,
		get_token_count        = anthropic_get_token_count,
		send_prompt            = anthropic_send_prompt,
	},
}

open_ai_create_request :: proc(
	allocator: mem.Allocator,
	api_key, model, input: string,
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

	Data :: struct {
		model: string,
		input: string,
	}

	data_json := json.marshal(Data{model, input}, allocator = allocator) or_return
	log.infof("%s LLM Request data: %s", LLM_Provider.Open_Ai, string(data_json))
	bytes.buffer_init(&req.body, data_json)

	return
}

open_ai_get_token_count :: proc(
	config: ^LLM_Provider_Config,
	api_key, input: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	token_count: int,
	err: Error,
) {
	req, rerr := open_ai_create_request(temp_allocator, api_key, config.model, input)
	if rerr != nil {
		err = error_new(rerr)
		return
	}

	Input_Tokens_Response :: struct {
		input_tokens: int,
	}
	response: Input_Tokens_Response

	result, herr := http_request(
		req,
		config.api_url_token_count,
		temp_allocator,
		program_allocator,
		&response,
	)
	if herr != nil {
		err = error_new(herr)
		return
	}
	if herr, ok := result.(Http_Request_Err); ok {
		err = error_new(herr)
		return
	}

	token_count = response.input_tokens

	return
}

open_ai_send_prompt :: proc(
	config: ^LLM_Provider_Config,
	api_key, input: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	message: string,
	output_tokens: int,
	err: Error,
) {
	req, rerr := open_ai_create_request(temp_allocator, api_key, config.model, input)
	if rerr != nil {
		err = error_new(rerr)
		return
	}

	Response_Output_Content :: struct {
		type: string,
		text: string,
	}

	Response_Output :: struct {
		type:    string,
		id:      string,
		status:  string,
		role:    string,
		content: []Response_Output_Content,
	}

	Create_Response_Response :: struct {
		output: []Response_Output,
		usage:  struct {
			input_tokens:  int,
			output_tokens: int,
		},
	}

	response: Create_Response_Response

	result, herr := http_request(
		req,
		config.api_url_create_message,
		temp_allocator,
		program_allocator,
		&response,
	)
	if herr != nil {
		err = error_new(herr)
		return
	}
	if herr, ok := result.(Http_Request_Err); ok {
		err = error_new(herr)
		return
	}

	found := false
	outer: for o in response.output {
		for content in o.content {
			if content.type == "output_text" {
				message = content.text
				found = true
				break outer
			}
		}
	}
	if !found {
		err = error_new(nil, "missing output_text in open ai response")
	}

	output_tokens = response.usage.output_tokens

	return
}

anthropic_create_request :: proc(
	allocator: mem.Allocator,
	api_key: string,
) -> (
	req: ^http_client.Request,
) {
	req = new(http_client.Request, allocator)
	http_client.request_init(req, .Post, allocator)
	http.headers_set(&req.headers, "content-type", "application/json")
	http.headers_set(&req.headers, "x-api-key", api_key)
	http.headers_set(&req.headers, "anthropic-version", "2023-06-01")
	return
}

anthropic_get_token_count :: proc(
	config: ^LLM_Provider_Config,
	api_key, input: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	token_count: int,
	err: Error,
) {
	req := anthropic_create_request(temp_allocator, api_key)

	{ 	// req data
		Data :: struct {
			messages: []struct {
				content: string,
				role:    string,
			},
			model:    string,
		}

		data := Data {
			messages = {{content = input, role = "user"}},
			model    = config.model,
		}
		data_json, merr := json.marshal(data, allocator = temp_allocator)
		if merr != nil {
			err = error_new(merr)
			return
		}
		log.infof("%s LLM Request data: %s", LLM_Provider.Anthropic, string(data_json))
		bytes.buffer_init(&req.body, data_json)
	}

	Input_Tokens_Reponse :: struct {
		input_tokens: int,
	}
	response: Input_Tokens_Reponse

	result, herr := http_request(
		req,
		config.api_url_token_count,
		temp_allocator,
		program_allocator,
		&response,
	)
	if herr != nil {
		err = error_new(herr)
		return
	}
	if herr, ok := result.(Http_Request_Err); ok {
		err = error_new(herr)
		return
	}

	token_count = response.input_tokens
	return
}

anthropic_send_prompt :: proc(
	config: ^LLM_Provider_Config,
	api_key, input: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	message: string,
	output_tokens: int,
	err: Error,
) {
	req := anthropic_create_request(temp_allocator, api_key)

	{ 	// req data
		Data :: struct {
			max_tokens: int,
			messages:   []struct {
				content: string,
				role:    string,
			},
			model:      string,
		}

		data := Data {
			max_tokens = 128000,
			messages   = {{content = input, role = "user"}},
			model      = config.model,
		}
		data_json, merr := json.marshal(data, allocator = temp_allocator)
		if merr != nil {
			err = error_new(merr)
			return
		}
		log.infof("%s LLM Request data: %s", LLM_Provider.Anthropic, string(data_json))
		bytes.buffer_init(&req.body, data_json)
	}

	Messages_Content :: struct {
		text: string,
		type: string,
	}

	Messages_Response :: struct {
		content: []Messages_Content,
		usage:   struct {
			output_tokens: int,
		},
	}

	response: Messages_Response

	result, herr := http_request(
		req,
		config.api_url_create_message,
		temp_allocator,
		program_allocator,
		&response,
	)
	if herr != nil {
		err = error_new(herr)
		return
	}
	if herr, ok := result.(Http_Request_Err); ok {
		err = error_new(herr)
		return
	}

	found := false
	for content in response.content {
		if content.type == "text" {
			message = content.text
			found = true
			break
		}
	}
	if !found {
		err = error_new(nil, "missing text content in anthropic response")
	}

	output_tokens = response.usage.output_tokens

	return
}

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
