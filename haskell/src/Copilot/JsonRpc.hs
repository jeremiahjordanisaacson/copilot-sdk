---------------------------------------------------------------------------------------------
--  Copyright (c) Microsoft Corporation. All rights reserved.
---------------------------------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | JSON-RPC 2.0 client for communicating with the Copilot CLI over stdio.
--
-- Messages use Content-Length header framing (the same as LSP):
--
-- @
-- Content-Length: <n>\r\n
-- \r\n
-- <n bytes of JSON>
-- @
--
-- An async reader thread continuously reads from stdout, dispatching
-- responses to pending requests via 'TMVar' and routing notifications
-- and server-initiated requests to registered handlers.
module Copilot.JsonRpc
  ( -- * Client
    JsonRpcClient
  , newJsonRpcClient
  , startClient
  , stopClient

    -- * Sending requests
  , sendRequest
  , sendNotification

    -- * Registering handlers
  , setRequestHandler
  , RequestHandler
  , NotificationHandler

    -- * Errors
  , JsonRpcError (..)
  ) where

import           Control.Concurrent        (forkIO, killThread, ThreadId)
import           Control.Concurrent.STM
import           Control.Exception         (SomeException, catch, try, evaluate)
import           Control.Monad             (forever, void, when)
import qualified Data.Aeson                as Aeson
import           Data.Aeson                (Value (..), object, (.=), (.:), (.:?))
import           Data.Aeson.Types          (Parser, parseMaybe)
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Char8     as BS8
import qualified Data.ByteString.Lazy      as LBS
import qualified Data.Map.Strict           as Map
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.UUID                 (toText)
import           Data.UUID.V4              (nextRandom)
import           System.IO                 (Handle, hFlush, hSetBinaryMode, hSetBuffering, BufferMode(..))

-- | JSON-RPC error from the server.
data JsonRpcError = JsonRpcError
  { jreCode    :: !Int
  , jreMessage :: !Text
  , jreData    :: !(Maybe Value)
  } deriving (Show, Eq)

-- | A notification handler takes method name and params.
type NotificationHandler = Text -> Value -> IO ()

-- | A request handler takes params and returns (result, maybe error).
type RequestHandler = Value -> IO (Either JsonRpcError Value)

-- | JSON-RPC 2.0 client over stdio handles.
data JsonRpcClient = JsonRpcClient
  { jrcStdin          :: !Handle        -- ^ Write to CLI process stdin
  , jrcStdout         :: !Handle        -- ^ Read from CLI process stdout
  , jrcPending        :: !(TVar (Map.Map Text (TMVar (Either JsonRpcError Value))))
  , jrcRequestHandlers :: !(TVar (Map.Map Text RequestHandler))
  , jrcReaderThread   :: !(TVar (Maybe ThreadId))
  , jrcRunning        :: !(TVar Bool)
  , jrcWriteLock      :: !(TMVar ())    -- ^ Mutex for writing to stdin
  }

-- | Create a new JSON-RPC client from stdin/stdout handles of the CLI process.
newJsonRpcClient :: Handle -> Handle -> IO JsonRpcClient
newJsonRpcClient hIn hOut = do
  hSetBinaryMode hIn True
  hSetBinaryMode hOut True
  hSetBuffering hIn NoBuffering
  hSetBuffering hOut NoBuffering
  pending   <- newTVarIO Map.empty
  handlers  <- newTVarIO Map.empty
  readerTid <- newTVarIO Nothing
  running   <- newTVarIO False
  writeLock <- newTMVarIO ()
  pure JsonRpcClient
    { jrcStdin           = hIn
    , jrcStdout          = hOut
    , jrcPending         = pending
    , jrcRequestHandlers = handlers
    , jrcReaderThread    = readerTid
    , jrcRunning         = running
    , jrcWriteLock       = writeLock
    }

-- | Start the background reader thread.
startClient :: JsonRpcClient -> IO ()
startClient client = do
  atomically $ writeTVar (jrcRunning client) True
  tid <- forkIO $ readLoop client
  atomically $ writeTVar (jrcReaderThread client) (Just tid)

-- | Stop the client and kill the reader thread.
stopClient :: JsonRpcClient -> IO ()
stopClient client = do
  atomically $ writeTVar (jrcRunning client) False
  mTid <- atomically $ readTVar (jrcReaderThread client)
  case mTid of
    Just tid -> killThread tid
    Nothing  -> pure ()
  -- Fail all pending requests
  pending <- atomically $ do
    m <- readTVar (jrcPending client)
    writeTVar (jrcPending client) Map.empty
    pure m
  let err = Left $ JsonRpcError (-32603) "Client stopped" Nothing
  mapM_ (\tmvar -> atomically $ tryPutTMVar tmvar err) (Map.elems pending)

