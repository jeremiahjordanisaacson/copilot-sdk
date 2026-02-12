/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

/**
 * @file client.c
 * @brief CopilotClient implementation - spawns CLI process, manages sessions.
 */

#include "copilot/copilot.h"
#include "copilot/sdk_protocol_version.h"
#include "json_rpc_client.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cjson/cJSON.h>

#ifdef _WIN32
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <process.h>
#else
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#endif

/* ============================================================================
 * Internal session structure (forward declared in copilot.h as opaque)
 * ============================================================================ */

/* Session event handler entry */
typedef struct session_handler_entry {
    int id;
    const char *event_type_filter;  /* NULL = wildcard */
    copilot_session_event_handler_fn handler;
    void *user_data;
    struct session_handler_entry *next;
} session_handler_entry_t;

struct copilot_session {
    char *session_id;
    char *workspace_path;
    json_rpc_client_t *rpc;
    struct copilot_client *owner;

    /* Event handlers */
    session_handler_entry_t *handlers;
    int next_handler_id;
    pthread_mutex_t handlers_mutex;

    /* Tools */
    copilot_tool_t *tools;
    size_t tools_count;

    /* Permission handler */
    copilot_permission_handler_fn permission_handler;
    void *permission_user_data;

    /* User input handler */
    copilot_user_input_handler_fn user_input_handler;
    void *user_input_user_data;

    /* Hook handler */
    copilot_hook_handler_fn hook_handler;
    void *hook_user_data;

    /* SendAndWait synchronization */
    pthread_mutex_t idle_mutex;
    pthread_cond_t idle_cond;
    bool idle_signaled;
    bool error_signaled;
    char *error_message;
    char *last_assistant_content;

    /* Linked list for client's session tracking */
    struct copilot_session *next;
};

/* ============================================================================
 * Internal client structure
 * ============================================================================ */

struct copilot_client {
    /* Options (owned copies) */
    char *cli_path;
    char *cwd;
    char *log_level;
    bool use_stdio;
    bool auto_start;
    bool auto_restart;
    char *github_token;
    bool use_logged_in_user;
    char **extra_args;
    int extra_args_count;

    /* State */
    copilot_connection_state_t state;

    /* Process */
#ifdef _WIN32
    HANDLE process_handle;
    HANDLE stdin_write;
    HANDLE stdout_read;
#else
    pid_t cli_pid;
    int stdin_write_fd;
    int stdout_read_fd;
#endif

    /* JSON-RPC client */
    json_rpc_client_t *rpc;

    /* Sessions */
    copilot_session_t *sessions;
    pthread_mutex_t sessions_mutex;
};

/* ============================================================================
 * Error strings
 * ============================================================================ */

const char *copilot_error_string(copilot_error_t err)
{
    switch (err) {
    case COPILOT_OK:                     return "OK";
    case COPILOT_ERROR_INVALID_ARGUMENT: return "Invalid argument";
    case COPILOT_ERROR_NOT_CONNECTED:    return "Not connected";
    case COPILOT_ERROR_SPAWN_FAILED:     return "Failed to spawn CLI process";
    case COPILOT_ERROR_PROTOCOL_MISMATCH:return "Protocol version mismatch";
    case COPILOT_ERROR_TIMEOUT:          return "Timeout";
    case COPILOT_ERROR_JSON_PARSE:       return "JSON parse error";
    case COPILOT_ERROR_RPC:              return "JSON-RPC error";
    case COPILOT_ERROR_SESSION_NOT_FOUND:return "Session not found";
    case COPILOT_ERROR_TOOL_NOT_FOUND:   return "Tool not found";
    case COPILOT_ERROR_HANDLER_FAILED:   return "Handler failed";
    case COPILOT_ERROR_OUT_OF_MEMORY:    return "Out of memory";
    case COPILOT_ERROR_IO:               return "I/O error";
    case COPILOT_ERROR_ALREADY_STARTED:  return "Already started";
    case COPILOT_ERROR_SESSION_ERROR:    return "Session error";
    default:                             return "Unknown error";
    }
}

/* ============================================================================
 * Defaults
 * ============================================================================ */

copilot_client_options_t copilot_client_options_default(void)
{
    copilot_client_options_t opts;
    memset(&opts, 0, sizeof(opts));
    opts.cli_path = NULL;
    opts.cwd = NULL;
    opts.log_level = "info";
    opts.use_stdio = true;
    opts.auto_start = true;
    opts.auto_restart = true;
    opts.github_token = NULL;
    opts.use_logged_in_user = true;
    opts.extra_args = NULL;
    return opts;
}

copilot_session_config_t copilot_session_config_default(void)
{
    copilot_session_config_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    return cfg;
}

/* ============================================================================
 * Internal: find session by ID
 * ============================================================================ */

static copilot_session_t *find_session(copilot_client_t *client, const char *session_id)
{
    pthread_mutex_lock(&client->sessions_mutex);
    copilot_session_t *s = client->sessions;
    while (s) {
        if (strcmp(s->session_id, session_id) == 0) {
            pthread_mutex_unlock(&client->sessions_mutex);
            return s;
        }
        s = s->next;
    }
    pthread_mutex_unlock(&client->sessions_mutex);
    return NULL;
}

static void add_session(copilot_client_t *client, copilot_session_t *session)
{
    pthread_mutex_lock(&client->sessions_mutex);
    session->next = client->sessions;
    client->sessions = session;
    pthread_mutex_unlock(&client->sessions_mutex);
}

static void remove_session(copilot_client_t *client, copilot_session_t *session)
{
    pthread_mutex_lock(&client->sessions_mutex);
    copilot_session_t **pp = &client->sessions;
    while (*pp) {
        if (*pp == session) {
            *pp = session->next;
            break;
        }
        pp = &(*pp)->next;
    }
    pthread_mutex_unlock(&client->sessions_mutex);
}

/* ============================================================================
 * Internal: dispatch session event
 * ============================================================================ */

static void dispatch_session_event(copilot_session_t *session,
                                   const copilot_session_event_t *event)
{
    pthread_mutex_lock(&session->handlers_mutex);
    session_handler_entry_t *h = session->handlers;
    while (h) {
        if (!h->event_type_filter || strcmp(h->event_type_filter, event->type) == 0) {
            h->handler(event, h->user_data);
        }
        h = h->next;
    }
    pthread_mutex_unlock(&session->handlers_mutex);
}

/* ============================================================================
 * Internal: session event notification handler
 * ============================================================================ */

