---------------------------------------------------------------------------------------------
--  Copyright (c) Microsoft Corporation. All rights reserved.
---------------------------------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The Copilot Client module.
--
-- Manages the connection to the Copilot CLI server. Spawns the CLI process,
-- communicates via JSON-RPC 2.0 over stdio, and provides session management.
module Copilot.Client
  ( -- * Client
    CopilotClient
  , newCopilotClient
  , startClient
  , stopClient
  , forceStopClient

    -- * Session management
  , createSession
  , resumeSession
  , deleteSession
  , listSessions
  , getLastSessionId

    -- * Queries
  , ping
  , getStatus
  , getAuthStatus
  , listModels
  , getClientState

    -- * Lifecycle events
  , onLifecycleEvent
  ) where

import           Control.Concurrent        (MVar, newMVar, modifyMVar_, readMVar)
import           Control.Exception         (SomeException, catch, try, throwIO, Exception)
import           Control.Monad             (when, void, forM_)
import           Data.Aeson                (Value (..), object, (.=), (.:), (.:?), withObject)
import qualified Data.Aeson                as Aeson
import           Data.Aeson.Types          (parseMaybe)
import           Data.IORef
import qualified Data.Map.Strict           as Map
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           System.Exit               (ExitCode)
import           System.Process            (CreateProcess (..), StdStream (..), ProcessHandle,
                                            createProcess, proc, terminateProcess,
                                            waitForProcess)

import           Copilot.JsonRpc           (JsonRpcClient, JsonRpcError (..),
                                            newJsonRpcClient,
                                            sendRequest, setRequestHandler)
import qualified Copilot.JsonRpc           as JR
import           Copilot.SdkProtocolVersion (sdkProtocolVersion)
import           Copilot.Session           (CopilotSession, newCopilotSession, dispatchSessionEvent,
                                            registerSessionTools, registerSessionPermissionHandler,
                                            registerSessionUserInputHandler, registerSessionHooks,
                                            getSessionToolHandler, handleSessionPermissionRequest,
                                            handleSessionUserInputRequest, handleSessionHooksInvoke,
                                            destroySession)
import           Copilot.Types

-- ============================================================================
-- Client Errors
-- ============================================================================

data CopilotClientError
  = ClientNotConnected
  | ProtocolVersionMismatch Int (Maybe Int)
  | SessionNotFound Text
  | ServerError Text
  | ClientError Text
  deriving (Show)

instance Exception CopilotClientError

-- ============================================================================
-- Client State
-- ============================================================================

-- | The Copilot CLI client.
data CopilotClient = CopilotClient
  { ccOptions           :: !CopilotClientOptions
  , ccState             :: !(IORef ConnectionState)
  , ccProcess           :: !(IORef (Maybe ProcessHandle))
  , ccJsonRpc           :: !(IORef (Maybe JsonRpcClient))
  , ccSessions          :: !(MVar (Map.Map Text CopilotSession))
  , ccModelsCache       :: !(MVar (Maybe [ModelInfo]))
  , ccLifecycleHandlers :: !(IORef [SessionLifecycleHandler])
  }

-- | Create a new 'CopilotClient' with the given options.
newCopilotClient :: CopilotClientOptions -> IO CopilotClient
newCopilotClient opts = do
  stateRef     <- newIORef Disconnected
  processRef   <- newIORef Nothing
  jsonRpcRef   <- newIORef Nothing
  sessionsVar  <- newMVar Map.empty
  modelsCacheVar <- newMVar Nothing
  handlersRef  <- newIORef []
  pure CopilotClient
    { ccOptions           = opts
    , ccState             = stateRef
    , ccProcess           = processRef
    , ccJsonRpc           = jsonRpcRef
    , ccSessions          = sessionsVar
    , ccModelsCache       = modelsCacheVar
    , ccLifecycleHandlers = handlersRef
    }

-- | Get the current connection state.
getClientState :: CopilotClient -> IO ConnectionState
getClientState = readIORef . ccState

-- ============================================================================
-- Start / Stop
-- ============================================================================

