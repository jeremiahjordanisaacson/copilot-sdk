---------------------------------------------------------------------------------------------
--  Copyright (c) Microsoft Corporation. All rights reserved.
---------------------------------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Copilot Session management.
--
-- A 'CopilotSession' represents a single conversation session with the
-- Copilot CLI. It supports sending messages, subscribing to events,
-- registering tools, and handling permission\/user-input\/hook requests.
module Copilot.Session
  ( -- * Session type
    CopilotSession
  , newCopilotSession
  , sessionId
  , workspacePath

    -- * Sending messages
  , send
  , sendAndWait

    -- * Event subscription
  , onSessionEvent
  , dispatchSessionEvent

    -- * Tool registration (internal)
  , registerSessionTools
  , getSessionToolHandler

    -- * Permission / user-input / hooks handlers (internal)
  , registerSessionPermissionHandler
  , registerSessionUserInputHandler
  , registerSessionHooks
  , handleSessionPermissionRequest
  , handleSessionUserInputRequest
  , handleSessionHooksInvoke

    -- * Lifecycle
  , destroySession
  , abortSession
  , getMessages
  ) where

import           Control.Concurrent        (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar, tryTakeMVar)
import           Control.Exception         (SomeException, catch, try, throwIO, Exception)
import           Control.Monad             (forM_, void, when)
import           Data.Aeson                (Value (..), object, (.=), (.:), (.:?), withObject)
import qualified Data.Aeson                as Aeson
import           Data.Aeson.Types          (parseMaybe)
import           Data.IORef
import qualified Data.Map.Strict           as Map
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           System.Timeout            (timeout)

import           Copilot.JsonRpc           (JsonRpcClient, JsonRpcError (..),
                                            sendRequest)
import           Copilot.Types

-- ============================================================================
-- Session Error
-- ============================================================================

data SessionError
  = SessionRpcError Text
  | SessionTimeout Int
  | SessionErrorEvent Text (Maybe Text)
  deriving (Show)

instance Exception SessionError

-- ============================================================================
-- Session Type
-- ============================================================================

-- | A single conversation session with the Copilot CLI.
data CopilotSession = CopilotSession
  { csSessionId         :: !Text
  , csWorkspacePath     :: !(Maybe Text)
  , csJsonRpc           :: !JsonRpcClient
  , csEventHandlers     :: !(IORef [SessionEventHandler])
  , csToolHandlers      :: !(IORef (Map.Map Text ToolHandler))
  , csPermissionHandler :: !(IORef (Maybe PermissionHandler))
  , csUserInputHandler  :: !(IORef (Maybe UserInputHandler))
  , csHooks             :: !(IORef (Maybe SessionHooks))
  }

-- | Create a new session.
newCopilotSession :: Text -> JsonRpcClient -> Maybe Text -> IO CopilotSession
newCopilotSession sid rpc wsp = do
  handlers   <- newIORef []
  toolH      <- newIORef Map.empty
  permH      <- newIORef Nothing
  userInputH <- newIORef Nothing
  hooksRef   <- newIORef Nothing
  pure CopilotSession
    { csSessionId         = sid
    , csWorkspacePath     = wsp
    , csJsonRpc           = rpc
    , csEventHandlers     = handlers
    , csToolHandlers      = toolH
    , csPermissionHandler = permH
    , csUserInputHandler  = userInputH
    , csHooks             = hooksRef
    }

-- | Get the session ID.
sessionId :: CopilotSession -> Text
sessionId = csSessionId

-- | Get the workspace path (when infinite sessions are enabled).
workspacePath :: CopilotSession -> Maybe Text
workspacePath = csWorkspacePath

-- ============================================================================
-- Sending Messages
-- ============================================================================

-- | Send a message to the session.
-- Returns the message ID.
send :: CopilotSession -> MessageOptions -> IO Text
send session opts = do
  let reqParams = object $ filter ((/= Null) . snd)
        [ "sessionId"      .= csSessionId session
        , "prompt"         .= moPrompt opts
        , "attachments"    .= moAttachments opts
        , "mode"           .= moMode opts
        , "responseFormat" .= moResponseFormat opts
        , "imageOptions"   .= moImageOptions opts
        ]
  result <- sendRequest (csJsonRpc session) "session.send" reqParams
  case result of
    Left err -> throwIO $ SessionRpcError (jreMessage err)
    Right val -> do
      let mMsgId = parseMaybe (withObject "" $ \o -> o .: "messageId") val :: Maybe Text
      case mMsgId of
        Just mid -> pure mid
        Nothing  -> throwIO $ SessionRpcError "No messageId in send response"