static void on_session_event_notification(const char *method, cJSON *params, void *user_data)
{
    copilot_client_t *client = (copilot_client_t *)user_data;

    cJSON *session_id_item = cJSON_GetObjectItem(params, "sessionId");
    cJSON *event_item = cJSON_GetObjectItem(params, "event");
    if (!session_id_item || !cJSON_IsString(session_id_item) || !event_item) return;

    const char *session_id = session_id_item->valuestring;
    copilot_session_t *session = find_session(client, session_id);
    if (!session) return;

    /* Build event struct */
    copilot_session_event_t event;
    memset(&event, 0, sizeof(event));

    cJSON *type_item = cJSON_GetObjectItem(event_item, "type");
    if (type_item && cJSON_IsString(type_item)) {
        event.type = type_item->valuestring;
    } else {
        event.type = "unknown";
    }

    char *raw = cJSON_PrintUnformatted(event_item);
    event.raw_json = raw;

    /* Parse convenience fields */
    cJSON *data = cJSON_GetObjectItem(event_item, "data");
    if (data) {
        cJSON *content = cJSON_GetObjectItem(data, "content");
        if (content && cJSON_IsString(content)) {
            event.content = content->valuestring;
        }
        cJSON *message = cJSON_GetObjectItem(data, "message");
        if (message && cJSON_IsString(message)) {
            event.message = message->valuestring;
        }
        cJSON *delta_content = cJSON_GetObjectItem(data, "deltaContent");
        if (delta_content && cJSON_IsString(delta_content)) {
            event.delta_content = delta_content->valuestring;
        }
        cJSON *tool_name = cJSON_GetObjectItem(data, "toolName");
        if (tool_name && cJSON_IsString(tool_name)) {
            event.tool_name = tool_name->valuestring;
        }
        cJSON *tool_call_id = cJSON_GetObjectItem(data, "toolCallId");
        if (tool_call_id && cJSON_IsString(tool_call_id)) {
            event.tool_call_id = tool_call_id->valuestring;
        }
    }

    /* Dispatch to handlers */
    dispatch_session_event(session, &event);

    /* Update SendAndWait state */
    if (strcmp(event.type, "assistant.message") == 0 && event.content) {
        pthread_mutex_lock(&session->idle_mutex);
        free(session->last_assistant_content);
        session->last_assistant_content = strdup(event.content);
        pthread_mutex_unlock(&session->idle_mutex);
    } else if (strcmp(event.type, "session.idle") == 0) {
        pthread_mutex_lock(&session->idle_mutex);
        session->idle_signaled = true;
        pthread_cond_signal(&session->idle_cond);
        pthread_mutex_unlock(&session->idle_mutex);
    } else if (strcmp(event.type, "session.error") == 0) {
        pthread_mutex_lock(&session->idle_mutex);
        session->error_signaled = true;
        free(session->error_message);
        session->error_message = event.message ? strdup(event.message) : strdup("Session error");
        pthread_cond_signal(&session->idle_cond);
        pthread_mutex_unlock(&session->idle_mutex);
    }

    free(raw);
}

/* ============================================================================
 * Internal: tool call request handler
 * ============================================================================ */

static cJSON *on_tool_call_request(const char *method, cJSON *params, void *user_data,
                                   int *out_error_code, char **out_error_message)
{
    copilot_client_t *client = (copilot_client_t *)user_data;

    cJSON *session_id_item = cJSON_GetObjectItem(params, "sessionId");
    cJSON *tool_call_id_item = cJSON_GetObjectItem(params, "toolCallId");
    cJSON *tool_name_item = cJSON_GetObjectItem(params, "toolName");
    cJSON *arguments_item = cJSON_GetObjectItem(params, "arguments");

    if (!session_id_item || !tool_call_id_item || !tool_name_item) {
        *out_error_code = -32602;
        *out_error_message = strdup("Invalid tool call params");
        return NULL;
    }

    const char *session_id = session_id_item->valuestring;
    const char *tool_name = tool_name_item->valuestring;
    const char *tool_call_id = tool_call_id_item->valuestring;

    copilot_session_t *session = find_session(client, session_id);
    if (!session) {
        *out_error_code = -32000;
        *out_error_message = strdup("Session not found");
        return NULL;
    }

    /* Find tool handler */
    copilot_tool_handler_fn handler = NULL;
    void *handler_user_data = NULL;
    for (size_t i = 0; i < session->tools_count; i++) {
        if (strcmp(session->tools[i].name, tool_name) == 0) {
            handler = session->tools[i].handler;
            handler_user_data = session->tools[i].user_data;
            break;
        }
    }

    cJSON *result_obj = cJSON_CreateObject();
    cJSON *result_inner = cJSON_CreateObject();

    if (!handler) {
        char msg[256];
        snprintf(msg, sizeof(msg), "Tool '%s' is not supported by this client instance.", tool_name);
        cJSON_AddStringToObject(result_inner, "textResultForLlm", msg);
        cJSON_AddStringToObject(result_inner, "resultType", "failure");
        snprintf(msg, sizeof(msg), "tool '%s' not supported", tool_name);
        cJSON_AddStringToObject(result_inner, "error", msg);
    } else {
        char *args_json = arguments_item ? cJSON_PrintUnformatted(arguments_item) : strdup("{}");

        copilot_tool_invocation_t invocation;
        invocation.session_id = session_id;
        invocation.tool_call_id = tool_call_id;
        invocation.tool_name = tool_name;
        invocation.arguments_json = args_json;

        copilot_tool_result_t tool_result;
        memset(&tool_result, 0, sizeof(tool_result));

        copilot_error_t err = handler(&invocation, handler_user_data, &tool_result);

        if (err != COPILOT_OK || !tool_result.text_result_for_llm) {
            cJSON_AddStringToObject(result_inner, "textResultForLlm",
                "Invoking this tool produced an error. Detailed information is not available.");
            cJSON_AddStringToObject(result_inner, "resultType", "failure");
            if (tool_result.error) {
                cJSON_AddStringToObject(result_inner, "error", tool_result.error);
            }
        } else {
            cJSON_AddStringToObject(result_inner, "textResultForLlm",
                                    tool_result.text_result_for_llm);
            const char *type_str;
            switch (tool_result.result_type) {
            case COPILOT_TOOL_RESULT_FAILURE:  type_str = "failure"; break;
            case COPILOT_TOOL_RESULT_REJECTED: type_str = "rejected"; break;
            case COPILOT_TOOL_RESULT_DENIED:   type_str = "denied"; break;
            default:                           type_str = "success"; break;
            }
            cJSON_AddStringToObject(result_inner, "resultType", type_str);
            if (tool_result.error) {
                cJSON_AddStringToObject(result_inner, "error", tool_result.error);
            }
        }
        free(args_json);
    }

    cJSON_AddItemToObject(result_obj, "result", result_inner);
    return result_obj;
}

/* ============================================================================
 * Internal: permission request handler
 * ============================================================================ */

