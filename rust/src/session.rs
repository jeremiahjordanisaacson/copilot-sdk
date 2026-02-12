// Copyright (c) Microsoft Corporation. All rights reserved.

//! CopilotSession - represents a single conversation session with the Copilot CLI.
//!
//! Sessions are created via [`CopilotClient::create_session`] or resumed via
//! [`CopilotClient::resume_session`]. They maintain conversation state, handle events,
//! and manage tool execution.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde_json::Value;
use tokio::sync::{mpsc, Mutex};

use crate::jsonrpc::JsonRpcClient;
use crate::types::*;
use crate::CopilotError;

// ============================================================================
// Handler Type Aliases
// ============================================================================

/// A tool handler is an async function that takes arguments and invocation info,
/// and returns a result value.
pub type ToolHandler = Arc<
    dyn Fn(
            Value,
            ToolInvocation,
        ) -> Pin<Box<dyn Future<Output = Result<Value, CopilotError>> + Send>>
        + Send
        + Sync,
>;

/// A permission handler is an async function that takes a permission request
/// and returns a permission result.
pub type PermissionHandlerFn = Arc<
    dyn Fn(
            PermissionRequest,
            String,
        ) -> Pin<Box<dyn Future<Output = Result<PermissionRequestResult, CopilotError>> + Send>>
        + Send
        + Sync,
>;

/// A user input handler is an async function that takes a user input request
/// and returns a response.
pub type UserInputHandlerFn = Arc<
    dyn Fn(
            UserInputRequest,
            String,
        ) -> Pin<Box<dyn Future<Output = Result<UserInputResponse, CopilotError>> + Send>>
        + Send
        + Sync,
>;

/// A hooks handler is an async function that takes hook type, input, and session ID,
/// and returns optional output.
pub type HooksHandlerFn = Arc<
    dyn Fn(
            String,
            Value,
            String,
        ) -> Pin<Box<dyn Future<Output = Result<Option<Value>, CopilotError>> + Send>>
        + Send
        + Sync,
>;

/// A session event handler callback.
pub type SessionEventHandlerFn = Arc<dyn Fn(SessionEvent) + Send + Sync>;

/// A typed session event handler for a specific event type.
pub type TypedSessionEventHandlerFn = Arc<dyn Fn(SessionEvent) + Send + Sync>;

// ============================================================================
// Unsubscribe Guard
// ============================================================================

/// An RAII guard that unsubscribes a handler when dropped.
/// Can also be explicitly unsubscribed via `unsubscribe()`.
pub struct Subscription {
    unsubscribe_fn: Option<Box<dyn FnOnce() + Send>>,
}

impl Subscription {
    fn new(f: impl FnOnce() + Send + 'static) -> Self {
        Self {
            unsubscribe_fn: Some(Box::new(f)),
        }
    }

    /// Explicitly unsubscribes this handler.
    pub fn unsubscribe(mut self) {
        if let Some(f) = self.unsubscribe_fn.take() {
            f();
        }
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        if let Some(f) = self.unsubscribe_fn.take() {
            f();
        }
    }
}

// ============================================================================
// CopilotSession
// ============================================================================

/// Represents a single conversation session with the Copilot CLI.
///
/// A session maintains conversation state, handles events, and manages tool execution.
///
/// # Examples
///
/// ```rust,no_run
/// # use copilot_sdk::*;
/// # async fn example() -> Result<(), CopilotError> {
/// let client = CopilotClient::new(CopilotClientOptions::default());
/// let session = client.create_session(SessionConfig::default()).await?;
///
/// // Subscribe to events
/// let sub = session.on(|event| {
///     if event.is_assistant_message() {
///         if let Some(content) = event.assistant_message_content() {
///             println!("Assistant: {}", content);
///         }
///     }
/// }).await;
///
/// // Send a message and wait for completion
/// let response = session.send_and_wait(
///     MessageOptions { prompt: "Hello!".into(), attachments: None, mode: None, response_format: None, image_options: None },
///     None,
/// ).await?;
///
/// // Clean up
/// session.destroy().await?;
/// # Ok(())
/// # }
/// ```
pub struct CopilotSession {
    /// The unique session ID.
    session_id: String,
    /// Path to the session workspace directory (when infinite sessions are enabled).
    workspace_path: Option<String>,
    /// Reference to the JSON-RPC client.
    rpc_client: Arc<JsonRpcClient>,
    /// Registered tool handlers, keyed by tool name.
    tool_handlers: Arc<Mutex<HashMap<String, ToolHandler>>>,
    /// Permission request handler.
    permission_handler: Arc<Mutex<Option<PermissionHandlerFn>>>,
    /// User input request handler.
    user_input_handler: Arc<Mutex<Option<UserInputHandlerFn>>>,
    /// Hooks handler.
    hooks_handler: Arc<Mutex<Option<HooksHandlerFn>>>,
    /// Wildcard event handlers.
    event_handlers: Arc<Mutex<Vec<(u64, SessionEventHandlerFn)>>>,
    /// Typed event handlers, keyed by event type string.
    typed_event_handlers: Arc<Mutex<HashMap<String, Vec<(u64, TypedSessionEventHandlerFn)>>>>,
    /// Counter for handler IDs (for unsubscribe).
    next_handler_id: Arc<Mutex<u64>>,
}

