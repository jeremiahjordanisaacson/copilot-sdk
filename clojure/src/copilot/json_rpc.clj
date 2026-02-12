;;;; ---------------------------------------------------------------------------
;;;;  Copyright (c) Microsoft Corporation. All rights reserved.
;;;; ---------------------------------------------------------------------------
;;;;
;;;; Minimal JSON-RPC 2.0 client for stdio / TCP transport.
;;;;
;;;; Uses Content-Length header framing:
;;;;   Content-Length: N\r\n\r\n{json-payload}
;;;;
;;;; A background reader thread parses incoming messages and dispatches them:
;;;;   - Responses   -> delivered to the pending-request promise
;;;;   - Notifications -> delivered via the notification handler
;;;;   - Requests     -> dispatched to registered request handlers

(ns copilot.json-rpc
  "JSON-RPC 2.0 client with Content-Length framing over stdio or TCP streams."
  (:require [cheshire.core :as json]
            [clojure.core.async :as async])
  (:import [java.io
            BufferedInputStream BufferedOutputStream
            InputStream OutputStream IOException]
           [java.net Socket]
           [java.nio.charset StandardCharsets]
           [java.util UUID]
           [java.util.concurrent ConcurrentHashMap]))

;; ============================================================================
;; Wire format helpers
;; ============================================================================

(defn- write-message!
  "Write a JSON-RPC message with Content-Length header framing.
  Thread-safe via the write-lock."
  [^OutputStream out write-lock msg]
  (let [payload  (json/generate-string msg {:key-fn name})
        payload-bytes (.getBytes ^String payload StandardCharsets/UTF_8)
        header   (str "Content-Length: " (alength payload-bytes) "\r\n\r\n")
        header-bytes (.getBytes ^String header StandardCharsets/UTF_8)]
    (locking write-lock
      (.write out header-bytes)
      (.write out payload-bytes)
      (.flush out))))

(defn- read-exact!
  "Read exactly `n` bytes from `in`. Returns a byte array or nil on EOF."
  [^InputStream in ^long n]
  (let [buf (byte-array n)]
    (loop [offset 0]
      (if (>= offset n)
        buf
        (let [read (.read in buf offset (- n offset))]
          (if (neg? read)
            nil
            (recur (+ offset read))))))))

(defn- read-line-crlf
  "Read bytes until \\r\\n from the input stream. Returns a String or nil on EOF."
  [^InputStream in]
  (let [sb (StringBuilder.)]
    (loop [prev-byte -1]
      (let [b (.read in)]
        (cond
          (neg? b)
          (if (pos? (.length sb)) (.toString sb) nil)

          (and (== prev-byte (int \return)) (== b (int \newline)))
          ;; strip trailing \r
          (let [s (.toString sb)]
            (subs s 0 (max 0 (dec (count s)))))

          :else
          (do (.append sb (char b))
              (recur b)))))))

(defn- read-message!
  "Read a single JSON-RPC message (Content-Length framed) from `in`.
  Returns parsed map or nil on EOF / parse error."
  [^InputStream in]
  (when-let [header-line (read-line-crlf in)]
    (when (.startsWith ^String header-line "Content-Length:")
      (let [content-length (Long/parseLong (.trim (subs header-line
                                                        (count "Content-Length:"))))
            ;; consume the blank line after header
            _ (read-line-crlf in)]
        (when-let [content-bytes (read-exact! in content-length)]
          (let [content (String. ^bytes content-bytes StandardCharsets/UTF_8)]
            (json/parse-string content true)))))))

;; ============================================================================
;; JSON-RPC Client
;; ============================================================================

(defprotocol IJsonRpcClient
  "Protocol for a JSON-RPC 2.0 client."
  (start! [this] "Start the background reader loop.")
  (stop!  [this] "Stop the reader loop and clean up.")
  (request! [this method params] [this method params timeout-ms]
    "Send a request and return a promise that will be delivered with the result.")
  (notify! [this method params]
    "Send a notification (no response expected).")
  (set-notification-handler! [this handler]
    "Set a function (fn [method params]) for server-sent notifications.")
  (set-request-handler! [this method handler]
    "Register a handler (fn [params] -> result-map) for server-sent requests."))

