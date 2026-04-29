#+vet explicit-allocators
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

IGNORED_DIRECTORIES :: [?]string{"vendor", "target"}
IGNORED_SUFFIXES :: [?]string {
	// lock files
	".lock",
	".lockb",
	".sum",
	// binaries
	".bin",
	".wasm",
	".dll",
	".so",
	".exe",
	// assets
	".ttf",
	".png",
}
IGNORED_FILENAMES :: [?]string{"package-lock.json"}

PROGRAM_MEMORY: [100 * mem.Megabyte]byte

create_arena :: proc(backing_allocator: mem.Allocator, size: int) -> (allocator: mem.Allocator) {
	arena := new(mem.Arena, backing_allocator)
	data := make([]byte, len = size, allocator = backing_allocator)
	mem.arena_init(arena, data)
	allocator = mem.arena_allocator(arena)
	return
}

Error_Og :: union {
	os.Error,
	mem.Allocator_Error,
	Http_Error,
	Http_Request_Err,
	json.Marshal_Error,
}

error_og_string :: proc(err: Error_Og) -> string {
	if err == nil {
		return "Unknown"
	}

	switch e in err {
	case os.Error:
		return os.error_string(e)
	case mem.Allocator_Error, Http_Error, json.Marshal_Error:
		scratch: [256]byte
		scratch_arena: mem.Arena
		mem.arena_init(&scratch_arena, scratch[:])
		return fmt.aprintf("%s", e, allocator = mem.arena_allocator(&scratch_arena))
	case Http_Request_Err:
		return "Request response status not ok"
	}

	return ""
}

Error :: struct {
	valid: bool,
	loc:   runtime.Source_Code_Location,
	msg:   string,
	og:    Error_Og,
}

error_new :: proc(og: Error_Og, msg := "", loc := #caller_location) -> (err: Error) {
	err.valid = true
	err.loc = loc
	err.msg = msg
	err.og = og
	return
}

error_fatal :: proc(err: ^Error) {
	// print error with this format:
	//
	// Error: <og>
	//  --> <loc>
	//
	// <msg>
	//
	// <details>
	fmt.fprintln(os.stderr, "\n\n\x1b[1;31mError: \x1b[0m", error_og_string(err.og))
	fmt.fprintln(os.stderr, "\x1b[1;36m --> \x1b[0m", err.loc)

	if len(err.msg) > 0 {
		fmt.fprintln(os.stderr)
		fmt.fprintln(os.stderr, err.msg)
	}

	if req_err, ok := err.og.(Http_Request_Err); ok {
		fmt.fprintln(os.stderr)
		fmt.fprintln(os.stderr, "Calling: ", req_err.method, req_err.url)
		fmt.fprintln(os.stderr, "Status: ", req_err.status)
		fmt.fprintln(os.stderr, "Headers: ", req_err.headers)
		fmt.fprintln(os.stderr, "Body: ", req_err.body)
	}

	log_filename_raw := cast(^[]rawptr)context.user_ptr
	log_filename := strings.string_from_ptr(
		cast([^]u8)log_filename_raw[0],
		int(uintptr(log_filename_raw[1])),
	)
	fmt.fprintln(os.stderr, "\nLogs are saved in: ", log_filename)

	os.exit(1)
}

error_fatal_new :: proc(og: Error_Og, msg := "", loc := #caller_location) {
	err := error_new(og, msg, loc)
	error_fatal(&err)
}