-- | Start the CLI server and establish a connection.
--
-- Spawns the Copilot CLI process with @--headless --no-auto-update --log-level info --stdio@,
-- creates a JSON-RPC client over the process stdio pipes, and verifies the
-- protocol version via a ping.
startClient :: CopilotClient -> IO ()
startClient client = do
  st <- readIORef (ccState client)
  when (st == Connected) $ pure ()

  writeIORef (ccState client) Connecting

  -- Determine CLI path
  let cliPath = case ccoCliPath (ccOptions client) of
        Just p  -> p
        Nothing -> "copilot"

  -- Build args
  let baseArgs = ccoCliArgs (ccOptions client)
               ++ [ "--headless"
                  , "--no-auto-update"
                  , "--log-level"
                  , T.unpack (ccoLogLevel (ccOptions client))
                  , "--stdio"
                  ]

  -- Auth flags
  let authArgs = case ccoGithubToken (ccOptions client) of
        Just _ -> ["--auth-token-env", "COPILOT_SDK_AUTH_TOKEN"]
        Nothing -> []

  let loginArgs = case ccoUseLoggedInUser (ccOptions client) of
        Just False -> ["--no-auto-login"]
        Nothing | isJust (ccoGithubToken (ccOptions client)) -> ["--no-auto-login"]
        _ -> []

  let allArgs = baseArgs ++ authArgs ++ loginArgs

  -- Build environment
  let envSetup = case (ccoEnv (ccOptions client), ccoGithubToken (ccOptions client)) of
        (Just env, Just tok) -> Just $ ("COPILOT_SDK_AUTH_TOKEN", T.unpack tok) : env
        (Just env, Nothing)  -> Just env
        (Nothing, Just tok)  -> Just [("COPILOT_SDK_AUTH_TOKEN", T.unpack tok)]
        (Nothing, Nothing)   -> Nothing

  let cpSpec = (proc cliPath allArgs)
        { std_in  = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , cwd     = ccoCwd (ccOptions client)
        , env     = envSetup
        }

  result <- try $ createProcess cpSpec
  case result of
    Left (e :: SomeException) -> do
      writeIORef (ccState client) ConnectionError
      throwIO $ ClientError $ "Failed to start CLI server: " <> T.pack (show e)
    Right (Just hIn, Just hOut, Just hErr, ph) -> do
      writeIORef (ccProcess client) (Just ph)

      -- Create JSON-RPC client
      rpcClient <- newJsonRpcClient hIn hOut
      writeIORef (ccJsonRpc client) (Just rpcClient)

      -- Setup handlers
      setupHandlers client rpcClient

      -- Start the reader
      JR.startClient rpcClient

      -- Verify protocol version
      verifyResult <- try $ verifyProtocolVersion client
      case verifyResult of
        Left (e :: SomeException) -> do
          writeIORef (ccState client) ConnectionError
          throwIO $ ClientError $ T.pack (show e)
        Right () -> do
          writeIORef (ccState client) Connected

    _ -> do
      writeIORef (ccState client) ConnectionError
      throwIO $ ClientError "Failed to create process pipes"

-- | Stop the client gracefully: destroy sessions, close connection, kill process.
stopClient :: CopilotClient -> IO [Text]
stopClient client = do
  errors <- newIORef ([] :: [Text])

  -- Destroy all sessions
  sessions <- readMVar (ccSessions client)
  forM_ (Map.toList sessions) $ \(sid, session) -> do
    result <- try $ destroySession session
    case result of
      Left (e :: SomeException) ->
        modifyIORef errors (("Failed to destroy session " <> sid <> ": " <> T.pack (show e)) :)
      Right () -> pure ()

  modifyMVar_ (ccSessions client) $ \_ -> pure Map.empty

  -- Stop JSON-RPC client
  mRpc <- readIORef (ccJsonRpc client)
  case mRpc of
    Just rpc -> do
      result <- try $ JR.stopClient rpc
      case result of
        Left (e :: SomeException) ->
          modifyIORef errors (("Failed to stop JSON-RPC client: " <> T.pack (show e)) :)
        Right () -> pure ()
    Nothing -> pure ()
  writeIORef (ccJsonRpc client) Nothing

  -- Clear models cache
  modifyMVar_ (ccModelsCache client) $ \_ -> pure Nothing

  -- Kill CLI process
  mPh <- readIORef (ccProcess client)
  case mPh of
    Just ph -> do
      result <- try $ terminateProcess ph
      case result of
        Left (e :: SomeException) ->
          modifyIORef errors (("Failed to kill CLI process: " <> T.pack (show e)) :)
        Right () -> do
          _ <- try (waitForProcess ph) :: IO (Either SomeException ExitCode)
          pure ()
    Nothing -> pure ()
  writeIORef (ccProcess client) Nothing

  writeIORef (ccState client) Disconnected
  readIORef errors