(defrecord JsonRpcClient
    [^InputStream in-stream
     ^OutputStream out-stream
     write-lock
     ;; ConcurrentHashMap<String, promise>
     ^ConcurrentHashMap pending-requests
     ;; atom<fn | nil>
     notification-handler-atom
     ;; ConcurrentHashMap<String, fn>
     ^ConcurrentHashMap request-handlers
     ;; atom<boolean>
     running-atom
     ;; atom<Thread | nil>
     reader-thread-atom]

  IJsonRpcClient

  (start! [this]
    (when (compare-and-set! running-atom false true)
      (let [reader (Thread.
                    (fn []
                      (try
                        (loop []
                          (when @running-atom
                            (when-let [msg (read-message! in-stream)]
                              (handle-incoming this msg)
                              (recur))))
                        (catch IOException _e
                          ;; stream closed, expected during shutdown
                          nil)
                        (catch Exception e
                          (when @running-atom
                            (.printStackTrace e)))))
                    "copilot-jsonrpc-reader")]
        (.setDaemon reader true)
        (reset! reader-thread-atom reader)
        (.start reader)))
    this)

  (stop! [_this]
    (reset! running-atom false)
    ;; Deliver errors to any pending requests
    (doseq [^java.util.Map$Entry entry (.entrySet pending-requests)]
      (deliver (.getValue entry)
               {:error {:code -32000 :message "Client shutting down"}}))
    (.clear pending-requests)
    ;; Wait briefly for reader thread to finish
    (when-let [^Thread t @reader-thread-atom]
      (try (.join t 1000) (catch InterruptedException _)))
    nil)

  (request! [this method params]
    (request! this method params 30000))

  (request! [_this method params timeout-ms]
    (let [id      (str (UUID/randomUUID))
          p       (promise)
          message {:jsonrpc "2.0"
                   :id      id
                   :method  method
                   :params  (or params {})}]
      (.put pending-requests id p)
      (write-message! out-stream write-lock message)
      ;; Block with timeout
      (let [result (deref p timeout-ms ::timeout)]
        (.remove pending-requests id)
        (cond
          (= result ::timeout)
          (throw (ex-info (str "JSON-RPC request timed out after " timeout-ms "ms")
                          {:method method :timeout-ms timeout-ms}))

          (and (map? result) (:error result))
          (let [err (:error result)]
            (throw (ex-info (str "JSON-RPC Error " (:code err) ": " (:message err))
                            {:code    (:code err)
                             :message (:message err)
                             :data    (:data err)})))

          :else
          result))))

  (notify! [_this method params]
    (let [message {:jsonrpc "2.0"
                   :method  method
                   :params  (or params {})}]
      (write-message! out-stream write-lock message))
    nil)

  (set-notification-handler! [_this handler]
    (reset! notification-handler-atom handler)
    nil)

  (set-request-handler! [_this method handler]
    (if handler
      (.put request-handlers method handler)
      (.remove request-handlers method))
    nil))

;; ============================================================================
;; Message dispatch (called from reader thread)
;; ============================================================================

(defn- handle-incoming
  "Dispatch an incoming JSON-RPC message."
  [{:keys [^ConcurrentHashMap pending-requests
           notification-handler-atom
           ^ConcurrentHashMap request-handlers
           ^OutputStream out-stream
           write-lock]} msg]
  (cond
    ;; Response to one of our requests
    (and (:id msg) (not (:method msg)))
    (when-let [p (.remove pending-requests (str (:id msg)))]
      (if (:error msg)
        (deliver p {:error (:error msg)})
        (deliver p (:result msg))))

    ;; Notification from server (no id)
    (and (:method msg) (not (:id msg)))
    (when-let [handler @notification-handler-atom]
      (try
        (handler (:method msg) (:params msg))
        (catch Exception e
          (.printStackTrace e))))

    ;; Request from server (has both method and id)
    (and (:method msg) (:id msg))
    (let [handler (.get request-handlers (:method msg))]
      (if handler
        ;; Run handler on a separate thread to avoid blocking the reader
        (future
          (try
            (let [result (handler (:params msg))]
              (write-message! out-stream write-lock
                              {:jsonrpc "2.0"
                               :id      (:id msg)
                               :result  (or result {})}))
            (catch Exception e
              (write-message! out-stream write-lock
                              {:jsonrpc "2.0"
                               :id      (:id msg)
                               :error   {:code    -32603
                                          :message (.getMessage e)
                                          :data    nil}}))))
        ;; No handler registered
        (write-message! out-stream write-lock
                        {:jsonrpc "2.0"
                         :id      (:id msg)
                         :error   {:code    -32601
                                    :message (str "Method not found: " (:method msg))
                                    :data    nil}})))))

;; ============================================================================
;; Constructors
;; ============================================================================

(defn create-client
  "Create a new JSON-RPC client from an input stream and output stream.
  Call `(start! client)` to begin reading."
  [^InputStream in-stream ^OutputStream out-stream]
  (map->JsonRpcClient
   {:in-stream               (BufferedInputStream. in-stream)
    :out-stream              (BufferedOutputStream. out-stream)
    :write-lock              (Object.)
    :pending-requests        (ConcurrentHashMap.)
    :notification-handler-atom (atom nil)
    :request-handlers        (ConcurrentHashMap.)
    :running-atom            (atom false)
    :reader-thread-atom      (atom nil)}))

(defn create-tcp-client
  "Create a JSON-RPC client connected to a TCP server at host:port.
  Returns {:client <JsonRpcClient> :socket <Socket>}."
  [^String host ^long port]
  (let [socket (Socket. host port)
        client (create-client (.getInputStream socket)
                              (.getOutputStream socket))]
    {:client client
     :socket socket}))
