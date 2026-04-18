from std.io import input, print
from std.collections import List
from std.os import remove
from std.subprocess import run
from std.sys import argv, stderr


fn shell_quote(value: String) -> String:
    return "'" + value.replace("'", "'\"'\"'") + "'"


fn json_escape(value: String) -> String:
    return (
        value.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


fn write_text_file(path: String, content: String) raises:
    with open(path, "w") as file:
        file.write(content)


fn read_text_file(path: String) raises -> String:
    with open(path, "r") as file:
        return file.read().strip()


fn remove_quiet(path: String):
    if path == "":
        return
    try:
        remove(path)
    except:
        pass


fn require_runtime_command(command_name: String) raises -> Bool:
    return run("command -v " + shell_quote(command_name) + " 2>/dev/null").strip() != ""


fn run_jq_raw(input_json: String, filter: String) raises -> String:
    var in_file = ""
    var out_file = ""
    var result = ""
    try:
        in_file = run("mktemp").strip()
        out_file = run("mktemp").strip()
        write_text_file(in_file, input_json)
        let cmd = (
            "jq -r "
            + shell_quote(filter)
            + " "
            + shell_quote(in_file)
            + " > "
            + shell_quote(out_file)
            + " 2>/dev/null"
        )
        _ = run(cmd)
        result = read_text_file(out_file)
    except:
        remove_quiet(in_file)
        remove_quiet(out_file)
        raise
    remove_quiet(in_file)
    remove_quiet(out_file)
    return result


fn run_jq_compact(input_json: String, filter: String) raises -> String:
    var in_file = ""
    var out_file = ""
    var result = ""
    try:
        in_file = run("mktemp").strip()
        out_file = run("mktemp").strip()
        write_text_file(in_file, input_json)
        let cmd = (
            "jq -c "
            + shell_quote(filter)
            + " "
            + shell_quote(in_file)
            + " > "
            + shell_quote(out_file)
            + " 2>/dev/null"
        )
        _ = run(cmd)
        result = read_text_file(out_file)
    except:
        remove_quiet(in_file)
        remove_quiet(out_file)
        raise
    remove_quiet(in_file)
    remove_quiet(out_file)
    return result


fn emit_json(payload: String):
    print(payload, flush=True)


fn send_response(request_id_json: String, result_json: String) raises:
    emit_json(
        "{\"jsonrpc\":\"2.0\",\"id\":"
        + request_id_json
        + ",\"result\":"
        + result_json
        + "}"
    )


fn send_error(
    request_id_json: String,
    code: Int,
    message: String,
    data: String = "",
) raises:
    var payload = (
        "{\"jsonrpc\":\"2.0\",\"id\":"
        + request_id_json
        + ",\"error\":{\"code\":"
        + String(code)
        + ",\"message\":\""
        + json_escape(message)
        + "\""
    )
    if data != "":
        payload += ",\"data\":\"" + json_escape(data) + "\""
    payload += "}}"
    emit_json(payload)


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

    if not require_runtime_command("jq"):
        print("jq is required at runtime", file=stderr, flush=True)
        return
    if not require_runtime_command("curl"):
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
                    "message cannot be empty",
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

            var temp_files = List[String]()
            let token_file = run("mktemp").strip()
            temp_files.append(token_file)
            write_text_file(token_file, token)
            let user_file = run("mktemp").strip()
            temp_files.append(user_file)
            write_text_file(user_file, user)
            let message_file = run("mktemp").strip()
            temp_files.append(message_file)
            write_text_file(message_file, message)

            var curl_cmd = (
                "curl -sS -X POST https://api.pushover.net/1/messages.json"
                + " --data-urlencode "
                + shell_quote("token@" + token_file)
                + " --data-urlencode "
                + shell_quote("user@" + user_file)
                + " --data-urlencode "
                + shell_quote("message@" + message_file)
            )

            for field_name in ["title", "sound", "url", "url_title", "device"]:
                let value = run_jq_raw(arguments_json, "." + field_name + " // empty")
                if value != "":
                    let value_file = run("mktemp").strip()
                    temp_files.append(value_file)
                    write_text_file(value_file, value)
                    curl_cmd += (
                        " --data-urlencode "
                        + shell_quote(field_name + "@" + value_file)
                    )

            if priority != "":
                let priority_file = run("mktemp").strip()
                temp_files.append(priority_file)
                write_text_file(priority_file, priority)
                curl_cmd += (
                    " --data-urlencode "
                    + shell_quote("priority@" + priority_file)
                )

            var response_body = ""
            var status = ""
            try:
                response_body = run(curl_cmd).strip()
                status = run_jq_raw(response_body, ".status // empty")
            except:
                for path in temp_files:
                    remove_quiet(path)
                send_error(
                    request_id_json,
                    -32000,
                    "Failed to send notification",
                    "curl/jq execution failed",
                )
                continue
            for path in temp_files:
                remove_quiet(path)

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
