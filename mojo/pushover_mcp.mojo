from std.io import input, print
from std.subprocess import run
from std.sys import argv, stderr


fn shell_quote(value: String) -> String:
    return "'" + value.replace("'", "'\"'\"'") + "'"


fn run_jq_raw(input_json: String, filter: String) raises -> String:
    let cmd = (
        "printf %s "
        + shell_quote(input_json)
        + " | jq -r "
        + shell_quote(filter)
        + " 2>/dev/null"
    )
    return run(cmd).strip()


fn run_jq_compact(input_json: String, filter: String) raises -> String:
    let cmd = (
        "printf %s "
        + shell_quote(input_json)
        + " | jq -c "
        + shell_quote(filter)
        + " 2>/dev/null"
    )
    return run(cmd).strip()


fn emit_json(payload: String):
    print(payload, flush=True)


fn send_response(request_id_json: String, result_json: String) raises:
    let cmd = (
        "jq -cn --argjson id "
        + shell_quote(request_id_json)
        + " --argjson result "
        + shell_quote(result_json)
        + " '{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":$result}'"
    )
    emit_json(run(cmd).strip())


fn send_error(
    request_id_json: String,
    code: Int,
    message: String,
    data: String = "",
) raises:
    var cmd = (
        "jq -cn --argjson id "
        + shell_quote(request_id_json)
        + " --arg code "
        + shell_quote(String(code))
        + " --arg message "
        + shell_quote(message)
    )
    if data != "":
        cmd += (
            " --arg data "
            + shell_quote(data)
            + " '{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":($code|tonumber),\"message\":$message,\"data\":$data}}'"
        )
    else:
        cmd += " '{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":($code|tonumber),\"message\":$message}}'"
    emit_json(run(cmd).strip())


fn parse_cli_args() -> (String, String):
    let args = argv()
    var token = ""
    var user = ""

    var i = 1
    while i < len(args):
        let arg = String(args[i])
        if arg == "--token" and i + 1 < len(args):
            token = String(args[i + 1])
            i += 2
            continue
        if arg == "--user" and i + 1 < len(args):
            user = String(args[i + 1])
            i += 2
            continue
        i += 1

    return (token, user)


fn main() raises:
    let (token, user) = parse_cli_args()
    if token == "" or user == "":
        print(
            "Usage: pushover-mcp --token YOUR_TOKEN --user YOUR_USER",
            file=stderr,
            flush=True,
        )
        return

    if run("command -v jq 2>/dev/null").strip() == "":
        print("jq is required at runtime", file=stderr, flush=True)
        return
    if run("command -v curl 2>/dev/null").strip() == "":
        print("curl is required at runtime", file=stderr, flush=True)
        return

    let tool_schema_json = "{\"name\":\"send\",\"description\":\"Send a notification via Pushover\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"minLength\":1},\"title\":{\"type\":\"string\"},\"priority\":{\"type\":\"number\",\"minimum\":-2,\"maximum\":2},\"sound\":{\"type\":\"string\"},\"url\":{\"type\":\"string\",\"format\":\"uri\"},\"url_title\":{\"type\":\"string\"},\"device\":{\"type\":\"string\"}},\"required\":[\"message\"],\"additionalProperties\":false}}"

    while True:
        var line = ""
        try:
            line = input()
        except Exception:
            break

        let stripped = line.strip()
        if stripped == "":
            continue

        let request_json = run_jq_compact(stripped, ".")
        if request_json == "":
            send_error("null", -32700, "Parse error", "Invalid JSON input")
            continue

        let method = run_jq_raw(request_json, ".method // empty")
        let request_id_json = run_jq_compact(request_json, ".id // null")
        let params_json = run_jq_compact(request_json, ".params // {}")

        if method == "initialize":
            send_response(
                request_id_json,
                "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"pushover\",\"version\":\"1.0.0\"}}",
            )
            continue

        if method == "notifications/initialized":
            continue

        if method == "tools/list":
            send_response(request_id_json, "{\"tools\":[" + tool_schema_json + "]}")
            continue

        if method == "tools/call":
            let name = run_jq_raw(params_json, ".name // empty")
            let arguments_json = run_jq_compact(params_json, ".arguments // {}")

            if name != "send":
                send_error(
                    request_id_json,
                    -32602,
                    "Invalid params",
                    "Unknown tool: " + name,
                )
                continue

            let message = run_jq_raw(arguments_json, ".message // empty").strip()
            if message == "":
                send_error(
                    request_id_json,
                    -32602,
                    "Invalid params",
                    "message is required and cannot be empty",
                )
                continue

            var priority = ""
            let priority_json = run_jq_compact(arguments_json, ".priority // null")
            if priority_json != "null":
                priority = run_jq_raw(arguments_json, ".priority|tostring")
                let valid_priority = run_jq_raw(
                    arguments_json,
                    "(.priority|type == \"number\") and (.priority >= -2) and (.priority <= 2)",
                )
                if valid_priority != "true":
                    send_error(
                        request_id_json,
                        -32602,
                        "Invalid params",
                        "priority must be a number between -2 and 2",
                    )
                    continue

            var curl_cmd = (
                "curl -sS -X POST https://api.pushover.net/1/messages.json"
                + " --data-urlencode "
                + shell_quote("token=" + token)
                + " --data-urlencode "
                + shell_quote("user=" + user)
                + " --data-urlencode "
                + shell_quote("message=" + message)
            )

            for field_name in ["title", "sound", "url", "url_title", "device"]:
                let value = run_jq_raw(arguments_json, "." + field_name + " // empty")
                if value != "":
                    curl_cmd += " --data-urlencode " + shell_quote(field_name + "=" + value)

            if priority != "":
                curl_cmd += " --data-urlencode " + shell_quote("priority=" + priority)

            let response_body = run(curl_cmd).strip()
            let status = run_jq_raw(response_body, ".status // empty")
            if status != "1":
                send_error(
                    request_id_json,
                    -32000,
                    "Pushover API error",
                    response_body,
                )
                continue

            send_response(
                request_id_json,
                "{\"content\":[{\"type\":\"text\",\"text\":\"Notification sent successfully\"}]}",
            )
            continue

        if request_id_json != "null":
            send_error(request_id_json, -32601, "Method not found", method)