impl CopilotSession {
    /// Creates a new CopilotSession. This is called internally by CopilotClient.
    pub(crate) fn new(
        session_id: String,
        rpc_client: Arc<JsonRpcClient>,
        workspace_path: Option<String>,
    ) -> Self {
        Self {
            session_id,
            workspace_path,
            rpc_client,
            tool_handlers: Arc::new(Mutex::new(HashMap::new())),
            permission_handler: Arc::new(Mutex::new(None)),
            user_input_handler: Arc::new(Mutex::new(None)),
            hooks_handler: Arc::new(Mutex::new(None)),
            event_handlers: Arc::new(Mutex::new(Vec::new())),
            typed_event_handlers: Arc::new(Mutex::new(HashMap::new())),
            next_handler_id: Arc::new(Mutex::new(0)),
        }
    }

    /// Returns the session ID.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Returns the workspace path (when infinite sessions are enabled).
    pub fn workspace_path(&self) -> Option<&str> {
        self.workspace_path.as_deref()
    }

    // ========================================================================
    // Message Sending
    // ========================================================================

    /// Sends a message to this session.
    ///
    /// The message is processed asynchronously. Subscribe to events via `on()`
    /// to receive streaming responses and other session events.
    ///
    /// Returns the message ID.
    pub async fn send(&self, options: MessageOptions) -> Result<String, CopilotError> {
        let params = serde_json::json!({
            "sessionId": self.session_id,
            "prompt": options.prompt,
            "attachments": options.attachments,
            "mode": options.mode,
            "responseFormat": options.response_format,
            "imageOptions": options.image_options,
        });

        let response = self.rpc_client.request("session.send", params, None).await?;
        let message_id = response
            .get("messageId")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        Ok(message_id)
    }

    /// Sends a message and waits until the session becomes idle.
    ///
    /// This combines `send()` with waiting for the `session.idle` event.
    /// Returns the last `assistant.message` event received, or `None`.
    ///
    /// # Arguments
    /// * `options` - The message options
    /// * `timeout` - Optional timeout in milliseconds (defaults to 60000)
    pub async fn send_and_wait(
        &self,
        options: MessageOptions,
        timeout: Option<u64>,
    ) -> Result<Option<SessionEvent>, CopilotError> {
        let effective_timeout = timeout.unwrap_or(60_000);

        // Channel to signal idle or error
        let (idle_tx, mut idle_rx) = mpsc::channel::<Result<(), CopilotError>>(1);
        let last_assistant_message: Arc<Mutex<Option<SessionEvent>>> =
            Arc::new(Mutex::new(None));

        let last_msg_clone = Arc::clone(&last_assistant_message);
        let idle_tx_clone = idle_tx.clone();

        // Register event handler BEFORE calling send to avoid race condition
        let sub = self
            .on(move |event: SessionEvent| {
                if event.is_assistant_message() {
                    let mut msg = last_msg_clone.blocking_lock();
                    *msg = Some(event);
                } else if event.is_session_idle() {
                    let _ = idle_tx_clone.try_send(Ok(()));
                } else if event.is_session_error() {
                    let error_msg = event
                        .error_message()
                        .unwrap_or("Unknown error")
                        .to_string();
                    let _ = idle_tx_clone.try_send(Err(CopilotError::SessionError(error_msg)));
                }
            })
            .await;

        // Send the message
        self.send(options).await?;

        // Wait for idle or timeout
        let result = tokio::time::timeout(
            std::time::Duration::from_millis(effective_timeout),
            idle_rx.recv(),
        )
        .await;

        // Unsubscribe
        sub.unsubscribe();

        match result {
            Ok(Some(Ok(()))) => {
                let msg = last_assistant_message.lock().await;
                Ok(msg.clone())
            }
            Ok(Some(Err(e))) => Err(e),
            Ok(None) => Err(CopilotError::ConnectionClosed),
            Err(_) => Err(CopilotError::Timeout(effective_timeout)),
        }
    }