generate_readme_prompt :: proc(
	github_owner, github_repo, authors_note: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	prompt: string,
	err: Error,
) {
	defer free_all(temp_allocator)

	// create the temp dir
	tmp_path, tderr := os.make_directory_temp(
		"/tmp",
		fmt.aprintf("%s-%s", github_owner, github_repo, allocator = temp_allocator),
		program_allocator,
	)
	if tderr != nil {
		err = error_new(tderr)
		return
	}
	defer {
		if err := os.remove_all(tmp_path); err != nil {
			fmt.println("unable to remove temp directory: ", err)
		}
	}

	{ 	// clone the repo
		print(.Loading, "Cloning repository")

		git_url := fmt.aprintf(
			"https://github.com/%s/%s.git",
			github_owner,
			github_repo,
			allocator = temp_allocator,
		)
		process_desc := os.Process_Desc {
			working_dir = tmp_path,
			command     = {"git", "clone", "--depth", "1", git_url, "."},
		}
		process_state, _, stderr, perr := os.process_exec(process_desc, temp_allocator)
		if perr != nil {
			err = error_new(perr)
			return
		}
		if !process_state.success {
			msg := fmt.aprintf(
				"process exited without success: %s",
				string(stderr),
				allocator = program_allocator,
			)
			err = error_new(nil, msg)
			return
		}

		print(.Success, "Cloned repository\n", clear_line = true)
	}

	// read repo
	print(.Loading, "Reading files and buildig prompt")

	read_dir :: proc(
		path: string,
		files: ^[dynamic]Readme_File,
		program_allocator, temp_allocator: mem.Allocator,
	) -> (
		err: Error,
	) {
		fis, rderr := os.read_directory_by_path(path, 0, temp_allocator)
		if rderr != nil {
			err = error_new(rderr)
			return
		}

		fis_loop: for fi in fis {
			#partial switch fi.type {
			case .Directory:
				if strings.has_prefix(fi.name, ".") {
					continue fis_loop
				}
				for d in IGNORED_DIRECTORIES {
					if fi.name == d {
						continue fis_loop
					}
				}
				read_dir(fi.fullpath, files, program_allocator, temp_allocator)
			case .Regular:
				for suffix in IGNORED_SUFFIXES {
					if strings.has_suffix(fi.name, suffix) {
						continue fis_loop
					}
				}
				for name in IGNORED_FILENAMES {
					if fi.name == name {
						continue fis_loop
					}
				}

				file_data, fderr := os.read_entire_file_from_path(fi.fullpath, program_allocator)
				if fderr != nil {
					msg := fmt.aprintf(
						"unable to read file: %s",
						fi.fullpath,
						allocator = program_allocator,
					)
					err = error_new(fderr, msg)
					return
				}

				file_path, aerr := strings.clone(fi.fullpath, program_allocator)
				if aerr != nil {
					err = error_new(aerr)
					return
				}

				append(files, Readme_File{path = file_path, data = file_data})
			}
		}

		return
	}

	files := make([dynamic]Readme_File, allocator = program_allocator)
	if err = read_dir(tmp_path, &files, program_allocator, temp_allocator); err.valid {
		return
	}

	for file, i in files {
		files[i].path = file.path[len(tmp_path):]
	}

	prompt = build_readme_prompt(github_repo, authors_note, files[:], program_allocator)
	return
}

