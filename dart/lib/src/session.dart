// Copyright (c) Microsoft Corporation. All rights reserved.

/// Copilot Session - represents a single conversation session with the
/// Copilot CLI.

import 'dart:async';

import 'json_rpc_client.dart';
import 'types.dart';

/// Represents a single conversation session with the Copilot CLI.
///
/// A session maintains conversation state, handles events, and manages tool
/// execution. Sessions are created via [CopilotClient.createSession] or
/// resumed via [CopilotClient.resumeSession].
///
/// ```dart
/// final session = await client.createSession();
///
/// // Listen to all events.
/// session.events.listen((event) {
///   final type = event['type'] as String;
///   if (type == 'assistant.message') {
///     print(event['data']['content']);
///   }
/// });
///
/// // Send and wait for completion.
/// final response = await session.sendAndWait(MessageOptions(prompt: 'Hello!'));
/// print(response?['data']?['content']);
///
/// await session.destroy();
/// ```
class CopilotSession {
  /// Unique identifier for this session.
  final String sessionId;

  /// Path to the session workspace directory (when infinite sessions enabled).
  final String? workspacePath;

  final JsonRpcClient _connection;

  // Event handling.
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Tool handling.
  final Map<String, ToolHandler> _toolHandlers = {};

  // Permission / input / hooks handlers.
  PermissionHandler? _permissionHandler;
  UserInputHandler? _userInputHandler;
  SessionHooks? _hooks;

  /// Creates a new [CopilotSession].
  ///
  /// This constructor is internal. Use [CopilotClient.createSession] or
  /// [CopilotClient.resumeSession] to create sessions.
  CopilotSession({
    required this.sessionId,
    required JsonRpcClient connection,
    this.workspacePath,
  }) : _connection = connection;

  /// Broadcast stream of all session events.
  ///
  /// Each event is a `Map<String, dynamic>` with at least:
  /// - `type`: The event type string (e.g. `assistant.message`, `session.idle`)
  /// - `id`: Event ID
  /// - `timestamp`: ISO 8601 timestamp
  /// - `data`: Event payload
  ///
  /// You can filter by type:
  /// ```dart
  /// session.events
  ///   .where((e) => e['type'] == 'assistant.message')
  ///   .listen((e) => print(e['data']['content']));
  /// ```
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  /// Returns a filtered stream of events matching [eventType].
  ///
  /// Convenience wrapper over [events] with a type filter.
  Stream<Map<String, dynamic>> on(String eventType) {
    return _eventController.stream
        .where((event) => event['type'] == eventType);
  }

  /// Sends a message to this session.
  ///
  /// The message is enqueued for processing. Subscribe to [events] to receive
  /// streaming responses and other session events.
  ///
  /// Returns the message ID of the enqueued message.
  Future<String> send(MessageOptions options) async {
    final response = await _connection.sendRequest('session.send', {
      'sessionId': sessionId,
      'prompt': options.prompt,
      if (options.attachments != null) 'attachments': options.attachments,
      if (options.mode != null) 'mode': options.mode,
      if (options.responseFormat != null)
        'responseFormat': options.responseFormat!.toJson(),
      if (options.imageOptions != null)
        'imageOptions': options.imageOptions!.toJson(),
    }) as Map<String, dynamic>;

    return response['messageId'] as String;
  }

  /// Sends a message and waits until the session becomes idle.
  ///
  /// This combines [send] with waiting for the `session.idle` event.
  /// Events are still delivered to [events] subscribers while waiting.
  ///
  /// Returns the final `assistant.message` event, or `null` if none received.
  ///
  /// [timeout] controls how long to wait (default 60 seconds).
  /// Throws [TimeoutException] if the timeout is reached.
  /// Throws if a `session.error` event is received.
  Future<Map<String, dynamic>?> sendAndWait(
    MessageOptions options, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final idleCompleter = Completer<void>();
    Map<String, dynamic>? lastAssistantMessage;

    // Subscribe BEFORE sending to avoid race conditions.
    final subscription = events.listen((event) {
      final type = event['type'] as String?;
      if (type == 'assistant.message') {
        lastAssistantMessage = event;
      } else if (type == 'session.idle') {
        if (!idleCompleter.isCompleted) {
          idleCompleter.complete();
        }
      } else if (type == 'session.error') {
        if (!idleCompleter.isCompleted) {
          final data = event['data'] as Map<String, dynamic>?;
          final message = data?['message'] as String? ?? 'Unknown error';
          idleCompleter.completeError(Exception(message));
        }
      }
    });

    try {
      await send(options);
      await idleCompleter.future.timeout(timeout);
      return lastAssistantMessage;
    } finally {
      await subscription.cancel();
    }
  }