-- | Forcefully stop the client without graceful cleanup.
forceStopClient :: CopilotClient -> IO ()
forceStopClient client = do
  modifyMVar_ (ccSessions client) $ \_ -> pure Map.empty

  mRpc <- readIORef (ccJsonRpc client)
  case mRpc of
    Just rpc -> void (try $ JR.stopClient rpc :: IO (Either SomeException ()))
    Nothing  -> pure ()
  writeIORef (ccJsonRpc client) Nothing

  modifyMVar_ (ccModelsCache client) $ \_ -> pure Nothing

  mPh <- readIORef (ccProcess client)
  case mPh of
    Just ph -> void (try $ terminateProcess ph :: IO (Either SomeException ()))
    Nothing -> pure ()
  writeIORef (ccProcess client) Nothing

  writeIORef (ccState client) Disconnected

-- ============================================================================
-- Session Management
-- ============================================================================

-- | Create a new conversation session.
createSession :: CopilotClient -> SessionConfig -> IO CopilotSession
createSession client config = do
  rpc <- ensureConnected client

  -- Build the create request
  let toolsJson = case scTools config of
        [] -> Nothing
        ts -> Just $ map toolToJson ts

  let reqParams = object $ filter ((/= Null) . snd)
        [ "model"              .= scModel config
        , "sessionId"          .= scSessionId config
        , "reasoningEffort"    .= scReasoningEffort config
        , "configDir"          .= scConfigDir config
        , "tools"              .= toolsJson
        , "systemMessage"      .= scSystemMessage config
        , "availableTools"     .= scAvailableTools config
        , "excludedTools"      .= scExcludedTools config
        , "provider"           .= scProvider config
        , "requestPermission"  .= (isJust (scOnPermissionRequest config))
        , "requestUserInput"   .= (isJust (scOnUserInputRequest config))
        , "hooks"              .= hasHooks (scHooks config)
        , "workingDirectory"   .= scWorkingDirectory config
        , "streaming"          .= scStreaming config
        , "mcpServers"         .= scMcpServers config
        , "customAgents"       .= scCustomAgents config
        , "skillDirectories"   .= scSkillDirectories config
        , "disabledSkills"     .= scDisabledSkills config
        , "infiniteSessions"   .= scInfiniteSessions config
        ]

  result <- sendRequest rpc "session.create" reqParams
  case result of
    Left err -> throwIO $ ServerError (jreMessage err)
    Right val -> do
      let mSessionId = parseMaybe (withObject "" $ \o -> o .: "sessionId") val :: Maybe Text
          mWorkspacePath = parseMaybe (withObject "" $ \o -> o .:? "workspacePath") val :: Maybe (Maybe Text)
      case mSessionId of
        Nothing -> throwIO $ ServerError "No sessionId in create response"
        Just sid -> do
          let wsp = case mWorkspacePath of
                      Just wp -> wp
                      Nothing -> Nothing
          session <- newCopilotSession sid rpc wsp
          registerSessionTools session (scTools config)
          case scOnPermissionRequest config of
            Just h  -> registerSessionPermissionHandler session h
            Nothing -> pure ()
          case scOnUserInputRequest config of
            Just h  -> registerSessionUserInputHandler session h
            Nothing -> pure ()
          case scHooks config of
            Just h  -> registerSessionHooks session h
            Nothing -> pure ()
          modifyMVar_ (ccSessions client) $ \m -> pure (Map.insert sid session m)
          pure session

