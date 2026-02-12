/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot.internal;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.function.BiConsumer;

/**
 * Minimal JSON-RPC 2.0 client for stdio/TCP transport.
 * Uses threads for blocking IO and provides a synchronous + async interface.
 */
public class JsonRpcClient {
    private final InputStream inputStream;
    private final OutputStream outputStream;
    private final ObjectMapper mapper = new ObjectMapper();
    private final ConcurrentHashMap<String, CompletableFuture<Object>> pendingRequests = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, RequestHandler> requestHandlers = new ConcurrentHashMap<>();
    private volatile BiConsumer<String, Map<String, Object>> notificationHandler;
    private volatile boolean running;
    private Thread readThread;
    private final Object writeLock = new Object();
    private final ExecutorService handlerExecutor = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r, "jsonrpc-handler");
        t.setDaemon(true);
        return t;
    });

    @FunctionalInterface
    public interface RequestHandler {
        Map<String, Object> handle(Map<String, Object> params) throws Exception;
    }

    public JsonRpcClient(InputStream inputStream, OutputStream outputStream) {
        this.inputStream = inputStream;
        this.outputStream = outputStream;
    }

    public void start() {
        if (running) return;
        running = true;
        readThread = new Thread(this::readLoop, "jsonrpc-reader");
        readThread.setDaemon(true);
        readThread.start();
    }

    public void stop() {
        running = false;
        handlerExecutor.shutdownNow();
        if (readThread != null) {
            readThread.interrupt();
        }
        // Complete all pending requests with error
        for (var entry : pendingRequests.entrySet()) {
            entry.getValue().completeExceptionally(new IOException("Client stopped"));
        }
        pendingRequests.clear();
    }

    public void setNotificationHandler(BiConsumer<String, Map<String, Object>> handler) {
        this.notificationHandler = handler;
    }

    public void setRequestHandler(String method, RequestHandler handler) {
        if (handler == null) {
            requestHandlers.remove(method);
        } else {
            requestHandlers.put(method, handler);
        }
    }

    /**
     * Send a JSON-RPC request and wait for the response.
     */
    @SuppressWarnings("unchecked")
    public Map<String, Object> request(String method, Object params) throws Exception {
        return request(method, params, 30, TimeUnit.SECONDS);
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> request(String method, Object params, long timeout, TimeUnit unit) throws Exception {
        String requestId = UUID.randomUUID().toString();
        CompletableFuture<Object> future = new CompletableFuture<>();
        pendingRequests.put(requestId, future);

        Map<String, Object> message = Map.of(
            "jsonrpc", "2.0",
            "id", requestId,
            "method", method,
            "params", params != null ? params : Map.of()
        );

        sendMessage(message);

        try {
            Object result = future.get(timeout, unit);
            if (result instanceof Map) {
                return (Map<String, Object>) result;
            }
            return Map.of("result", result);
        } finally {
            pendingRequests.remove(requestId);
        }
    }

    private void sendMessage(Map<String, Object> message) throws JsonProcessingException, IOException {
        String content = mapper.writeValueAsString(message);
        byte[] contentBytes = content.getBytes(StandardCharsets.UTF_8);
        String header = "Content-Length: " + contentBytes.length + "\r\n\r\n";

        synchronized (writeLock) {
            outputStream.write(header.getBytes(StandardCharsets.UTF_8));
            outputStream.write(contentBytes);
            outputStream.flush();
        }
    }

    private void readLoop() {
        try (BufferedInputStream bis = new BufferedInputStream(inputStream)) {
            while (running) {
                Map<String, Object> message = readMessage(bis);
                if (message == null) break;
                handleMessage(message);
            }
        } catch (Exception e) {
            if (running) {
                // Connection error
            }
        }
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> readMessage(InputStream in) throws IOException {
        // Read header line
        StringBuilder headerLine = new StringBuilder();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') break;
            if (c != '\r') headerLine.append((char) c);
        }
        if (c == -1) return null;

        String header = headerLine.toString().trim();
        if (!header.startsWith("Content-Length:")) return null;

        int contentLength = Integer.parseInt(header.substring("Content-Length:".length()).trim());

        // Read empty line
        while ((c = in.read()) != -1) {
            if (c == '\n') break;
        }

        // Read content
        byte[] content = new byte[contentLength];
        int bytesRead = 0;
        while (bytesRead < contentLength) {
            int read = in.read(content, bytesRead, contentLength - bytesRead);
            if (read == -1) throw new EOFException("Unexpected end of stream");
            bytesRead += read;
        }

        return mapper.readValue(content, Map.class);
    }

    @SuppressWarnings("unchecked")
    private void handleMessage(Map<String, Object> message) {
        // Response to our request
        if (message.containsKey("id") && (message.containsKey("result") || message.containsKey("error"))) {
            String id = String.valueOf(message.get("id"));
            CompletableFuture<Object> future = pendingRequests.get(id);
            if (future != null) {
                if (message.containsKey("error")) {
                    Map<String, Object> error = (Map<String, Object>) message.get("error");
                    String errorMsg = String.valueOf(error.getOrDefault("message", "Unknown error"));
                    future.completeExceptionally(new JsonRpcException(
                        ((Number) error.getOrDefault("code", -1)).intValue(),
                        errorMsg
                    ));
                } else {
                    future.complete(message.get("result"));
                }
            }
            return;
        }

        // Notification (no id)
        if (message.containsKey("method") && !message.containsKey("id")) {
            String method = (String) message.get("method");
            Map<String, Object> params = (Map<String, Object>) message.getOrDefault("params", Map.of());
            BiConsumer<String, Map<String, Object>> handler = notificationHandler;
            if (handler != null) {
                handler.accept(method, params);
            }
            return;
        }

        // Incoming request (has both method and id)
        if (message.containsKey("method") && message.containsKey("id")) {
            String method = (String) message.get("method");
            String id = String.valueOf(message.get("id"));
            Map<String, Object> params = (Map<String, Object>) message.getOrDefault("params", Map.of());

            RequestHandler handler = requestHandlers.get(method);
            if (handler == null) {
                handlerExecutor.submit(() -> {
                    try {
                        sendErrorResponse(id, -32601, "Method not found: " + method);
                    } catch (Exception ignored) {}
                });
                return;
            }

            handlerExecutor.submit(() -> {
                try {
                    Map<String, Object> result = handler.handle(params);
                    sendResponse(id, result != null ? result : Map.of());
                } catch (Exception e) {
                    try {
                        sendErrorResponse(id, -32603, e.getMessage());
                    } catch (Exception ignored) {}
                }
            });
        }
    }

    private void sendResponse(String requestId, Map<String, Object> result) throws Exception {
        Map<String, Object> response = Map.of(
            "jsonrpc", "2.0",
            "id", requestId,
            "result", result
        );
        sendMessage(response);
    }

    private void sendErrorResponse(String requestId, int code, String message) throws Exception {
        // Build response manually since Map.of doesn't allow nested mutable maps
        String json = mapper.writeValueAsString(Map.of(
            "jsonrpc", "2.0",
            "id", requestId,
            "error", Map.of("code", code, "message", message)
        ));
        byte[] contentBytes = json.getBytes(StandardCharsets.UTF_8);
        String header = "Content-Length: " + contentBytes.length + "\r\n\r\n";
        synchronized (writeLock) {
            outputStream.write(header.getBytes(StandardCharsets.UTF_8));
            outputStream.write(contentBytes);
            outputStream.flush();
        }
    }

    public static class JsonRpcException extends Exception {
        public final int code;
        public JsonRpcException(int code, String message) {
            super("JSON-RPC Error " + code + ": " + message);
            this.code = code;
        }
    }
}