-- | Send a message and wait for the session to become idle.
--
-- Returns the last @assistant.message@ event received, or 'Nothing' if none
-- was emitted before the session went idle.
--
-- The timeout is in microseconds (default: 60 seconds = 60000000).
sendAndWait :: CopilotSession -> MessageOptions -> Maybe Int -> IO (Maybe SessionEvent)
sendAndWait session opts mTimeout = do
  let timeoutUs = maybe 60000000 id mTimeout

  idleMVar <- newEmptyMVar :: IO (MVar ())
  errorMVar <- newEmptyMVar :: IO (MVar SessionError)
  lastMsgRef <- newIORef (Nothing :: Maybe SessionEvent)

  -- Subscribe to events BEFORE sending to avoid race conditions
  let handler evt = do
        case seType evt of
          "assistant.message" -> writeIORef lastMsgRef (Just evt)
          "session.idle"      -> void $ tryPutMVar idleMVar ()
          "session.error"     -> do
            let mMsg = parseMaybe (withObject "" $ \o -> o .: "message") (seData evt) :: Maybe Text
                mStack = parseMaybe (withObject "" $ \o -> o .:? "stack") (seData evt) :: Maybe (Maybe Text)
            void $ tryPutMVar errorMVar (SessionErrorEvent (maybe "session error" id mMsg) (maybe Nothing id mStack))
          _ -> pure ()

  unsubscribe <- onSessionEvent session handler

  -- Send the message
  sendResult <- try $ send session opts
  case sendResult of
    Left (e :: SomeException) -> do
      unsubscribe
      throwIO $ SessionRpcError (T.pack $ show e)
    Right _ -> pure ()

  -- Wait for idle, error, or timeout
  result <- timeout timeoutUs $ do
    -- Race between idle and error
    let waitLoop = do
          -- Check if idle already signaled
          mIdle <- tryTakeMVar idleMVar
          case mIdle of
            Just () -> pure Nothing  -- No error
            Nothing -> do
              mErr <- tryTakeMVar errorMVar
              case mErr of
                Just err -> pure (Just err)
                Nothing  -> do
                  -- Small sleep then retry via STM or polling
                  -- Use a simple approach: block on idleMVar with a short timeout
                  mIdle2 <- timeout 10000 (takeMVar idleMVar)  -- 10ms poll
                  case mIdle2 of
                    Just () -> pure Nothing
                    Nothing -> waitLoop
    waitLoop

  unsubscribe

  case result of
    Nothing -> throwIO $ SessionTimeout (timeoutUs `div` 1000)
    Just (Just err) -> throwIO err
    Just Nothing -> readIORef lastMsgRef

-- ============================================================================
-- Event Subscription
-- ============================================================================

-- | Subscribe to session events.
-- Returns an IO action that unsubscribes when called.
onSessionEvent :: CopilotSession -> SessionEventHandler -> IO (IO ())
onSessionEvent session handler = do
  -- Use an IORef as a unique "alive" flag for this subscription
  aliveRef <- newIORef True
  let wrappedHandler evt = do
        alive <- readIORef aliveRef
        when alive $ handler evt
  modifyIORef (csEventHandlers session) (wrappedHandler :)
  pure $ writeIORef aliveRef False

-- | Dispatch an event to all registered handlers. (Internal)
dispatchSessionEvent :: CopilotSession -> SessionEvent -> IO ()
dispatchSessionEvent session evt = do
  handlers <- readIORef (csEventHandlers session)
  forM_ handlers $ \h ->
    catch (h evt) (\(_ :: SomeException) -> pure ())

-- ============================================================================
-- Tool Registration
-- ============================================================================

-- | Register tools for this session. (Internal)
registerSessionTools :: CopilotSession -> [Tool] -> IO ()
registerSessionTools session tools = do
  let m = Map.fromList [ (toolName t, toolHandler t) | t <- tools ]
  writeIORef (csToolHandlers session) m

-- | Get a tool handler by name. (Internal)
getSessionToolHandler :: CopilotSession -> Text -> IO (Maybe ToolHandler)
getSessionToolHandler session name = do
  handlers <- readIORef (csToolHandlers session)
  pure $ Map.lookup name handlers

-- ============================================================================
-- Permission Handler
-- ============================================================================

-- | Register a permission handler. (Internal)
registerSessionPermissionHandler :: CopilotSession -> PermissionHandler -> IO ()
registerSessionPermissionHandler session handler =
  writeIORef (csPermissionHandler session) (Just handler)

-- | Handle a permission request. (Internal)
handleSessionPermissionRequest :: CopilotSession -> Value -> Text -> IO PermissionRequestResult
handleSessionPermissionRequest session reqVal sid = do
  mHandler <- readIORef (csPermissionHandler session)
  case mHandler of
    Nothing -> pure $ PermissionRequestResult "denied-no-approval-rule-and-could-not-request-from-user" Nothing
    Just handler -> do
      case Aeson.fromJSON reqVal of
        Aeson.Success permReq -> handler permReq sid
        Aeson.Error _ ->
          -- Try to at least get the kind
          let mKind = parseMaybe (withObject "" $ \o -> o .: "kind") reqVal :: Maybe Text
          in case mKind of
            Just kind -> handler (PermissionRequest kind Nothing Map.empty) sid
            Nothing   -> pure $ PermissionRequestResult "denied-no-approval-rule-and-could-not-request-from-user" Nothing