-- | Resume an existing session.
resumeSession :: CopilotClient -> Text -> ResumeSessionConfig -> IO CopilotSession
resumeSession client sessionId config = do
  rpc <- ensureConnected client

  let toolsJson = case rscTools config of
        [] -> Nothing
        ts -> Just $ map toolToJson ts

  let reqParams = object $ filter ((/= Null) . snd)
        [ "sessionId"          .= sessionId
        , "model"              .= rscModel config
        , "reasoningEffort"    .= rscReasoningEffort config
        , "tools"              .= toolsJson
        , "systemMessage"      .= rscSystemMessage config
        , "availableTools"     .= rscAvailableTools config
        , "excludedTools"      .= rscExcludedTools config
        , "provider"           .= rscProvider config
        , "requestPermission"  .= (isJust (rscOnPermissionRequest config))
        , "requestUserInput"   .= (isJust (rscOnUserInputRequest config))
        , "hooks"              .= hasHooks (rscHooks config)
        , "workingDirectory"   .= rscWorkingDirectory config
        , "configDir"          .= rscConfigDir config
        , "streaming"          .= rscStreaming config
        , "mcpServers"         .= rscMcpServers config
        , "customAgents"       .= rscCustomAgents config
        , "skillDirectories"   .= rscSkillDirectories config
        , "disabledSkills"     .= rscDisabledSkills config
        , "infiniteSessions"   .= rscInfiniteSessions config
        , "disableResume"      .= rscDisableResume config
        ]

  result <- sendRequest rpc "session.resume" reqParams
  case result of
    Left err -> throwIO $ ServerError (jreMessage err)
    Right val -> do
      let mSid = parseMaybe (withObject "" $ \o -> o .: "sessionId") val :: Maybe Text
          mWsp = parseMaybe (withObject "" $ \o -> o .:? "workspacePath") val :: Maybe (Maybe Text)
      case mSid of
        Nothing -> throwIO $ ServerError "No sessionId in resume response"
        Just sid -> do
          let wsp = case mWsp of
                      Just wp -> wp
                      Nothing -> Nothing
          session <- newCopilotSession sid rpc wsp
          registerSessionTools session (rscTools config)
          case rscOnPermissionRequest config of
            Just h  -> registerSessionPermissionHandler session h
            Nothing -> pure ()
          case rscOnUserInputRequest config of
            Just h  -> registerSessionUserInputHandler session h
            Nothing -> pure ()
          case rscHooks config of
            Just h  -> registerSessionHooks session h
            Nothing -> pure ()
          modifyMVar_ (ccSessions client) $ \m -> pure (Map.insert sid session m)
          pure session

-- | Delete a session permanently.
deleteSession :: CopilotClient -> Text -> IO ()
deleteSession client sessionId = do
  rpc <- ensureConnected client
  result <- sendRequest rpc "session.delete" (object [ "sessionId" .= sessionId ])
  case result of
    Left err -> throwIO $ ServerError (jreMessage err)
    Right val -> do
      let mSuccess = parseMaybe (withObject "" $ \o -> o .: "success") val :: Maybe Bool
          mError = parseMaybe (withObject "" $ \o -> o .:? "error") val :: Maybe (Maybe Text)
      case mSuccess of
        Just True -> do
          modifyMVar_ (ccSessions client) $ \m -> pure (Map.delete sessionId m)
        _ -> do
          let errMsg = case mError of
                Just (Just e) -> e
                _             -> "Unknown error"
          throwIO $ ServerError $ "Failed to delete session " <> sessionId <> ": " <> errMsg

-- | List all available sessions.
listSessions :: CopilotClient -> IO [SessionMetadata]
listSessions client = do
  rpc <- ensureConnected client
  result <- sendRequest rpc "session.list" (object [])
  case result of
    Left err -> throwIO $ ServerError (jreMessage err)
    Right val -> do
      let mSessions = parseMaybe (withObject "" $ \o -> o .: "sessions") val :: Maybe [SessionMetadata]
      case mSessions of
        Nothing -> pure []
        Just ss -> pure ss

-- | Get the ID of the most recently updated session.
getLastSessionId :: CopilotClient -> IO (Maybe Text)
getLastSessionId client = do
  rpc <- ensureConnected client
  result <- sendRequest rpc "session.getLastId" (object [])
  case result of
    Left _ -> pure Nothing
    Right val -> pure $ parseMaybe (withObject "" $ \o -> o .: "sessionId") val

-- ============================================================================
-- Queries
-- ============================================================================

-- | Send a ping to verify connectivity.
ping :: CopilotClient -> Maybe Text -> IO PingResponse
ping client mMessage = do
  rpc <- ensureConnected client
  let params = object $ maybe [] (\m -> ["message" .= m]) mMessage
  result <- sendRequest rpc "ping" params
  case result of
    Left err -> throwIO $ ServerError (jreMessage err)
    Right val -> case Aeson.fromJSON val of
      Aeson.Success pr -> pure pr
      Aeson.Error e    -> throwIO $ ServerError $ T.pack e

