package main

import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"

import http "../vendor/odin-http"
import http_client "../vendor/odin-http/client"

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

	MODEL :: "gpt-5.4"
	Data :: struct {
		model: string,
		input: string,
	}

	data_json := json.marshal(Data{model = MODEL, input = prompt}, allocator = allocator) or_return
	log.infof("LLM Request data: %s", string(data_json))
	bytes.buffer_init(&req.body, data_json)

	return
}

Http_Error :: union #shared_nil {
	http_client.Error,
	http_client.Body_Error,
	json.Unmarshal_Error,
}

Http_Request_Ok :: struct {}

Http_Request_Err :: struct {
	url:     string,
	method:  http.Method,
	status:  http.Status,
	headers: http.Headers,
	body:    http_client.Body_Type,
}

Http_Request_Result :: union {
	Http_Request_Ok,
	Http_Request_Err,
}

http_request :: proc(
	request: ^http_client.Request,
	url: string,
	http_allocator, data_allocator: mem.Allocator,
	data: ^$T,
) -> (
	result: Http_Request_Result,
	err: Http_Error,
) {
	res := http_client.request(request, url, http_allocator) or_return
	body, _ := http_client.response_body(&res, allocator = http_allocator) or_return

	switch {
	case u16(res.status) >= 200 && u16(res.status) < 300:
		#partial switch b in body {
		case http_client.Body_Plain:
			json.unmarshal_string(b, data, allocator = data_allocator) or_return
		case:
			assert(false, "unimplemented")
		}

		result = Http_Request_Ok{}
	case:
		result = Http_Request_Err {
			url     = url,
			method  = request.method,
			status  = res.status,
			headers = res.headers,
			body    = body,
		}
	}

	return
}