generate_blogpost_prompt :: proc(
	github_owner, github_repo, authors_note: string,
	github_access_token: string,
	openai_api_key: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	llm_prompt: string,
	err: Error,
) {
	defer free_all(temp_allocator)

	// fetch github data

	commits: []Commit

	{ 	// get all commits
		print(.Loading, "Fetching commits")
		defer printf(.Success, "Fetched %d commits\n", len(commits), clear_line = true)

		req := create_github_request(temp_allocator, github_access_token)
		url := fmt.aprintf(
			"%s/repos/%s/%s/commits",
			GITHUB_API_URL,
			github_owner,
			github_repo,
			allocator = temp_allocator,
		)

		res, rerr := http_request(req, url, temp_allocator, program_allocator, &commits)
		if rerr != nil {
			err = error_new(rerr)
			return
		}
		if res_err, ok := res.(Http_Request_Err); ok {
			err = error_new(res_err)
			return
		}
	}

	commits_str: strings.Builder
	strings.builder_init(&commits_str, allocator = program_allocator)

	#reverse for commit, i in commits {
		printf(
			.Loading,
			"Fetching commit details (%d/%d)",
			len(commits) - 1 - i,
			len(commits),
			clear_line = true,
		)

		defer free_all(temp_allocator)

		req := create_github_request(temp_allocator, github_access_token)
		url := fmt.aprintf(
			"%s/repos/%s/%s/commits/%s",
			GITHUB_API_URL,
			github_owner,
			github_repo,
			commit.sha,
			allocator = temp_allocator,
		)

		details: Commit_Details

		req_result, rerr := http_request(req, url, temp_allocator, program_allocator, &details)
		if rerr != nil {
			err = error_new(rerr)
			return
		}
		if req_err, ok := req_result.(Http_Request_Err); ok {
			err = error_new(req_err)
			return
		}


		files_str: strings.Builder
		strings.builder_init(&files_str, allocator = temp_allocator)

		file_loop: for file in details.files {
			for dir in IGNORED_DIRECTORIES {
				if strings.contains(
					file.filename,
					fmt.aprintf("%s/", dir, allocator = temp_allocator),
				) {
					continue file_loop
				}
			}


			skip_patch: bool
			for suffix in IGNORED_SUFFIXES {
				if strings.has_suffix(file.filename, suffix) {
					skip_patch = true
					break
				}
			}
			if !skip_patch {
				for filename in IGNORED_FILENAMES {
					if filename == file.filename {
						skip_patch = true
						break
					}
				}
			}

			patch: string
			if !skip_patch {
				patch = minify_patch(file.patch, file.status, temp_allocator)
			}

			str := fmt.aprintf(
				FILE_TEMPL,
				file.filename,
				file.status,
				file.additions,
				file.deletions,
				patch,
				allocator = temp_allocator,
			)
			strings.write_string(&files_str, str)
		}

		strings.write_string(
			&commits_str,
			fmt.aprintf(
				COMMIT_TEMPL,
				details.commit.author.date,
				details.commit.author.name,
				commit.commit.message,
				details.stats.additions,
				details.stats.deletions,
				string(files_str.buf[:]),
				allocator = temp_allocator,
			),
		)
	}

	printf(.Success, "Fetched details for all commits (%d)\n", len(commits), clear_line = true)

	// build prompt

	print(.Loading, "Building LLM prompt")

	llm_prompt = build_blog_prompt(
		github_repo,
		string(commits_str.buf[:]),
		authors_note,
		program_allocator,
	)

	return
}