-- | Get CLI status.
getStatus :: CopilotClient -> IO GetStatusResponse
getStatus client = do
  rpc <- ensureConnected client
  result <- sendRequest rpc "status.get" (object [])
  case result of
    Left err -> throwIO $ ServerError (jreMessage err)
    Right val -> case Aeson.fromJSON val of
      Aeson.Success r -> pure r
      Aeson.Error e   -> throwIO $ ServerError $ T.pack e

-- | Get authentication status.
getAuthStatus :: CopilotClient -> IO GetAuthStatusResponse
getAuthStatus client = do
  rpc <- ensureConnected client
  result <- sendRequest rpc "auth.getStatus" (object [])
  case result of
    Left err -> throwIO $ ServerError (jreMessage err)
    Right val -> case Aeson.fromJSON val of
      Aeson.Success r -> pure r
      Aeson.Error e   -> throwIO $ ServerError $ T.pack e

-- | List available models (cached after first call).
listModels :: CopilotClient -> IO [ModelInfo]
listModels client = do
  rpc <- ensureConnected client
  modifyMVar_ (ccModelsCache client) $ \mCache ->
    case mCache of
      Just models -> pure (Just models)
      Nothing -> do
        result <- sendRequest rpc "models.list" (object [])
        case result of
          Left err -> throwIO $ ServerError (jreMessage err)
          Right val -> do
            let mModels = parseMaybe (withObject "" $ \o -> o .: "models") val :: Maybe [ModelInfo]
            case mModels of
              Just models -> pure (Just models)
              Nothing     -> pure (Just [])
  cached <- readMVar (ccModelsCache client)
  pure $ maybe [] id cached

-- | Subscribe to session lifecycle events.
-- Returns an unsubscribe action.
--
-- Note: Haskell functions cannot be compared by equality. The returned
-- unsubscribe action removes the handler by dropping the head of the list
-- that was prepended. For robust unsubscription, only call unsubscribe once.
onLifecycleEvent :: CopilotClient -> SessionLifecycleHandler -> IO (IO ())
onLifecycleEvent client handler = do
  -- Use an IORef as a unique "alive" flag for this subscription
  aliveRef <- newIORef True
  let wrappedHandler evt = do
        alive <- readIORef aliveRef
        when alive $ handler evt
  modifyIORef (ccLifecycleHandlers client) (wrappedHandler :)
  pure $ writeIORef aliveRef False

-- ============================================================================
-- Internal
-- ============================================================================

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing  = False

hasHooks :: Maybe SessionHooks -> Bool
hasHooks Nothing = False
hasHooks (Just sh) = isJust (shOnPreToolUse sh)
                  || isJust (shOnPostToolUse sh)
                  || isJust (shOnUserPromptSubmitted sh)
                  || isJust (shOnSessionStart sh)
                  || isJust (shOnSessionEnd sh)
                  || isJust (shOnErrorOccurred sh)

-- | Convert a Tool to its JSON wire representation (without handler).
toolToJson :: Tool -> Value
toolToJson t = object $ filter ((/= Null) . snd)
  [ "name"        .= toolName t
  , "description" .= toolDescription t
  , "parameters"  .= toolParameters t
  ]

-- | Ensure the client is connected, auto-starting if configured.
ensureConnected :: CopilotClient -> IO JsonRpcClient
ensureConnected client = do
  mRpc <- readIORef (ccJsonRpc client)
  case mRpc of
    Just rpc -> pure rpc
    Nothing
      | ccoAutoStart (ccOptions client) -> do
          Copilot.Client.startClient client
          mRpc' <- readIORef (ccJsonRpc client)
          case mRpc' of
            Just rpc -> pure rpc
            Nothing  -> throwIO ClientNotConnected
      | otherwise -> throwIO ClientNotConnected

-- | Verify the server protocol version matches the SDK expectation.
verifyProtocolVersion :: CopilotClient -> IO ()
verifyProtocolVersion client = do
  response <- ping client Nothing
  let serverVersion = pingProtocolVersion response
  case serverVersion of
    Nothing -> throwIO $ ProtocolVersionMismatch sdkProtocolVersion Nothing
    Just sv
      | sv /= sdkProtocolVersion -> throwIO $ ProtocolVersionMismatch sdkProtocolVersion (Just sv)
      | otherwise -> pure ()