static cJSON *on_permission_request(const char *method, cJSON *params, void *user_data,
                                    int *out_error_code, char **out_error_message)
{
    copilot_client_t *client = (copilot_client_t *)user_data;

    cJSON *session_id_item = cJSON_GetObjectItem(params, "sessionId");
    cJSON *perm_req_item = cJSON_GetObjectItem(params, "permissionRequest");

    if (!session_id_item || !cJSON_IsString(session_id_item) || !perm_req_item) {
        *out_error_code = -32602;
        *out_error_message = strdup("Invalid permission request params");
        return NULL;
    }

    copilot_session_t *session = find_session(client, session_id_item->valuestring);
    if (!session || !session->permission_handler) {
        /* Deny by default */
        cJSON *result = cJSON_CreateObject();
        cJSON *inner = cJSON_CreateObject();
        cJSON_AddStringToObject(inner, "kind",
            "denied-no-approval-rule-and-could-not-request-from-user");
        cJSON_AddItemToObject(result, "result", inner);
        return result;
    }

    copilot_permission_request_t request;
    memset(&request, 0, sizeof(request));

    cJSON *kind_item = cJSON_GetObjectItem(perm_req_item, "kind");
    if (kind_item && cJSON_IsString(kind_item)) {
        request.kind = kind_item->valuestring;
    }
    cJSON *tcid = cJSON_GetObjectItem(perm_req_item, "toolCallId");
    if (tcid && cJSON_IsString(tcid)) {
        request.tool_call_id = tcid->valuestring;
    }
    char *raw = cJSON_PrintUnformatted(perm_req_item);
    request.raw_json = raw;

    copilot_permission_result_t perm_result;
    memset(&perm_result, 0, sizeof(perm_result));

    copilot_error_t err = session->permission_handler(
        &request, session->session_id, session->permission_user_data, &perm_result);

    free(raw);

    cJSON *result = cJSON_CreateObject();
    cJSON *inner = cJSON_CreateObject();

    if (err != COPILOT_OK) {
        cJSON_AddStringToObject(inner, "kind",
            "denied-no-approval-rule-and-could-not-request-from-user");
    } else {
        const char *kind_str;
        switch (perm_result.kind) {
        case COPILOT_PERMISSION_APPROVED:        kind_str = "approved"; break;
        case COPILOT_PERMISSION_DENIED_BY_RULES: kind_str = "denied-by-rules"; break;
        case COPILOT_PERMISSION_DENIED_BY_USER:  kind_str = "denied-interactively-by-user"; break;
        default:
            kind_str = "denied-no-approval-rule-and-could-not-request-from-user"; break;
        }
        cJSON_AddStringToObject(inner, "kind", kind_str);
    }

    cJSON_AddItemToObject(result, "result", inner);
    return result;
}

/* ============================================================================
 * Internal: user input request handler
 * ============================================================================ */

static cJSON *on_user_input_request(const char *method, cJSON *params, void *user_data,
                                    int *out_error_code, char **out_error_message)
{
    copilot_client_t *client = (copilot_client_t *)user_data;

    cJSON *session_id_item = cJSON_GetObjectItem(params, "sessionId");
    cJSON *question_item = cJSON_GetObjectItem(params, "question");

    if (!session_id_item || !question_item) {
        *out_error_code = -32602;
        *out_error_message = strdup("Invalid user input request params");
        return NULL;
    }

    copilot_session_t *session = find_session(client, session_id_item->valuestring);
    if (!session || !session->user_input_handler) {
        *out_error_code = -32000;
        *out_error_message = strdup("No user input handler registered");
        return NULL;
    }

    copilot_user_input_request_t request;
    memset(&request, 0, sizeof(request));
    request.question = question_item->valuestring;
    request.allow_freeform = true;

    cJSON *choices_item = cJSON_GetObjectItem(params, "choices");
    const char *choices_arr[64];
    if (choices_item && cJSON_IsArray(choices_item)) {
        int count = cJSON_GetArraySize(choices_item);
        if (count > 63) count = 63;
        request.choices_count = count;
        for (int i = 0; i < count; i++) {
            cJSON *c = cJSON_GetArrayItem(choices_item, i);
            choices_arr[i] = cJSON_IsString(c) ? c->valuestring : "";
        }
        choices_arr[count] = NULL;
        request.choices = choices_arr;
    }

    cJSON *freeform_item = cJSON_GetObjectItem(params, "allowFreeform");
    if (freeform_item && cJSON_IsBool(freeform_item)) {
        request.allow_freeform = cJSON_IsTrue(freeform_item);
    }

    copilot_user_input_response_t response;
    memset(&response, 0, sizeof(response));

    copilot_error_t err = session->user_input_handler(
        &request, session->session_id, session->user_input_user_data, &response);

    if (err != COPILOT_OK || !response.answer) {
        *out_error_code = -32000;
        *out_error_message = strdup("User input handler failed");
        free(response.answer);
        return NULL;
    }

    cJSON *result = cJSON_CreateObject();
    cJSON_AddStringToObject(result, "answer", response.answer);
    cJSON_AddBoolToObject(result, "wasFreeform", response.was_freeform);
    free(response.answer);
    return result;
}

/* ============================================================================
 * Internal: hooks invoke handler
 * ============================================================================ */

static cJSON *on_hooks_invoke(const char *method, cJSON *params, void *user_data,
                              int *out_error_code, char **out_error_message)
{
    copilot_client_t *client = (copilot_client_t *)user_data;

    cJSON *session_id_item = cJSON_GetObjectItem(params, "sessionId");
    cJSON *hook_type_item = cJSON_GetObjectItem(params, "hookType");
    cJSON *input_item = cJSON_GetObjectItem(params, "input");

    if (!session_id_item || !hook_type_item) {
        *out_error_code = -32602;
        *out_error_message = strdup("Invalid hooks invoke params");
        return NULL;
    }

    copilot_session_t *session = find_session(client, session_id_item->valuestring);
    if (!session || !session->hook_handler) {
        cJSON *result = cJSON_CreateObject();
        return result;
    }

    char *input_json = input_item ? cJSON_PrintUnformatted(input_item) : strdup("{}");
    char *output_json = session->hook_handler(
        hook_type_item->valuestring, input_json,
        session->session_id, session->hook_user_data);
    free(input_json);

    cJSON *result = cJSON_CreateObject();
    if (output_json) {
        cJSON *output = cJSON_Parse(output_json);
        if (output) {
            cJSON_AddItemToObject(result, "output", output);
        }
        free(output_json);
    }
    return result;
}

/* ============================================================================
 * Internal: spawn CLI process
 * ============================================================================ */

#ifdef _WIN32

static copilot_error_t spawn_cli_process(copilot_client_t *client)
{
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityAttributes = NULL;

    HANDLE stdin_read, stdin_write, stdout_read, stdout_write;

    if (!CreatePipe(&stdin_read, &stdin_write, &sa, 0)) return COPILOT_ERROR_SPAWN_FAILED;
    SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0);

    if (!CreatePipe(&stdout_read, &stdout_write, &sa, 0)) {
        CloseHandle(stdin_read);
        CloseHandle(stdin_write);
        return COPILOT_ERROR_SPAWN_FAILED;
    }
    SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);

    /* Build command line */
    const char *cli_path = client->cli_path ? client->cli_path : "copilot";

    /* Estimate command line length */
    size_t cmd_len = strlen(cli_path) + 256;
    for (int i = 0; i < client->extra_args_count; i++) {
        cmd_len += strlen(client->extra_args[i]) + 3;
    }
    char *cmd_line = malloc(cmd_len);
    if (!cmd_line) {
        CloseHandle(stdin_read); CloseHandle(stdin_write);
        CloseHandle(stdout_read); CloseHandle(stdout_write);
        return COPILOT_ERROR_OUT_OF_MEMORY;
    }

    int pos = snprintf(cmd_line, cmd_len, "\"%s\"", cli_path);

    /* Add extra args first */
    for (int i = 0; i < client->extra_args_count; i++) {
        pos += snprintf(cmd_line + pos, cmd_len - pos, " %s", client->extra_args[i]);
    }

    /* Add standard args */
    pos += snprintf(cmd_line + pos, cmd_len - pos,
                    " --headless --no-auto-update --log-level %s --stdio",
                    client->log_level ? client->log_level : "info");

    if (client->github_token) {
        pos += snprintf(cmd_line + pos, cmd_len - pos, " --auth-token-env COPILOT_SDK_AUTH_TOKEN");
    }
    if (!client->use_logged_in_user) {
        pos += snprintf(cmd_line + pos, cmd_len - pos, " --no-auto-login");
    }

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.hStdInput = stdin_read;
    si.hStdOutput = stdout_write;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    si.dwFlags |= STARTF_USESTDHANDLES;

    /* Set environment if github token provided */
    char *env_block = NULL;
    if (client->github_token) {
        char env_var[4096];
        snprintf(env_var, sizeof(env_var), "COPILOT_SDK_AUTH_TOKEN=%s", client->github_token);
        /* For simplicity, pass through environment with additional var */
        SetEnvironmentVariableA("COPILOT_SDK_AUTH_TOKEN", client->github_token);
    }

    BOOL success = CreateProcessA(
        NULL, cmd_line, NULL, NULL, TRUE,
        CREATE_NO_WINDOW, env_block, client->cwd,
        &si, &pi);

    free(cmd_line);
    CloseHandle(stdin_read);
    CloseHandle(stdout_write);

    if (!success) {
        CloseHandle(stdin_write);
        CloseHandle(stdout_read);
        return COPILOT_ERROR_SPAWN_FAILED;
    }

    CloseHandle(pi.hThread);
    client->process_handle = pi.hProcess;
    client->stdin_write = stdin_write;
    client->stdout_read = stdout_read;

    return COPILOT_OK;
}