main :: proc() {
	context = runtime.default_context()

	program_arena: mem.Arena
	mem.arena_init(&program_arena, PROGRAM_MEMORY[:])
	program_allocator := mem.arena_allocator(&program_arena)
	temp_allocator := create_arena(program_allocator, 10 * mem.Megabyte)

	// logger

	log_file, lferr := os.create_temp_file("", "logs_")
	if lferr != nil {
		error_fatal_new(lferr)
	}
	defer os.close(log_file)

	context.logger = log.create_file_logger(
		log_file,
		.Debug,
		{.Level, .Date, .Time, .Short_File_Path, .Line, .Procedure},
		allocator = program_allocator,
	)
	log_filename := os.name(log_file)
	context.user_ptr = &[]rawptr{raw_data(log_filename), rawptr(uintptr(len(log_filename)))}

	github_access_token: string
	openai_api_key: string
	anthropic_api_key: string

	{ 	// setup config
		defer free_all(temp_allocator)

		os_config_dir, cderr := os.user_config_dir(temp_allocator)
		if cderr != nil {
			error_fatal_new(cderr)
		}
		config_dir_path, _ := filepath.join({os_config_dir, "blogger"}, temp_allocator)
		config_file_path, _ := filepath.join({config_dir_path, "config.txt"}, temp_allocator)

		config_file_data, cferr := os.read_entire_file_from_path(config_file_path, temp_allocator)
		switch cferr {
		case .Not_Exist:
			// setup config
			if mderr := os.make_directory(config_dir_path); mderr != nil {
				switch mderr {
				case .Exist:
				case:
					error_fatal_new(mderr)
				}
			}

			err: os.Error
			if github_access_token, _, err = read_prompt(
				"Github access token: ",
				100,
				program_allocator,
				true,
			); err != nil {
				error_fatal_new(err)
			}
			if openai_api_key, _, err = read_prompt(
				"Open ai API key: ",
				256,
				program_allocator,
				true,
			); err != nil {
				error_fatal_new(err)
			}
			if anthropic_api_key, _, err = read_prompt(
				"Anthropic API key: ",
				256,
				program_allocator,
				true,
			); err != nil {
				error_fatal_new(err)
			}

			data := fmt.aprintf(
				"github_access_token=%s\nopenai_api_key=%s\nanthropic_api_key=%s",
				github_access_token,
				openai_api_key,
				anthropic_api_key,
				allocator = temp_allocator,
			)

			config_file, cferr := os.create(config_file_path)
			if cferr != nil {
				error_fatal_new(cferr)
			}
			defer os.close(config_file)

			if _, err = os.write(config_file, transmute([]byte)data); err != nil {
				error_fatal_new(err)
			}

			printf(.Success, "Saved config to %s\n", config_file_path)
			fmt.println(DIVIDER)
		case nil:
			// read config
			config := make(map[string]string, allocator = temp_allocator)

			start: int
			key: string
			for b, i in config_file_data {
				switch {
				case b == '=':
					if start < i {
						key = strings.clone(string(config_file_data[start:i]), temp_allocator)
					}
					start = i + 1
				// save keyval if byte == '\n' or if it's the last byte and key is set
				case b == '\n':
					if start < i {
						val := strings.clone(string(config_file_data[start:i]), program_allocator)
						start = i + 1
						if key != "" {
							config[key] = val
							key = ""
						}
					}
				case i == len(config_file_data) - 1 && key != "":
					if start < i {
						val := strings.clone(
							string(config_file_data[start:i + 1]),
							program_allocator,
						)
						if key != "" {
							config[key] = val
							key = ""
						}
					}
				}
			}

			ok: bool
			if github_access_token, ok = config["github_access_token"]; !ok {
				error_fatal_new(nil, "Missing github access token")
			}
			if openai_api_key, ok = config["openai_api_key"]; !ok {
				error_fatal_new(nil, "Missing open ai api key")
			}
			if anthropic_api_key, ok = config["anthropic_api_key"]; !ok {
				error_fatal_new(nil, "Missing anthropic api key")
			}
		case:
			error_fatal_new(cferr)
		}
	}

	// read user input

	choice, cherr := read_choice("What do you want to create?", {"Blogpost", "Readme"})
	if cherr != nil {
		error_fatal_new(cherr)
	}
	llm_provider_choice, lerr := read_choice(
		"Which LLM do you want to use?",
		{OPEN_AI_MODEL, ANTHROPIC_AI_MODEL},
	)
	if lerr != nil {
		error_fatal_new(lerr)
	}
	github_owner, _, goerr := read_prompt("Github repo owner: ", 100, program_allocator)
	if goerr != nil {
		error_fatal_new(goerr)
	}
	github_repo, _, grerr := read_prompt("Github repository name: ", 100, program_allocator)
	if grerr != nil {
		error_fatal_new(grerr)
	}
	authors_note, _, anerr := read_prompt(
		"Author's note (can be left empty):\n",
		1024,
		program_allocator,
	)
	if anerr != nil {
		error_fatal_new(anerr)
	}

	fmt.println(DIVIDER)

	err: Error
	llm_prompt: string

	switch choice {
	case "Readme":
		llm_prompt, err = generate_readme_prompt(
			github_owner,
			github_repo,
			authors_note,
			program_allocator,
			temp_allocator,
		)
	case "Blogpost":
		llm_prompt, err = generate_blogpost_prompt(
			github_owner,
			github_repo,
			authors_note,
			github_access_token,
			openai_api_key,
			program_allocator,
			temp_allocator,
		)
	}

	log.infof("LLM prompt: %s", llm_prompt)

	if err.valid {
		error_fatal(&err)
	}

	prompt_size: string
	{
		b := len(llm_prompt)
		switch {
		case b < mem.Kilobyte:
			// bytes
			prompt_size = fmt.aprintf("%db", b, allocator = temp_allocator)
		case b < mem.Megabyte:
			// kilobytes
			prompt_size = fmt.aprintf("%.3fkb", f32(b) / 1024.0, allocator = temp_allocator)
		case b < mem.Gigabyte:
			// megabytes
			prompt_size = fmt.aprintf(
				"%.3fmb",
				f32(b) / 1024.0 / 1024.0,
				allocator = temp_allocator,
			)
		}
	}

	printf(.Success, "Prompt built %s(size: %s)\n", RESET, prompt_size, clear_line = true)

	// LLM

	llm_provider: LLM_Provider
	llm_provider_api_key: string
	switch llm_provider_choice {
	case OPEN_AI_MODEL:
		llm_provider = .Open_Ai
		llm_provider_api_key = openai_api_key
	case ANTHROPIC_AI_MODEL:
		llm_provider = .Anthropic
		llm_provider_api_key = anthropic_api_key
	}

	llm_config := llm_providers[llm_provider]

	{ 	// token count
		defer free_all(temp_allocator)
		print(.Loading, "Fetching token count")

		token_count, err := llm_config->get_token_count(
			llm_provider_api_key,
			llm_prompt,
			program_allocator,
			temp_allocator,
		)
		if err.valid {
			error_fatal(&err)
		}

		printf(.Success, "Token count: %d\n", token_count, clear_line = true)
	}

	should_continue, cerr := read_confirmation("Do you want to continue?")
	if cerr != nil {
		fmt.println("unable to read from stdin: ", cerr)
		return
	}

	if !should_continue {
		return
	}

	fmt.println(DIVIDER)

	llm_message: string

	{ 	// send prompt
		print(.Loading, "Sending prompt")
		defer free_all(temp_allocator)

		output_tokens: int
		err: Error
		llm_message, output_tokens, err = llm_config->send_prompt(
			llm_provider_api_key,
			llm_prompt,
			program_allocator,
			temp_allocator,
		)
		if err.valid {
			error_fatal(&err)
		}

		printf(
			.Success,
			"LLM response received (output tokens: %d)\n",
			output_tokens,
			clear_line = true,
		)
	}

	// save response

	exe_path := os.args[0]
	// NOTE: temp_allocator is empty, we can ignore the error
	out_filename := fmt.aprintf(
		"%s-%s.md",
		github_repo,
		strings.to_lower(choice, temp_allocator),
		allocator = temp_allocator,
	)
	out_path, _ := filepath.join({exe_path, "../out", out_filename}, temp_allocator)

	out_path_ok, operr := read_confirmation(
		fmt.aprintf(
			"Do you want to save the output to: %s?",
			out_path,
			allocator = temp_allocator,
		),
	)
	if operr != nil {
		error_fatal_new(operr)
	}
	if !out_path_ok {
		err: os.Error
		out_path, _, err = read_prompt("Output file path: ", 100, temp_allocator)
		if err != nil {
			error_fatal_new(err)
		}
	}

	out_file, oerr := os.create(out_path)
	if oerr != nil {
		error_fatal_new(oerr)
	}

	if _, err := os.write(out_file, transmute([]byte)llm_message); err != nil {
		error_fatal_new(err)
	}

	printf(.Success, "%s generated\n", choice)
	fmt.printfln("Saved LLM output to: %s", out_path)
}