    // ========================================================================
    // Event Subscription
    // ========================================================================

    /// Subscribes to all events from this session.
    ///
    /// Returns a `Subscription` that unsubscribes when dropped or when
    /// `unsubscribe()` is called.
    pub async fn on<F>(&self, handler: F) -> Subscription
    where
        F: Fn(SessionEvent) + Send + Sync + 'static,
    {
        let handler_id = {
            let mut id = self.next_handler_id.lock().await;
            *id += 1;
            *id
        };

        let handler_arc: SessionEventHandlerFn = Arc::new(handler);
        {
            let mut handlers = self.event_handlers.lock().await;
            handlers.push((handler_id, handler_arc));
        }

        let event_handlers = Arc::clone(&self.event_handlers);
        Subscription::new(move || {
            // We need to use blocking_lock since unsubscribe may be called from Drop
            // in a non-async context
            let mut handlers = event_handlers.blocking_lock();
            handlers.retain(|(id, _)| *id != handler_id);
        })
    }

    /// Subscribes to a specific event type from this session.
    ///
    /// # Arguments
    /// * `event_type` - The event type string (e.g., "assistant.message", "session.idle")
    /// * `handler` - The callback function
    pub async fn on_event<F>(&self, event_type: &str, handler: F) -> Subscription
    where
        F: Fn(SessionEvent) + Send + Sync + 'static,
    {
        let handler_id = {
            let mut id = self.next_handler_id.lock().await;
            *id += 1;
            *id
        };

        let handler_arc: TypedSessionEventHandlerFn = Arc::new(handler);
        let event_type_str = event_type.to_string();
        {
            let mut handlers = self.typed_event_handlers.lock().await;
            handlers
                .entry(event_type_str.clone())
                .or_default()
                .push((handler_id, handler_arc));
        }

        let typed_handlers = Arc::clone(&self.typed_event_handlers);
        let et = event_type_str;
        Subscription::new(move || {
            let mut handlers = typed_handlers.blocking_lock();
            if let Some(list) = handlers.get_mut(&et) {
                list.retain(|(id, _)| *id != handler_id);
            }
        })
    }

    // ========================================================================
    // Event Dispatch (internal, called by CopilotClient)
    // ========================================================================

    /// Dispatches a session event to all registered handlers.
    pub(crate) async fn dispatch_event(&self, event: SessionEvent) {
        // Dispatch to typed handlers
        {
            let handlers = self.typed_event_handlers.lock().await;
            if let Some(list) = handlers.get(&event.event_type) {
                for (_, handler) in list {
                    handler(event.clone());
                }
            }
        }

        // Dispatch to wildcard handlers
        {
            let handlers = self.event_handlers.lock().await;
            for (_, handler) in handlers.iter() {
                handler(event.clone());
            }
        }
    }

    // ========================================================================
    // Tool Registration
    // ========================================================================

    /// Registers a tool handler.
    pub async fn register_tool(&self, name: &str, handler: ToolHandler) {
        let mut handlers = self.tool_handlers.lock().await;
        handlers.insert(name.to_string(), handler);
    }

    /// Registers multiple tool handlers.
    pub async fn register_tools(&self, tools: Vec<(String, ToolHandler)>) {
        let mut handlers = self.tool_handlers.lock().await;
        handlers.clear();
        for (name, handler) in tools {
            handlers.insert(name, handler);
        }
    }

    /// Gets a registered tool handler by name.
    pub(crate) async fn get_tool_handler(&self, name: &str) -> Option<ToolHandler> {
        let handlers = self.tool_handlers.lock().await;
        handlers.get(name).cloned()
    }