#else /* POSIX */

static copilot_error_t spawn_cli_process(copilot_client_t *client)
{
    int stdin_pipe[2];
    int stdout_pipe[2];

    if (pipe(stdin_pipe) != 0) return COPILOT_ERROR_SPAWN_FAILED;
    if (pipe(stdout_pipe) != 0) {
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        return COPILOT_ERROR_SPAWN_FAILED;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        return COPILOT_ERROR_SPAWN_FAILED;
    }

    if (pid == 0) {
        /* Child process */
        close(stdin_pipe[1]);   /* Close write end of stdin */
        close(stdout_pipe[0]);  /* Close read end of stdout */

        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        /* Leave stderr as-is for debug logs */

        close(stdin_pipe[0]);
        close(stdout_pipe[1]);

        if (client->cwd) {
            if (chdir(client->cwd) != 0) {
                _exit(1);
            }
        }

        if (client->github_token) {
            setenv("COPILOT_SDK_AUTH_TOKEN", client->github_token, 1);
        }
        /* Remove NODE_DEBUG to prevent pollution of stdout */
        unsetenv("NODE_DEBUG");

        const char *cli_path = client->cli_path ? client->cli_path : "copilot";

        /* Build argv: cli_path [extra_args...] --headless --no-auto-update --log-level <level> --stdio */
        int base_args = 7; /* cli_path + 5 standard args + NULL */
        int extra_count = client->extra_args_count;
        int auth_args = 0;
        if (client->github_token) auth_args += 2;
        if (!client->use_logged_in_user) auth_args += 1;

        int total = extra_count + base_args + auth_args;
        char **argv = calloc((size_t)(total + 1), sizeof(char *));
        int idx = 0;

        argv[idx++] = (char *)cli_path;
        for (int i = 0; i < extra_count; i++) {
            argv[idx++] = client->extra_args[i];
        }
        argv[idx++] = "--headless";
        argv[idx++] = "--no-auto-update";
        argv[idx++] = "--log-level";
        argv[idx++] = client->log_level ? client->log_level : "info";
        argv[idx++] = "--stdio";
        if (client->github_token) {
            argv[idx++] = "--auth-token-env";
            argv[idx++] = "COPILOT_SDK_AUTH_TOKEN";
        }
        if (!client->use_logged_in_user) {
            argv[idx++] = "--no-auto-login";
        }
        argv[idx] = NULL;

        execvp(cli_path, argv);
        /* If exec fails */
        _exit(1);
    }

    /* Parent process */
    close(stdin_pipe[0]);   /* Close read end of stdin */
    close(stdout_pipe[1]);  /* Close write end of stdout */

    client->cli_pid = pid;
    client->stdin_write_fd = stdin_pipe[1];
    client->stdout_read_fd = stdout_pipe[0];

    return COPILOT_OK;
}

#endif /* _WIN32 */

/* ============================================================================
 * Internal: verify protocol version
 * ============================================================================ */