-- | Register a handler for incoming server requests/notifications.
setRequestHandler :: JsonRpcClient -> Text -> RequestHandler -> IO ()
setRequestHandler client method handler =
  atomically $ modifyTVar' (jrcRequestHandlers client) (Map.insert method handler)

-- | Send a JSON-RPC request and wait for the response.
sendRequest :: Aeson.ToJSON a => JsonRpcClient -> Text -> a -> IO (Either JsonRpcError Value)
sendRequest client method params = do
  requestId <- toText <$> nextRandom
  responseTMVar <- newEmptyTMVarIO

  -- Register pending request
  atomically $ modifyTVar' (jrcPending client) (Map.insert requestId responseTMVar)

  -- Build and send the message
  let msg = object
        [ "jsonrpc" .= ("2.0" :: Text)
        , "id"      .= requestId
        , "method"  .= method
        , "params"  .= Aeson.toJSON params
        ]
  writeMessage client msg

  -- Wait for response
  result <- atomically $ takeTMVar responseTMVar

  -- Clean up
  atomically $ modifyTVar' (jrcPending client) (Map.delete requestId)

  pure result

-- | Send a JSON-RPC notification (no response expected).
sendNotification :: Aeson.ToJSON a => JsonRpcClient -> Text -> a -> IO ()
sendNotification client method params = do
  let msg = object
        [ "jsonrpc" .= ("2.0" :: Text)
        , "method"  .= method
        , "params"  .= Aeson.toJSON params
        ]
  writeMessage client msg

-- ============================================================================
-- Internal
-- ============================================================================

-- | Write a JSON-RPC message with Content-Length header framing.
writeMessage :: JsonRpcClient -> Value -> IO ()
writeMessage client msg = do
  let body = LBS.toStrict $ Aeson.encode msg
      header = BS8.pack $ "Content-Length: " ++ show (BS.length body) ++ "\r\n\r\n"
  -- Acquire write lock
  atomically $ takeTMVar (jrcWriteLock client)
  -- Write header + body
  (do BS.hPut (jrcStdin client) header
      BS.hPut (jrcStdin client) body
      hFlush (jrcStdin client)
   ) `catch` (\(_ :: SomeException) -> pure ())
  -- Release write lock
  atomically $ putTMVar (jrcWriteLock client) ()

-- | Background loop: read messages from stdout and dispatch them.
readLoop :: JsonRpcClient -> IO ()
readLoop client = do
  let go = do
        running <- atomically $ readTVar (jrcRunning client)
        when running $ do
          mMsg <- readOneMessage (jrcStdout client)
          case mMsg of
            Nothing -> pure ()  -- EOF or error, exit loop
            Just body -> do
              dispatchMessage client body
              go
  go `catch` (\(_ :: SomeException) -> pure ())

-- | Read one Content-Length-framed message from a handle.
readOneMessage :: Handle -> IO (Maybe BS.ByteString)
readOneMessage h = do
  result <- try $ readHeaders h 0
  case result of
    Left (_ :: SomeException) -> pure Nothing
    Right contentLength
      | contentLength <= 0 -> pure Nothing
      | otherwise -> do
          bodyResult <- try $ readExactly h contentLength
          case bodyResult of
            Left (_ :: SomeException) -> pure Nothing
            Right body -> pure (Just body)

-- | Read HTTP-like headers, extracting Content-Length.
readHeaders :: Handle -> Int -> IO Int
readHeaders h currentLength = do
  line <- readLine h
  if line == "\r\n" || line == "\n" || BS.null line
    then pure currentLength
    else do
      let lineStr = BS8.unpack line
      case parseContentLength lineStr of
        Just n  -> readHeaders h n
        Nothing -> readHeaders h currentLength

-- | Parse "Content-Length: <n>" from a header line.
parseContentLength :: String -> Maybe Int
parseContentLength s =
  case words s of
    ["Content-Length:", nStr] ->
      case reads (filter (/= '\r') nStr) of
        [(n, "")] -> Just n
        _         -> Nothing
    _ -> Nothing