-- | Set up JSON-RPC handlers for session events, tool calls, permissions, etc.
setupHandlers :: CopilotClient -> JsonRpcClient -> IO ()
setupHandlers client rpc = do
  -- session.event notification
  setRequestHandler rpc "session.event" $ \params -> do
    handleSessionEventNotification client params
    pure (Right Null)

  -- session.lifecycle notification
  setRequestHandler rpc "session.lifecycle" $ \params -> do
    handleLifecycleNotification client params
    pure (Right Null)

  -- tool.call request
  setRequestHandler rpc "tool.call" $ \params -> do
    handleToolCallReq client params

  -- permission.request
  setRequestHandler rpc "permission.request" $ \params -> do
    handlePermissionReq client params

  -- userInput.request
  setRequestHandler rpc "userInput.request" $ \params -> do
    handleUserInputReq client params

  -- hooks.invoke
  setRequestHandler rpc "hooks.invoke" $ \params -> do
    handleHooksInvokeReq client params

-- | Dispatch a session.event notification to the appropriate session.
handleSessionEventNotification :: CopilotClient -> Value -> IO ()
handleSessionEventNotification client params = do
  let mSessionId = parseMaybe (withObject "" $ \o -> o .: "sessionId") params :: Maybe Text
      mEvent     = parseMaybe (withObject "" $ \o -> o .: "event") params :: Maybe SessionEvent
  case (mSessionId, mEvent) of
    (Just sid, Just evt) -> do
      sessions <- readMVar (ccSessions client)
      case Map.lookup sid sessions of
        Just session -> dispatchSessionEvent session evt
        Nothing      -> pure ()
    _ -> pure ()

-- | Dispatch a session.lifecycle notification.
handleLifecycleNotification :: CopilotClient -> Value -> IO ()
handleLifecycleNotification client params = do
  case Aeson.fromJSON params of
    Aeson.Success (evt :: SessionLifecycleEvent) -> do
      handlers <- readIORef (ccLifecycleHandlers client)
      mapM_ (\h -> catch (h evt) (\(_ :: SomeException) -> pure ())) handlers
    Aeson.Error _ -> pure ()

-- | Handle a tool.call request from the server.
handleToolCallReq :: CopilotClient -> Value -> IO (Either JsonRpcError Value)
handleToolCallReq client params = do
  case Aeson.fromJSON params of
    Aeson.Error e -> pure $ Left $ JsonRpcError (-32602) (T.pack e) Nothing
    Aeson.Success (tcr :: ToolCallRequest) -> do
      sessions <- readMVar (ccSessions client)
      case Map.lookup (tcrSessionId tcr) sessions of
        Nothing -> pure $ Left $ JsonRpcError (-32602) ("Unknown session: " <> tcrSessionId tcr) Nothing
        Just session -> do
          mHandler <- getSessionToolHandler session (tcrToolName tcr)
          case mHandler of
            Nothing -> do
              let result = ToolResultStruct $ ToolResultObject
                    { troTextResultForLlm    = "Tool '" <> tcrToolName tcr <> "' is not supported by this client instance."
                    , troBinaryResultsForLlm = Nothing
                    , troResultType          = Failure
                    , troError               = Just $ "tool '" <> tcrToolName tcr <> "' not supported"
                    , troSessionLog          = Nothing
                    , troToolTelemetry       = Just Map.empty
                    }
              pure $ Right $ Aeson.toJSON $ ToolCallResponse result
            Just handler -> do
              let invocation = ToolInvocation
                    { tiSessionId  = tcrSessionId tcr
                    , tiToolCallId = tcrToolCallId tcr
                    , tiToolName   = tcrToolName tcr
                    , tiArguments  = tcrArguments tcr
                    }
              result <- try $ handler (tcrArguments tcr) invocation
              case result of
                Right tr -> pure $ Right $ Aeson.toJSON $ ToolCallResponse tr
                Left (e :: SomeException) -> do
                  let failResult = ToolResultStruct $ ToolResultObject
                        { troTextResultForLlm    = "Invoking this tool produced an error. Detailed information is not available."
                        , troBinaryResultsForLlm = Nothing
                        , troResultType          = Failure
                        , troError               = Just (T.pack $ show e)
                        , troSessionLog          = Nothing
                        , troToolTelemetry       = Just Map.empty
                        }
                  pure $ Right $ Aeson.toJSON $ ToolCallResponse failResult