static copilot_error_t verify_protocol_version(copilot_client_t *client)
{
    cJSON *params = cJSON_CreateObject();
    cJSON_AddStringToObject(params, "message", "sdk-init");

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(client->rpc, "ping", params, 10000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    cJSON *pv = cJSON_GetObjectItem(result, "protocolVersion");
    if (!pv || !cJSON_IsNumber(pv)) {
        cJSON_Delete(result);
        return COPILOT_ERROR_PROTOCOL_MISMATCH;
    }

    int server_version = pv->valueint;
    cJSON_Delete(result);

    if (server_version != COPILOT_SDK_PROTOCOL_VERSION) {
        fprintf(stderr,
            "SDK protocol version mismatch: SDK expects version %d, "
            "but server reports version %d.\n",
            COPILOT_SDK_PROTOCOL_VERSION, server_version);
        return COPILOT_ERROR_PROTOCOL_MISMATCH;
    }

    return COPILOT_OK;
}

/* ============================================================================
 * Internal: build session create/resume params
 * ============================================================================ */

static cJSON *build_session_params(const copilot_session_config_t *config)
{
    cJSON *params = cJSON_CreateObject();

    if (config->session_id) {
        cJSON_AddStringToObject(params, "sessionId", config->session_id);
    }
    if (config->model) {
        cJSON_AddStringToObject(params, "model", config->model);
    }
    if (config->reasoning_effort) {
        cJSON_AddStringToObject(params, "reasoningEffort", config->reasoning_effort);
    }
    if (config->config_dir) {
        cJSON_AddStringToObject(params, "configDir", config->config_dir);
    }
    if (config->working_directory) {
        cJSON_AddStringToObject(params, "workingDirectory", config->working_directory);
    }
    if (config->streaming) {
        cJSON_AddBoolToObject(params, "streaming", true);
    }

    /* Tools */
    if (config->tools && config->tools_count > 0) {
        cJSON *tools = cJSON_CreateArray();
        for (size_t i = 0; i < config->tools_count; i++) {
            cJSON *tool = cJSON_CreateObject();
            cJSON_AddStringToObject(tool, "name", config->tools[i].name);
            if (config->tools[i].description) {
                cJSON_AddStringToObject(tool, "description", config->tools[i].description);
            }
            if (config->tools[i].parameters_json) {
                cJSON *schema = cJSON_Parse(config->tools[i].parameters_json);
                if (schema) {
                    cJSON_AddItemToObject(tool, "parameters", schema);
                }
            }
            cJSON_AddItemToArray(tools, tool);
        }
        cJSON_AddItemToObject(params, "tools", tools);
    }

    /* Available/excluded tools */
    if (config->available_tools) {
        cJSON *arr = cJSON_CreateArray();
        for (const char **p = config->available_tools; *p; p++) {
            cJSON_AddItemToArray(arr, cJSON_CreateString(*p));
        }
        cJSON_AddItemToObject(params, "availableTools", arr);
    }
    if (config->excluded_tools) {
        cJSON *arr = cJSON_CreateArray();
        for (const char **p = config->excluded_tools; *p; p++) {
            cJSON_AddItemToArray(arr, cJSON_CreateString(*p));
        }
        cJSON_AddItemToObject(params, "excludedTools", arr);
    }

    /* System message */
    if (config->system_message) {
        cJSON *sm = cJSON_CreateObject();
        if (config->system_message->mode) {
            cJSON_AddStringToObject(sm, "mode", config->system_message->mode);
        }
        if (config->system_message->content) {
            cJSON_AddStringToObject(sm, "content", config->system_message->content);
        }
        cJSON_AddItemToObject(params, "systemMessage", sm);
    }

    /* Provider */
    if (config->provider) {
        cJSON *prov = cJSON_CreateObject();
        if (config->provider->type) {
            cJSON_AddStringToObject(prov, "type", config->provider->type);
        }
        if (config->provider->wire_api) {
            cJSON_AddStringToObject(prov, "wireApi", config->provider->wire_api);
        }
        if (config->provider->base_url) {
            cJSON_AddStringToObject(prov, "baseUrl", config->provider->base_url);
        }
        if (config->provider->api_key) {
            cJSON_AddStringToObject(prov, "apiKey", config->provider->api_key);
        }
        if (config->provider->bearer_token) {
            cJSON_AddStringToObject(prov, "bearerToken", config->provider->bearer_token);
        }
        if (config->provider->azure_api_version) {
            cJSON *azure = cJSON_CreateObject();
            cJSON_AddStringToObject(azure, "apiVersion", config->provider->azure_api_version);
            cJSON_AddItemToObject(prov, "azure", azure);
        }
        cJSON_AddItemToObject(params, "provider", prov);
    }

    /* Infinite sessions */
    if (config->infinite_sessions) {
        cJSON *inf = cJSON_CreateObject();
        if (config->infinite_sessions->has_enabled) {
            cJSON_AddBoolToObject(inf, "enabled", config->infinite_sessions->enabled);
        }
        if (config->infinite_sessions->has_background_threshold) {
            cJSON_AddNumberToObject(inf, "backgroundCompactionThreshold",
                                    config->infinite_sessions->background_compaction_threshold);
        }
        if (config->infinite_sessions->has_buffer_threshold) {
            cJSON_AddNumberToObject(inf, "bufferExhaustionThreshold",
                                    config->infinite_sessions->buffer_exhaustion_threshold);
        }
        cJSON_AddItemToObject(params, "infiniteSessions", inf);
    }

    /* Handler flags */
    if (config->on_permission_request) {
        cJSON_AddBoolToObject(params, "requestPermission", true);
    }
    if (config->on_user_input_request) {
        cJSON_AddBoolToObject(params, "requestUserInput", true);
    }
    if (config->on_hook) {
        cJSON_AddBoolToObject(params, "hooks", true);
    }

    return params;
}

/* ============================================================================
 * Internal: create session object from RPC response
 * ============================================================================ */

static copilot_session_t *create_session_from_response(
    copilot_client_t *client,
    cJSON *response,
    const copilot_session_config_t *config)
{
    cJSON *sid = cJSON_GetObjectItem(response, "sessionId");
    if (!sid || !cJSON_IsString(sid)) return NULL;

    copilot_session_t *session = calloc(1, sizeof(copilot_session_t));
    if (!session) return NULL;

    session->session_id = strdup(sid->valuestring);
    session->rpc = client->rpc;
    session->owner = client;
    session->handlers = NULL;
    session->next_handler_id = 0;
    pthread_mutex_init(&session->handlers_mutex, NULL);
    pthread_mutex_init(&session->idle_mutex, NULL);
    pthread_cond_init(&session->idle_cond, NULL);
    session->idle_signaled = false;
    session->error_signaled = false;
    session->error_message = NULL;
    session->last_assistant_content = NULL;

    cJSON *wp = cJSON_GetObjectItem(response, "workspacePath");
    if (wp && cJSON_IsString(wp)) {
        session->workspace_path = strdup(wp->valuestring);
    }

    /* Copy tool definitions and handlers */
    if (config && config->tools && config->tools_count > 0) {
        session->tools = calloc(config->tools_count, sizeof(copilot_tool_t));
        session->tools_count = config->tools_count;
        for (size_t i = 0; i < config->tools_count; i++) {
            session->tools[i].name = config->tools[i].name;
            session->tools[i].description = config->tools[i].description;
            session->tools[i].parameters_json = config->tools[i].parameters_json;
            session->tools[i].handler = config->tools[i].handler;
            session->tools[i].user_data = config->tools[i].user_data;
        }
    }

    /* Copy handler callbacks */
    if (config) {
        session->permission_handler = config->on_permission_request;
        session->permission_user_data = config->permission_user_data;
        session->user_input_handler = config->on_user_input_request;
        session->user_input_user_data = config->user_input_user_data;
        session->hook_handler = config->on_hook;
        session->hook_user_data = config->hook_user_data;
    }

    return session;
}

/* ============================================================================
 * Public API: Client
 * ============================================================================ */

copilot_client_t *copilot_client_create(const copilot_client_options_t *options)
{
    copilot_client_t *client = calloc(1, sizeof(copilot_client_t));
    if (!client) return NULL;

    copilot_client_options_t opts = options ? *options : copilot_client_options_default();

    client->cli_path = opts.cli_path ? strdup(opts.cli_path) : NULL;
    client->cwd = opts.cwd ? strdup(opts.cwd) : NULL;
    client->log_level = strdup(opts.log_level ? opts.log_level : "info");
    client->use_stdio = opts.use_stdio;
    client->auto_start = opts.auto_start;
    client->auto_restart = opts.auto_restart;
    client->github_token = opts.github_token ? strdup(opts.github_token) : NULL;
    client->use_logged_in_user = opts.use_logged_in_user;

    /* Copy extra args */
    if (opts.extra_args) {
        int count = 0;
        while (opts.extra_args[count]) count++;
        client->extra_args = calloc((size_t)(count + 1), sizeof(char *));
        for (int i = 0; i < count; i++) {
            client->extra_args[i] = strdup(opts.extra_args[i]);
        }
        client->extra_args_count = count;
    }

    client->state = COPILOT_STATE_DISCONNECTED;
    client->rpc = NULL;
    client->sessions = NULL;
    pthread_mutex_init(&client->sessions_mutex, NULL);

#ifdef _WIN32
    client->process_handle = NULL;
    client->stdin_write = NULL;
    client->stdout_read = NULL;
#else
    client->cli_pid = 0;
    client->stdin_write_fd = -1;
    client->stdout_read_fd = -1;
#endif

    return client;
}

copilot_error_t copilot_client_start(copilot_client_t *client)
{
    if (!client) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (client->state == COPILOT_STATE_CONNECTED) return COPILOT_ERROR_ALREADY_STARTED;

    client->state = COPILOT_STATE_CONNECTING;

    /* Spawn CLI process */
    copilot_error_t err = spawn_cli_process(client);
    if (err != COPILOT_OK) {
        client->state = COPILOT_STATE_ERROR;
        return err;
    }

    /* Create JSON-RPC client */
#ifdef _WIN32
    int write_fd = _open_osfhandle((intptr_t)client->stdin_write, _O_WRONLY);
    int read_fd = _open_osfhandle((intptr_t)client->stdout_read, _O_RDONLY);
    client->rpc = json_rpc_client_create(write_fd, read_fd);
#else
    client->rpc = json_rpc_client_create(client->stdin_write_fd, client->stdout_read_fd);
#endif

    if (!client->rpc) {
        client->state = COPILOT_STATE_ERROR;
        return COPILOT_ERROR_OUT_OF_MEMORY;
    }

    /* Register handlers */
    json_rpc_client_set_notification_handler(client->rpc, "session.event",
                                             on_session_event_notification, client);
    json_rpc_client_set_request_handler(client->rpc, "tool.call",
                                        on_tool_call_request, client);
    json_rpc_client_set_request_handler(client->rpc, "permission.request",
                                        on_permission_request, client);
    json_rpc_client_set_request_handler(client->rpc, "userInput.request",
                                        on_user_input_request, client);
    json_rpc_client_set_request_handler(client->rpc, "hooks.invoke",
                                        on_hooks_invoke, client);

    /* Start reader thread */
    if (json_rpc_client_start(client->rpc) != 0) {
        json_rpc_client_free(client->rpc);
        client->rpc = NULL;
        client->state = COPILOT_STATE_ERROR;
        return COPILOT_ERROR_IO;
    }

    /* Verify protocol version */
    err = verify_protocol_version(client);
    if (err != COPILOT_OK) {
        json_rpc_client_stop(client->rpc);
        json_rpc_client_free(client->rpc);
        client->rpc = NULL;
        client->state = COPILOT_STATE_ERROR;
        return err;
    }

    client->state = COPILOT_STATE_CONNECTED;
    return COPILOT_OK;
}

copilot_error_t copilot_client_stop(copilot_client_t *client)
{
    if (!client) return COPILOT_ERROR_INVALID_ARGUMENT;

    /* Destroy all sessions */
    pthread_mutex_lock(&client->sessions_mutex);
    copilot_session_t *s = client->sessions;
    while (s) {
        copilot_session_t *next = s->next;
        /* Best-effort destroy */
        if (client->rpc) {
            cJSON *params = cJSON_CreateObject();
            cJSON_AddStringToObject(params, "sessionId", s->session_id);
            int ec = 0; char *em = NULL;
            cJSON *r = json_rpc_client_request(client->rpc, "session.destroy",
                                               params, 5000, &ec, &em);
            cJSON_Delete(params);
            if (r) cJSON_Delete(r);
            free(em);
        }
        s = next;
    }
    pthread_mutex_unlock(&client->sessions_mutex);

    /* Stop RPC client */
    if (client->rpc) {
        json_rpc_client_stop(client->rpc);
        json_rpc_client_free(client->rpc);
        client->rpc = NULL;
    }

    /* Kill CLI process */
#ifdef _WIN32
    if (client->stdin_write) {
        CloseHandle(client->stdin_write);
        client->stdin_write = NULL;
    }
    if (client->process_handle) {
        TerminateProcess(client->process_handle, 0);
        WaitForSingleObject(client->process_handle, 5000);
        CloseHandle(client->process_handle);
        client->process_handle = NULL;
    }
#else
    if (client->stdin_write_fd >= 0) {
        close(client->stdin_write_fd);
        client->stdin_write_fd = -1;
    }
    if (client->cli_pid > 0) {
        kill(client->cli_pid, SIGTERM);
        int status;
        waitpid(client->cli_pid, &status, 0);
        client->cli_pid = 0;
    }
#endif

    client->state = COPILOT_STATE_DISCONNECTED;
    return COPILOT_OK;
}

void copilot_client_free(copilot_client_t *client)
{
    if (!client) return;

    /* Free sessions */
    copilot_session_t *s = client->sessions;
    while (s) {
        copilot_session_t *next = s->next;
        copilot_session_free(s);
        s = next;
    }

    free(client->cli_path);
    free(client->cwd);
    free(client->log_level);
    free(client->github_token);

    if (client->extra_args) {
        for (int i = 0; i < client->extra_args_count; i++) {
            free(client->extra_args[i]);
        }
        free(client->extra_args);
    }

    pthread_mutex_destroy(&client->sessions_mutex);
    free(client);
}

copilot_connection_state_t copilot_client_get_state(const copilot_client_t *client)
{
    return client ? client->state : COPILOT_STATE_DISCONNECTED;
}

copilot_error_t copilot_client_ping(
    copilot_client_t *client,
    const char *message,
    copilot_ping_response_t *out)
{
    if (!client || !out) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (!client->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    cJSON *params = cJSON_CreateObject();
    if (message) {
        cJSON_AddStringToObject(params, "message", message);
    }

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(client->rpc, "ping", params, 10000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    memset(out, 0, sizeof(*out));

    cJSON *msg = cJSON_GetObjectItem(result, "message");
    out->message = msg && cJSON_IsString(msg) ? strdup(msg->valuestring) : strdup("");

    cJSON *ts = cJSON_GetObjectItem(result, "timestamp");
    out->timestamp = ts && cJSON_IsNumber(ts) ? (int64_t)ts->valuedouble : 0;

    cJSON *pv = cJSON_GetObjectItem(result, "protocolVersion");
    out->protocol_version = pv && cJSON_IsNumber(pv) ? pv->valueint : -1;

    cJSON_Delete(result);
    return COPILOT_OK;
}

void copilot_ping_response_free(copilot_ping_response_t *response)
{
    if (!response) return;
    free(response->message);
    response->message = NULL;
}

copilot_error_t copilot_client_list_models(
    copilot_client_t *client,
    copilot_model_list_t *out)
{
    if (!client || !out) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (!client->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    cJSON *params = cJSON_CreateObject();
    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(client->rpc, "models.list", params, 30000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    memset(out, 0, sizeof(*out));

    cJSON *models = cJSON_GetObjectItem(result, "models");
    if (models && cJSON_IsArray(models)) {
        int count = cJSON_GetArraySize(models);
        out->models = calloc((size_t)count, sizeof(copilot_model_info_t));
        out->count = (size_t)count;

        for (int i = 0; i < count; i++) {
            cJSON *m = cJSON_GetArrayItem(models, i);
            cJSON *id = cJSON_GetObjectItem(m, "id");
            cJSON *name = cJSON_GetObjectItem(m, "name");
            cJSON *caps = cJSON_GetObjectItem(m, "capabilities");

            out->models[i].id = id && cJSON_IsString(id) ? strdup(id->valuestring) : strdup("");
            out->models[i].name = name && cJSON_IsString(name) ? strdup(name->valuestring) : strdup("");

            if (caps) {
                cJSON *supports = cJSON_GetObjectItem(caps, "supports");
                if (supports) {
                    cJSON *v = cJSON_GetObjectItem(supports, "vision");
                    out->models[i].supports_vision = v && cJSON_IsTrue(v);
                    cJSON *re = cJSON_GetObjectItem(supports, "reasoningEffort");
                    out->models[i].supports_reasoning_effort = re && cJSON_IsTrue(re);
                }
                cJSON *limits = cJSON_GetObjectItem(caps, "limits");
                if (limits) {
                    cJSON *mctw = cJSON_GetObjectItem(limits, "max_context_window_tokens");
                    out->models[i].max_context_window_tokens =
                        mctw && cJSON_IsNumber(mctw) ? mctw->valueint : 0;
                }
            }
        }
    }

    cJSON_Delete(result);
    return COPILOT_OK;
}

void copilot_model_list_free(copilot_model_list_t *list)
{
    if (!list) return;
    for (size_t i = 0; i < list->count; i++) {
        free(list->models[i].id);
        free(list->models[i].name);
    }
    free(list->models);
    list->models = NULL;
    list->count = 0;
}

copilot_error_t copilot_client_list_sessions(
    copilot_client_t *client,
    copilot_session_list_t *out)
{
    if (!client || !out) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (!client->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    cJSON *params = cJSON_CreateObject();
    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(client->rpc, "session.list", params, 10000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    memset(out, 0, sizeof(*out));

    cJSON *sessions = cJSON_GetObjectItem(result, "sessions");
    if (sessions && cJSON_IsArray(sessions)) {
        int count = cJSON_GetArraySize(sessions);
        out->sessions = calloc((size_t)count, sizeof(copilot_session_metadata_t));
        out->count = (size_t)count;

        for (int i = 0; i < count; i++) {
            cJSON *s = cJSON_GetArrayItem(sessions, i);
            cJSON *sid = cJSON_GetObjectItem(s, "sessionId");
            cJSON *st = cJSON_GetObjectItem(s, "startTime");
            cJSON *mt = cJSON_GetObjectItem(s, "modifiedTime");
            cJSON *sum = cJSON_GetObjectItem(s, "summary");
            cJSON *rem = cJSON_GetObjectItem(s, "isRemote");

            out->sessions[i].session_id = sid && cJSON_IsString(sid) ? strdup(sid->valuestring) : strdup("");
            out->sessions[i].start_time = st && cJSON_IsString(st) ? strdup(st->valuestring) : strdup("");
            out->sessions[i].modified_time = mt && cJSON_IsString(mt) ? strdup(mt->valuestring) : strdup("");
            out->sessions[i].summary = sum && cJSON_IsString(sum) ? strdup(sum->valuestring) : NULL;
            out->sessions[i].is_remote = rem && cJSON_IsTrue(rem);
        }
    }

    cJSON_Delete(result);
    return COPILOT_OK;
}

void copilot_session_list_free(copilot_session_list_t *list)
{
    if (!list) return;
    for (size_t i = 0; i < list->count; i++) {
        free(list->sessions[i].session_id);
        free(list->sessions[i].start_time);
        free(list->sessions[i].modified_time);
        free(list->sessions[i].summary);
    }
    free(list->sessions);
    list->sessions = NULL;
    list->count = 0;
}

copilot_error_t copilot_client_delete_session(
    copilot_client_t *client,
    const char *session_id)
{
    if (!client || !session_id) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (!client->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    cJSON *params = cJSON_CreateObject();
    cJSON_AddStringToObject(params, "sessionId", session_id);

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(client->rpc, "session.delete", params, 10000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    cJSON *success = cJSON_GetObjectItem(result, "success");
    bool ok = success && cJSON_IsTrue(success);
    cJSON_Delete(result);

    if (!ok) return COPILOT_ERROR_RPC;

    /* Remove from local tracking */
    copilot_session_t *s = find_session(client, session_id);
    if (s) {
        remove_session(client, s);
    }

    return COPILOT_OK;
}

/* ============================================================================
 * Public API: Session creation
 * ============================================================================ */

copilot_error_t copilot_client_create_session(
    copilot_client_t *client,
    const copilot_session_config_t *config,
    copilot_session_t **out)
{
    if (!client || !out) return COPILOT_ERROR_INVALID_ARGUMENT;

    /* Auto-start if needed */
    if (client->state != COPILOT_STATE_CONNECTED && client->auto_start) {
        copilot_error_t err = copilot_client_start(client);
        if (err != COPILOT_OK) return err;
    }
    if (!client->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    copilot_session_config_t default_config = copilot_session_config_default();
    if (!config) config = &default_config;

    cJSON *params = build_session_params(config);

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(client->rpc, "session.create", params, 30000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    copilot_session_t *session = create_session_from_response(client, result, config);
    cJSON_Delete(result);

    if (!session) return COPILOT_ERROR_OUT_OF_MEMORY;

    add_session(client, session);
    *out = session;
    return COPILOT_OK;
}

copilot_error_t copilot_client_resume_session(
    copilot_client_t *client,
    const char *session_id,
    const copilot_session_config_t *config,
    copilot_session_t **out)
{
    if (!client || !session_id || !out) return COPILOT_ERROR_INVALID_ARGUMENT;

    /* Auto-start if needed */
    if (client->state != COPILOT_STATE_CONNECTED && client->auto_start) {
        copilot_error_t err = copilot_client_start(client);
        if (err != COPILOT_OK) return err;
    }
    if (!client->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    copilot_session_config_t default_config = copilot_session_config_default();
    if (!config) config = &default_config;

    cJSON *params = build_session_params(config);
    cJSON_AddStringToObject(params, "sessionId", session_id);

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(client->rpc, "session.resume", params, 30000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    copilot_session_t *session = create_session_from_response(client, result, config);
    cJSON_Delete(result);

    if (!session) return COPILOT_ERROR_OUT_OF_MEMORY;

    add_session(client, session);
    *out = session;
    return COPILOT_OK;
}

/* ============================================================================
 * Public API: Session
 * ============================================================================ */

const char *copilot_session_get_id(const copilot_session_t *session)
{
    return session ? session->session_id : NULL;
}

const char *copilot_session_get_workspace_path(const copilot_session_t *session)
{
    return session ? session->workspace_path : NULL;
}

copilot_error_t copilot_session_send(
    copilot_session_t *session,
    const copilot_message_options_t *options,
    char **out_message_id)
{
    if (!session || !options || !options->prompt) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (!session->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    cJSON *params = cJSON_CreateObject();
    cJSON_AddStringToObject(params, "sessionId", session->session_id);
    cJSON_AddStringToObject(params, "prompt", options->prompt);

    if (options->mode) {
        cJSON_AddStringToObject(params, "mode", options->mode);
    }

    /* Response format */
    if (options->response_format != COPILOT_RESPONSE_FORMAT_TEXT) {
        switch (options->response_format) {
        case COPILOT_RESPONSE_FORMAT_IMAGE:
            cJSON_AddStringToObject(params, "responseFormat", "image");
            break;
        case COPILOT_RESPONSE_FORMAT_JSON_OBJECT:
            cJSON_AddStringToObject(params, "responseFormat", "json_object");
            break;
        default:
            break;
        }
    }

    /* Image generation options */
    if (options->image_options) {
        cJSON *img_opts = cJSON_CreateObject();
        if (options->image_options->size)
            cJSON_AddStringToObject(img_opts, "size", options->image_options->size);
        if (options->image_options->quality)
            cJSON_AddStringToObject(img_opts, "quality", options->image_options->quality);
        if (options->image_options->style)
            cJSON_AddStringToObject(img_opts, "style", options->image_options->style);
        cJSON_AddItemToObject(params, "imageOptions", img_opts);
    }

    /* Attachments */
    if (options->attachments && options->attachments_count > 0) {
        cJSON *arr = cJSON_CreateArray();
        for (size_t i = 0; i < options->attachments_count; i++) {
            const copilot_attachment_t *a = &options->attachments[i];
            cJSON *att = cJSON_CreateObject();

            switch (a->type) {
            case COPILOT_ATTACHMENT_FILE:
                cJSON_AddStringToObject(att, "type", "file");
                cJSON_AddStringToObject(att, "path", a->path);
                break;
            case COPILOT_ATTACHMENT_DIRECTORY:
                cJSON_AddStringToObject(att, "type", "directory");
                cJSON_AddStringToObject(att, "path", a->path);
                break;
            case COPILOT_ATTACHMENT_SELECTION:
                cJSON_AddStringToObject(att, "type", "selection");
                if (a->file_path) cJSON_AddStringToObject(att, "filePath", a->file_path);
                if (a->display_name) cJSON_AddStringToObject(att, "displayName", a->display_name);
                if (a->text) cJSON_AddStringToObject(att, "text", a->text);
                break;
            }

            if (a->display_name && a->type != COPILOT_ATTACHMENT_SELECTION) {
                cJSON_AddStringToObject(att, "displayName", a->display_name);
            }

            cJSON_AddItemToArray(arr, att);
        }
        cJSON_AddItemToObject(params, "attachments", arr);
    }

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(session->rpc, "session.send", params, 30000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (!result) {
        free(err_msg);
        return COPILOT_ERROR_RPC;
    }

    if (out_message_id) {
        cJSON *mid = cJSON_GetObjectItem(result, "messageId");
        *out_message_id = mid && cJSON_IsString(mid) ? strdup(mid->valuestring) : NULL;
    }

    cJSON_Delete(result);
    return COPILOT_OK;
}

copilot_error_t copilot_session_send_and_wait(
    copilot_session_t *session,
    const copilot_message_options_t *options,
    int timeout_ms,
    char **out_content)
{
    if (!session || !options) return COPILOT_ERROR_INVALID_ARGUMENT;

    if (timeout_ms <= 0) timeout_ms = 60000;

    /* Reset idle state before sending */
    pthread_mutex_lock(&session->idle_mutex);
    session->idle_signaled = false;
    session->error_signaled = false;
    free(session->error_message);
    session->error_message = NULL;
    free(session->last_assistant_content);
    session->last_assistant_content = NULL;
    pthread_mutex_unlock(&session->idle_mutex);

    /* Send message */
    copilot_error_t err = copilot_session_send(session, options, NULL);
    if (err != COPILOT_OK) return err;

    /* Wait for idle or error */
    struct timespec ts;
#ifdef _WIN32
    struct timespec now;
    timespec_get(&now, TIME_UTC);
    ts.tv_sec = now.tv_sec + timeout_ms / 1000;
    ts.tv_nsec = now.tv_nsec + (timeout_ms % 1000) * 1000000L;
#else
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
#endif
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&session->idle_mutex);
    while (!session->idle_signaled && !session->error_signaled) {
        int rc = pthread_cond_timedwait(&session->idle_cond, &session->idle_mutex, &ts);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&session->idle_mutex);
            return COPILOT_ERROR_TIMEOUT;
        }
    }

    if (session->error_signaled) {
        pthread_mutex_unlock(&session->idle_mutex);
        return COPILOT_ERROR_SESSION_ERROR;
    }

    if (out_content && session->last_assistant_content) {
        *out_content = strdup(session->last_assistant_content);
    } else if (out_content) {
        *out_content = NULL;
    }

    pthread_mutex_unlock(&session->idle_mutex);
    return COPILOT_OK;
}

int copilot_session_on(
    copilot_session_t *session,
    copilot_session_event_handler_fn handler,
    void *user_data)
{
    return copilot_session_on_type(session, NULL, handler, user_data);
}

int copilot_session_on_type(
    copilot_session_t *session,
    const char *event_type,
    copilot_session_event_handler_fn handler,
    void *user_data)
{
    if (!session || !handler) return -1;

    session_handler_entry_t *entry = calloc(1, sizeof(session_handler_entry_t));
    if (!entry) return -1;

    pthread_mutex_lock(&session->handlers_mutex);
    int id = session->next_handler_id++;
    entry->id = id;
    entry->event_type_filter = event_type ? event_type : NULL;
    entry->handler = handler;
    entry->user_data = user_data;
    entry->next = session->handlers;
    session->handlers = entry;
    pthread_mutex_unlock(&session->handlers_mutex);

    return id;
}

void copilot_session_off(copilot_session_t *session, int handler_id)
{
    if (!session) return;

    pthread_mutex_lock(&session->handlers_mutex);
    session_handler_entry_t **pp = &session->handlers;
    while (*pp) {
        if ((*pp)->id == handler_id) {
            session_handler_entry_t *entry = *pp;
            *pp = entry->next;
            free(entry);
            break;
        }
        pp = &(*pp)->next;
    }
    pthread_mutex_unlock(&session->handlers_mutex);
}

copilot_error_t copilot_session_destroy(copilot_session_t *session)
{
    if (!session) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (!session->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    cJSON *params = cJSON_CreateObject();
    cJSON_AddStringToObject(params, "sessionId", session->session_id);

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(session->rpc, "session.destroy", params, 10000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (result) cJSON_Delete(result);
    free(err_msg);

    /* Remove from client tracking */
    if (session->owner) {
        remove_session(session->owner, session);
    }

    /* Clear handlers */
    pthread_mutex_lock(&session->handlers_mutex);
    session_handler_entry_t *h = session->handlers;
    while (h) {
        session_handler_entry_t *next = h->next;
        free(h);
        h = next;
    }
    session->handlers = NULL;
    pthread_mutex_unlock(&session->handlers_mutex);

    return COPILOT_OK;
}

void copilot_session_free(copilot_session_t *session)
{
    if (!session) return;

    free(session->session_id);
    free(session->workspace_path);
    free(session->tools);
    free(session->last_assistant_content);
    free(session->error_message);

    /* Free remaining handlers */
    session_handler_entry_t *h = session->handlers;
    while (h) {
        session_handler_entry_t *next = h->next;
        free(h);
        h = next;
    }

    pthread_mutex_destroy(&session->handlers_mutex);
    pthread_mutex_destroy(&session->idle_mutex);
    pthread_cond_destroy(&session->idle_cond);

    free(session);
}

copilot_error_t copilot_session_abort(copilot_session_t *session)
{
    if (!session) return COPILOT_ERROR_INVALID_ARGUMENT;
    if (!session->rpc) return COPILOT_ERROR_NOT_CONNECTED;

    cJSON *params = cJSON_CreateObject();
    cJSON_AddStringToObject(params, "sessionId", session->session_id);

    int err_code = 0;
    char *err_msg = NULL;
    cJSON *result = json_rpc_client_request(session->rpc, "session.abort", params, 10000,
                                            &err_code, &err_msg);
    cJSON_Delete(params);

    if (result) cJSON_Delete(result);
    free(err_msg);

    return COPILOT_OK;
}