  /// Retrieves all events/messages from this session's history.
  Future<List<Map<String, dynamic>>> getMessages() async {
    final response = await _connection.sendRequest('session.getMessages', {
      'sessionId': sessionId,
    }) as Map<String, dynamic>;

    return (response['events'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }

  /// Destroys this session and releases all resources.
  ///
  /// After calling this, the session can no longer be used. To continue the
  /// conversation, use [CopilotClient.resumeSession] with the session ID.
  Future<void> destroy() async {
    await _connection.sendRequest('session.destroy', {
      'sessionId': sessionId,
    });
    _toolHandlers.clear();
    _permissionHandler = null;
    _userInputHandler = null;
    _hooks = null;
    await _eventController.close();
  }

  /// Aborts the currently processing message.
  ///
  /// The session remains valid and can continue to be used.
  Future<void> abort() async {
    await _connection.sendRequest('session.abort', {
      'sessionId': sessionId,
    });
  }

  // -------------------------------------------------------------------------
  // Tool Registration (called by CopilotClient)
  // -------------------------------------------------------------------------

  /// Registers tool handlers for this session.
  void registerTools(List<Tool>? tools) {
    _toolHandlers.clear();
    if (tools == null) return;
    for (final tool in tools) {
      _toolHandlers[tool.name] = tool.handler;
    }
  }

  /// Gets a registered tool handler by name.
  ToolHandler? getToolHandler(String name) => _toolHandlers[name];

  /// Registers a permission handler for this session.
  void registerPermissionHandler(PermissionHandler? handler) {
    _permissionHandler = handler;
  }

  /// Registers a user input handler for this session.
  void registerUserInputHandler(UserInputHandler? handler) {
    _userInputHandler = handler;
  }

  /// Registers hook handlers for this session.
  void registerHooks(SessionHooks? hooks) {
    _hooks = hooks;
  }

  // -------------------------------------------------------------------------
  // Internal: Event dispatch (called by CopilotClient)
  // -------------------------------------------------------------------------

  /// Dispatches a session event to all subscribers.
  ///
  /// This is called internally by [CopilotClient] when a `session.event`
  /// notification is received from the server.
  void dispatchEvent(Map<String, dynamic> event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  // -------------------------------------------------------------------------
  // Internal: Permission handling (called by CopilotClient)
  // -------------------------------------------------------------------------

  /// Handles a permission request from the CLI server.
  Future<PermissionRequestResult> handlePermissionRequest(
      dynamic rawRequest) async {
    if (_permissionHandler == null) {
      return const PermissionRequestResult(
        kind: 'denied-no-approval-rule-and-could-not-request-from-user',
      );
    }

    try {
      final request = PermissionRequest.fromJson(
          rawRequest as Map<String, dynamic>);
      return await _permissionHandler!(
        request,
        SessionInvocationContext(sessionId: sessionId),
      );
    } catch (_) {
      return const PermissionRequestResult(
        kind: 'denied-no-approval-rule-and-could-not-request-from-user',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Internal: User input handling (called by CopilotClient)
  // -------------------------------------------------------------------------

  /// Handles a user input request from the CLI server.
  Future<UserInputResponse> handleUserInputRequest(
      UserInputRequest request) async {
    if (_userInputHandler == null) {
      throw Exception('User input requested but no handler registered');
    }

    return await _userInputHandler!(
      request,
      SessionInvocationContext(sessionId: sessionId),
    );
  }

  // -------------------------------------------------------------------------
  // Internal: Hooks handling (called by CopilotClient)
  // -------------------------------------------------------------------------

  /// Handles a hooks invocation from the CLI server.
  Future<dynamic> handleHooksInvoke(String hookType, dynamic input) async {
    if (_hooks == null) return null;

    final context = SessionInvocationContext(sessionId: sessionId);
    final inputMap = input as Map<String, dynamic>? ?? {};

    try {
      switch (hookType) {
        case 'preToolUse':
          if (_hooks!.onPreToolUse == null) return null;
          final result = await _hooks!.onPreToolUse!(
            PreToolUseHookInput.fromJson(inputMap),
            context,
          );
          return result?.toJson();

        case 'postToolUse':
          if (_hooks!.onPostToolUse == null) return null;
          final result = await _hooks!.onPostToolUse!(
            PostToolUseHookInput.fromJson(inputMap),
            context,
          );
          return result?.toJson();

        case 'userPromptSubmitted':
          if (_hooks!.onUserPromptSubmitted == null) return null;
          final result = await _hooks!.onUserPromptSubmitted!(
            UserPromptSubmittedHookInput.fromJson(inputMap),
            context,
          );
          return result?.toJson();

        case 'sessionStart':
          if (_hooks!.onSessionStart == null) return null;
          final result = await _hooks!.onSessionStart!(
            SessionStartHookInput.fromJson(inputMap),
            context,
          );
          return result?.toJson();

        case 'sessionEnd':
          if (_hooks!.onSessionEnd == null) return null;
          final result = await _hooks!.onSessionEnd!(
            SessionEndHookInput.fromJson(inputMap),
            context,
          );
          return result?.toJson();

        case 'errorOccurred':
          if (_hooks!.onErrorOccurred == null) return null;
          final result = await _hooks!.onErrorOccurred!(
            ErrorOccurredHookInput.fromJson(inputMap),
            context,
          );
          return result?.toJson();

        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}