-- | Handle a permission.request from the server.
handlePermissionReq :: CopilotClient -> Value -> IO (Either JsonRpcError Value)
handlePermissionReq client params = do
  let mSessionId = parseMaybe (withObject "" $ \o -> o .: "sessionId") params :: Maybe Text
      mPermReq   = parseMaybe (withObject "" $ \o -> o .: "permissionRequest") params
  case (mSessionId, mPermReq) of
    (Just sid, Just permReq) -> do
      sessions <- readMVar (ccSessions client)
      case Map.lookup sid sessions of
        Nothing -> pure $ Left $ JsonRpcError (-32602) ("Session not found: " <> sid) Nothing
        Just session -> do
          result <- try $ handleSessionPermissionRequest session permReq sid
          case result of
            Right pr -> pure $ Right $ object [ "result" .= pr ]
            Left (_ :: SomeException) ->
              pure $ Right $ object
                [ "result" .= object [ "kind" .= ("denied-no-approval-rule-and-could-not-request-from-user" :: Text) ] ]
    _ -> pure $ Left $ JsonRpcError (-32602) "Invalid permission request payload" Nothing

-- | Handle a userInput.request from the server.
handleUserInputReq :: CopilotClient -> Value -> IO (Either JsonRpcError Value)
handleUserInputReq client params = do
  let mSessionId = parseMaybe (withObject "" $ \o -> o .: "sessionId") params :: Maybe Text
      mQuestion  = parseMaybe (withObject "" $ \o -> o .: "question") params :: Maybe Text
      mChoices   = parseMaybe (withObject "" $ \o -> o .:? "choices") params :: Maybe (Maybe [Text])
      mAllow     = parseMaybe (withObject "" $ \o -> o .:? "allowFreeform") params :: Maybe (Maybe Bool)
  case (mSessionId, mQuestion) of
    (Just sid, Just question) -> do
      sessions <- readMVar (ccSessions client)
      case Map.lookup sid sessions of
        Nothing -> pure $ Left $ JsonRpcError (-32602) ("Session not found: " <> sid) Nothing
        Just session -> do
          let req = UserInputRequest
                { uirQuestion      = question
                , uirChoices       = case mChoices of Just c -> c; Nothing -> Nothing
                , uirAllowFreeform = case mAllow of Just a -> a; Nothing -> Nothing
                }
          result <- try $ handleSessionUserInputRequest session req sid
          case result of
            Right resp -> pure $ Right $ Aeson.toJSON resp
            Left (e :: SomeException) ->
              pure $ Left $ JsonRpcError (-32603) (T.pack $ show e) Nothing
    _ -> pure $ Left $ JsonRpcError (-32602) "Invalid user input request payload" Nothing

-- | Handle a hooks.invoke from the server.
handleHooksInvokeReq :: CopilotClient -> Value -> IO (Either JsonRpcError Value)
handleHooksInvokeReq client params = do
  let mSessionId = parseMaybe (withObject "" $ \o -> o .: "sessionId") params :: Maybe Text
      mHookType  = parseMaybe (withObject "" $ \o -> o .: "hookType") params :: Maybe Text
      mInput     = parseMaybe (withObject "" $ \o -> o .: "input") params :: Maybe Value
  case (mSessionId, mHookType) of
    (Just sid, Just hookType) -> do
      sessions <- readMVar (ccSessions client)
      case Map.lookup sid sessions of
        Nothing -> pure $ Left $ JsonRpcError (-32602) ("Session not found: " <> sid) Nothing
        Just session -> do
          let input = case mInput of
                        Just i  -> i
                        Nothing -> Null
          result <- try $ handleSessionHooksInvoke session hookType input sid
          case result of
            Right mOutput -> case mOutput of
              Just output -> pure $ Right $ object [ "output" .= output ]
              Nothing     -> pure $ Right $ object []
            Left (e :: SomeException) ->
              pure $ Left $ JsonRpcError (-32603) (T.pack $ show e) Nothing
    _ -> pure $ Left $ JsonRpcError (-32602) "Invalid hooks invoke payload" Nothing
