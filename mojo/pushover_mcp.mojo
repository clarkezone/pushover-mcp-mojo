from python import Python


fn send_response(json_mod, sys_mod, request_id, result) raises:
    let payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": result,
    }
    sys_mod.stdout.write(json_mod.dumps(payload) + "\n")
    sys_mod.stdout.flush()


fn send_error(json_mod, sys_mod, request_id, code, message, data = None) raises:
    let payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {
            "code": code,
            "message": message,
        },
    }
    if data is not None:
        payload["error"]["data"] = data
    sys_mod.stdout.write(json_mod.dumps(payload) + "\n")
    sys_mod.stdout.flush()


fn main() raises:
    let argparse = Python.import_module("argparse")
    let json = Python.import_module("json")
    let sys = Python.import_module("sys")
    let urllib_parse = Python.import_module("urllib.parse")
    let urllib_request = Python.import_module("urllib.request")
    let urllib_error = Python.import_module("urllib.error")

    let parser = argparse.ArgumentParser(
        description="MCP for Pushover.net notifications (Mojo)"
    )
    parser.add_argument("--token", required=True, help="Pushover application token")
    parser.add_argument("--user", required=True, help="Pushover user key")
    let args = parser.parse_args()

    let token = args.token
    let user = args.user

    let tool_schema = {
        "name": "send",
        "description": "Send a notification via Pushover",
        "inputSchema": {
            "type": "object",
            "properties": {
                "message": {"type": "string", "minLength": 1},
                "title": {"type": "string"},
                "priority": {"type": "number", "minimum": -2, "maximum": 2},
                "sound": {"type": "string"},
                "url": {"type": "string", "format": "uri"},
                "url_title": {"type": "string"},
                "device": {"type": "string"},
            },
            "required": ["message"],
            "additionalProperties": False,
        },
    }

    while True:
        let line = sys.stdin.readline()
        if line == "":
            break

        let stripped = line.strip()
        if stripped == "":
            continue

        try:
            let request = json.loads(stripped)
        except Exception as parse_error:
            send_error(
                json,
                sys,
                None,
                -32700,
                "Parse error",
                str(parse_error),
            )
            continue

        let method = request.get("method")
        let request_id = request.get("id")
        let params = request.get("params", {})

        if method == "initialize":
            send_response(
                json,
                sys,
                request_id,
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {
                        "tools": {},
                    },
                    "serverInfo": {
                        "name": "pushover",
                        "version": "1.0.0",
                    },
                },
            )
            continue

        if method == "notifications/initialized":
            continue

        if method == "tools/list":
            send_response(
                json,
                sys,
                request_id,
                {
                    "tools": [tool_schema],
                },
            )
            continue

        if method == "tools/call":
            let name = params.get("name")
            let arguments = params.get("arguments", {})

            if name != "send":
                send_error(
                    json,
                    sys,
                    request_id,
                    -32602,
                    "Invalid params",
                    "Unknown tool: " + str(name),
                )
                continue

            let message_value = arguments.get("message")
            if message_value is None:
                send_error(
                    json,
                    sys,
                    request_id,
                    -32602,
                    "Invalid params",
                    "message is required",
                )
                continue
            let message = str(message_value).strip()
            if message == "":
                send_error(
                    json,
                    sys,
                    request_id,
                    -32602,
                    "Invalid params",
                    "message cannot be empty",
                )
                continue

            let priority = None
            let priority_input = arguments.get("priority")
            if priority_input is not None:
                try:
                    priority = int(priority_input)
                except Exception:
                    send_error(
                        json,
                        sys,
                        request_id,
                        -32602,
                        "Invalid params",
                        "priority must be a number between -2 and 2",
                    )
                    continue

            if priority is not None:
                if priority < -2 or priority > 2:
                    send_error(
                        json,
                        sys,
                        request_id,
                        -32602,
                        "Invalid params",
                        "priority must be between -2 and 2",
                    )
                    continue

            let payload = {
                "token": token,
                "user": user,
                "message": message,
            }

            for field_name in ["title", "sound", "url", "url_title", "device"]:
                let value = arguments.get(field_name)
                if value is not None:
                    payload[field_name] = str(value)
            if priority is not None:
                payload["priority"] = priority

            let encoded = urllib_parse.urlencode(payload).encode("utf-8")
            let http_request = urllib_request.Request(
                "https://api.pushover.net/1/messages.json",
                data=encoded,
                method="POST",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )

            try:
                let response = urllib_request.urlopen(http_request)
                let response_body = response.read().decode("utf-8")
                let response_json = json.loads(response_body)
                if response_json.get("status") != 1:
                    send_error(
                        json,
                        sys,
                        request_id,
                        -32000,
                        "Pushover API error",
                        response_body,
                    )
                    continue
                send_response(
                    json,
                    sys,
                    request_id,
                    {
                        "content": [
                            {"type": "text", "text": "Notification sent successfully"}
                        ]
                    },
                )
            except urllib_error.HTTPError as http_error:
                let body = ""
                try:
                    body = http_error.read().decode("utf-8")
                except Exception:
                    body = str(http_error)
                send_error(
                    json,
                    sys,
                    request_id,
                    -32000,
                    "Pushover API error",
                    body,
                )
            except Exception as request_error:
                send_error(
                    json,
                    sys,
                    request_id,
                    -32000,
                    "Failed to send notification",
                    str(request_error),
                )
            continue

        if request_id is not None:
            send_error(
                json,
                sys,
                request_id,
                -32601,
                "Method not found",
                method,
            )