-- | Read a line (up to '\n') from a handle.
readLine :: Handle -> IO BS.ByteString
readLine h = go []
  where
    go acc = do
      b <- BS.hGet h 1
      if BS.null b
        then pure $ BS.concat (reverse acc)
        else let acc' = b : acc
             in if b == "\n"
                  then pure $ BS.concat (reverse acc')
                  else go acc'

-- | Read exactly n bytes from a handle.
readExactly :: Handle -> Int -> IO BS.ByteString
readExactly h n = go n []
  where
    go 0 acc = pure $ BS.concat (reverse acc)
    go remaining acc = do
      chunk <- BS.hGet h remaining
      if BS.null chunk
        then pure $ BS.concat (reverse acc)  -- EOF
        else go (remaining - BS.length chunk) (chunk : acc)

-- | Dispatch a received JSON message (response, request, or notification).
dispatchMessage :: JsonRpcClient -> BS.ByteString -> IO ()
dispatchMessage client body =
  case Aeson.decodeStrict body of
    Nothing -> pure ()  -- Ignore unparsable messages
    Just val -> do
      let mMethod = parseMaybe (Aeson.withObject "" $ \o -> o .: "method") val :: Maybe Text
          mId     = parseMaybe (Aeson.withObject "" $ \o -> o .:? "id") val :: Maybe (Maybe Value)
          hasId   = case mId of
                      Just (Just _) -> True
                      _             -> False
      case (mMethod, hasId) of
        -- Response to a pending request (has id, no method)
        (Nothing, True) -> handleResponse client val
        -- Request from server (has method and id)
        (Just method, True) -> handleServerRequest client method val
        -- Notification from server (has method, no id)
        (Just method, False) -> handleServerNotification client method val
        _ -> pure ()

-- | Handle a response to a pending request.
handleResponse :: JsonRpcClient -> Value -> IO ()
handleResponse client val = do
  let mIdText = parseMaybe (Aeson.withObject "" $ \o -> o .: "id") val :: Maybe Text
  case mIdText of
    Nothing -> pure ()
    Just reqId -> do
      mTMVar <- atomically $ do
        m <- readTVar (jrcPending client)
        pure $ Map.lookup reqId m
      case mTMVar of
        Nothing -> pure ()
        Just tmvar -> do
          let mError = parseMaybe parseError val
              mResult = parseMaybe (Aeson.withObject "" $ \o -> o .: "result") val
          let response = case mError of
                Just err -> Left err
                Nothing  -> case mResult of
                  Just r  -> Right r
                  Nothing -> Right Null
          atomically $ putTMVar tmvar response
  where
    parseError :: Value -> Parser JsonRpcError
    parseError = Aeson.withObject "error" $ \o -> do
      errObj <- o .: "error"
      Aeson.withObject "JsonRpcError" (\e ->
        JsonRpcError
          <$> e .:  "code"
          <*> e .:  "message"
          <*> e .:? "data"
        ) errObj

-- | Handle an incoming request from the server (has both method and id).
handleServerRequest :: JsonRpcClient -> Text -> Value -> IO ()
handleServerRequest client method val = void $ forkIO $ do
  let mId     = parseMaybe (Aeson.withObject "" $ \o -> o .: "id") val :: Maybe Value
      mParams = case parseMaybe (Aeson.withObject "" $ \o -> o .: "params") val :: Maybe Value of
                  Just p  -> p
                  Nothing -> Null
  handlers <- atomically $ readTVar (jrcRequestHandlers client)
  case Map.lookup method handlers of
    Nothing -> do
      case mId of
        Just rid -> sendErrorResponse client rid (-32601) ("Method not found: " <> method) Nothing
        Nothing  -> pure ()
    Just handler -> do
      result <- try (handler mParams)
      case (mId, result) of
        (Just rid, Right (Right r))  -> sendSuccessResponse client rid r
        (Just rid, Right (Left err)) -> sendErrorResponse client rid (jreCode err) (jreMessage err) (jreData err)
        (Just rid, Left (e :: SomeException)) ->
          sendErrorResponse client rid (-32603) (T.pack $ show e) Nothing
        _ -> pure ()

-- | Handle an incoming notification from the server (has method, no id).
handleServerNotification :: JsonRpcClient -> Text -> Value -> IO ()
handleServerNotification client method val = do
  let mParams = case parseMaybe (Aeson.withObject "" $ \o -> o .: "params") val :: Maybe Value of
                  Just p  -> p
                  Nothing -> Null
  handlers <- atomically $ readTVar (jrcRequestHandlers client)
  case Map.lookup method handlers of
    Nothing  -> pure ()
    Just handler -> void $ try $ handler mParams :: IO (Either SomeException (Either JsonRpcError Value))

-- | Send a success response back to the server.
sendSuccessResponse :: JsonRpcClient -> Value -> Value -> IO ()
sendSuccessResponse client rid result = do
  let msg = object
        [ "jsonrpc" .= ("2.0" :: Text)
        , "id"      .= rid
        , "result"  .= result
        ]
  writeMessage client msg

-- | Send an error response back to the server.
sendErrorResponse :: JsonRpcClient -> Value -> Int -> Text -> Maybe Value -> IO ()
sendErrorResponse client rid code message mData = do
  let errObj = object $
        [ "code"    .= code
        , "message" .= message
        ] ++ maybe [] (\d -> ["data" .= d]) mData
  let msg = object
        [ "jsonrpc" .= ("2.0" :: Text)
        , "id"      .= rid
        , "error"   .= errObj
        ]
  writeMessage client msg