    // ========================================================================
    // Permission Handler
    // ========================================================================

    /// Registers a permission request handler.
    pub async fn register_permission_handler(&self, handler: PermissionHandlerFn) {
        let mut h = self.permission_handler.lock().await;
        *h = Some(handler);
    }

    /// Handles an incoming permission request from the server.
    pub(crate) async fn handle_permission_request(
        &self,
        request: Value,
    ) -> Result<PermissionRequestResult, CopilotError> {
        let handler = self.permission_handler.lock().await;
        if let Some(ref h) = *handler {
            let perm_request: PermissionRequest = serde_json::from_value(request)
                .map_err(|e| CopilotError::Serialization(e.to_string()))?;
            h(perm_request, self.session_id.clone()).await
        } else {
            Ok(PermissionRequestResult {
                kind: PermissionResultKind::DeniedNoApprovalRuleAndCouldNotRequestFromUser,
                rules: None,
            })
        }
    }

    // ========================================================================
    // User Input Handler
    // ========================================================================

    /// Registers a user input request handler.
    pub async fn register_user_input_handler(&self, handler: UserInputHandlerFn) {
        let mut h = self.user_input_handler.lock().await;
        *h = Some(handler);
    }

    /// Handles an incoming user input request from the server.
    pub(crate) async fn handle_user_input_request(
        &self,
        request: Value,
    ) -> Result<UserInputResponse, CopilotError> {
        let handler = self.user_input_handler.lock().await;
        if let Some(ref h) = *handler {
            let input_request: UserInputRequest = serde_json::from_value(request)
                .map_err(|e| CopilotError::Serialization(e.to_string()))?;
            h(input_request, self.session_id.clone()).await
        } else {
            Err(CopilotError::NoHandler(
                "User input requested but no handler registered".to_string(),
            ))
        }
    }

    // ========================================================================
    // Hooks Handler
    // ========================================================================

    /// Registers a hooks handler for all hook types.
    pub async fn register_hooks_handler(&self, handler: HooksHandlerFn) {
        let mut h = self.hooks_handler.lock().await;
        *h = Some(handler);
    }

    /// Handles an incoming hooks invocation from the server.
    pub(crate) async fn handle_hooks_invoke(
        &self,
        hook_type: &str,
        input: Value,
    ) -> Result<Option<Value>, CopilotError> {
        let handler = self.hooks_handler.lock().await;
        if let Some(ref h) = *handler {
            h(hook_type.to_string(), input, self.session_id.clone()).await
        } else {
            Ok(None)
        }
    }

    // ========================================================================
    // Session Operations
    // ========================================================================

    /// Retrieves all events and messages from this session's history.
    pub async fn get_messages(&self) -> Result<Vec<SessionEvent>, CopilotError> {
        let params = serde_json::json!({ "sessionId": self.session_id });
        let response = self
            .rpc_client
            .request("session.getMessages", params, None)
            .await?;
        let events: Vec<SessionEvent> = serde_json::from_value(
            response
                .get("events")
                .cloned()
                .unwrap_or(Value::Array(vec![])),
        )
        .map_err(|e| CopilotError::Serialization(e.to_string()))?;
        Ok(events)
    }

    /// Destroys this session and releases all associated resources.
    ///
    /// After calling this method, the session can no longer be used.
    pub async fn destroy(&self) -> Result<(), CopilotError> {
        let params = serde_json::json!({ "sessionId": self.session_id });
        self.rpc_client
            .request("session.destroy", params, None)
            .await?;

        // Clear all handlers
        {
            let mut handlers = self.event_handlers.lock().await;
            handlers.clear();
        }
        {
            let mut handlers = self.typed_event_handlers.lock().await;
            handlers.clear();
        }
        {
            let mut handlers = self.tool_handlers.lock().await;
            handlers.clear();
        }
        {
            let mut handler = self.permission_handler.lock().await;
            *handler = None;
        }
        {
            let mut handler = self.user_input_handler.lock().await;
            *handler = None;
        }

        Ok(())
    }

    /// Aborts the currently processing message in this session.
    pub async fn abort(&self) -> Result<(), CopilotError> {
        let params = serde_json::json!({ "sessionId": self.session_id });
        self.rpc_client
            .request("session.abort", params, None)
            .await?;
        Ok(())
    }
}