-- ============================================================================
-- User Input Handler
-- ============================================================================

-- | Register a user input handler. (Internal)
registerSessionUserInputHandler :: CopilotSession -> UserInputHandler -> IO ()
registerSessionUserInputHandler session handler =
  writeIORef (csUserInputHandler session) (Just handler)

-- | Handle a user input request. (Internal)
handleSessionUserInputRequest :: CopilotSession -> UserInputRequest -> Text -> IO UserInputResponse
handleSessionUserInputRequest session req sid = do
  mHandler <- readIORef (csUserInputHandler session)
  case mHandler of
    Nothing -> throwIO $ SessionRpcError "No user input handler registered"
    Just handler -> handler req sid

-- ============================================================================
-- Hooks
-- ============================================================================

-- | Register hooks. (Internal)
registerSessionHooks :: CopilotSession -> SessionHooks -> IO ()
registerSessionHooks session hooks =
  writeIORef (csHooks session) (Just hooks)

-- | Handle a hooks invocation. (Internal)
handleSessionHooksInvoke :: CopilotSession -> Text -> Value -> Text -> IO (Maybe Value)
handleSessionHooksInvoke session hookType input sid = do
  mHooks <- readIORef (csHooks session)
  case mHooks of
    Nothing -> pure Nothing
    Just hooks -> do
      let inv = HookInvocation { hiSessionId = sid }
      case hookType of
        "preToolUse" -> case shOnPreToolUse hooks of
          Nothing -> pure Nothing
          Just handler -> do
            case Aeson.fromJSON input of
              Aeson.Success inp -> do
                result <- handler inp inv
                pure $ fmap Aeson.toJSON result
              Aeson.Error _ -> pure Nothing

        "postToolUse" -> case shOnPostToolUse hooks of
          Nothing -> pure Nothing
          Just handler -> do
            case Aeson.fromJSON input of
              Aeson.Success inp -> do
                result <- handler inp inv
                pure $ fmap Aeson.toJSON result
              Aeson.Error _ -> pure Nothing

        "userPromptSubmitted" -> case shOnUserPromptSubmitted hooks of
          Nothing -> pure Nothing
          Just handler -> do
            case Aeson.fromJSON input of
              Aeson.Success inp -> do
                result <- handler inp inv
                pure $ fmap Aeson.toJSON result
              Aeson.Error _ -> pure Nothing

        "sessionStart" -> case shOnSessionStart hooks of
          Nothing -> pure Nothing
          Just handler -> do
            case Aeson.fromJSON input of
              Aeson.Success inp -> do
                result <- handler inp inv
                pure $ fmap Aeson.toJSON result
              Aeson.Error _ -> pure Nothing

        "sessionEnd" -> case shOnSessionEnd hooks of
          Nothing -> pure Nothing
          Just handler -> do
            case Aeson.fromJSON input of
              Aeson.Success inp -> do
                result <- handler inp inv
                pure $ fmap Aeson.toJSON result
              Aeson.Error _ -> pure Nothing

        "errorOccurred" -> case shOnErrorOccurred hooks of
          Nothing -> pure Nothing
          Just handler -> do
            case Aeson.fromJSON input of
              Aeson.Success inp -> do
                result <- handler inp inv
                pure $ fmap Aeson.toJSON result
              Aeson.Error _ -> pure Nothing

        _ -> pure Nothing

-- ============================================================================
-- Lifecycle
-- ============================================================================

-- | Destroy this session and release resources.
destroySession :: CopilotSession -> IO ()
destroySession session = do
  let params = object [ "sessionId" .= csSessionId session ]
  result <- sendRequest (csJsonRpc session) "session.destroy" params
  case result of
    Left err -> throwIO $ SessionRpcError (jreMessage err)
    Right _  -> do
      writeIORef (csEventHandlers session) []
      writeIORef (csToolHandlers session) Map.empty
      writeIORef (csPermissionHandler session) Nothing
      writeIORef (csUserInputHandler session) Nothing
      writeIORef (csHooks session) Nothing

-- | Abort the currently processing message.
abortSession :: CopilotSession -> IO ()
abortSession session = do
  let params = object [ "sessionId" .= csSessionId session ]
  result <- sendRequest (csJsonRpc session) "session.abort" params
  case result of
    Left err -> throwIO $ SessionRpcError (jreMessage err)
    Right _  -> pure ()

-- | Retrieve all events/messages from the session history.
getMessages :: CopilotSession -> IO [SessionEvent]
getMessages session = do
  let params = object [ "sessionId" .= csSessionId session ]
  result <- sendRequest (csJsonRpc session) "session.getMessages" params
  case result of
    Left err -> throwIO $ SessionRpcError (jreMessage err)
    Right val -> do
      let mEvents = parseMaybe (withObject "" $ \o -> o .: "events") val :: Maybe [SessionEvent]
      pure $ maybe [] id mEvents

