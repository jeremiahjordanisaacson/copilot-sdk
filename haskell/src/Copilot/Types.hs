---------------------------------------------------------------------------------------------
--  Copyright (c) Microsoft Corporation. All rights reserved.
---------------------------------------------------------------------------------------------

{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- | Type definitions for the Copilot SDK.
--
-- This module contains all data types, Aeson JSON instances, and type aliases
-- used across the SDK. It mirrors the types found in the Node.js, Go, and
-- other SDK implementations.
module Copilot.Types
  ( -- * Connection state
    ConnectionState (..)

    -- * Tool types
  , ToolResultType (..)
  , ToolBinaryResult (..)
  , ToolResultObject (..)
  , ToolResult (..)
  , ToolInvocation (..)
  , ToolHandler
  , Tool (..)
  , ToolCallRequest (..)
  , ToolCallResponse (..)

    -- * Session configuration
  , SystemMessageConfig (..)
  , ProviderConfig (..)
  , AzureProviderOptions (..)
  , MCPServerConfig (..)
  , CustomAgentConfig (..)
  , InfiniteSessionConfig (..)
  , SessionConfig (..)
  , defaultSessionConfig
  , ResumeSessionConfig (..)
  , defaultResumeSessionConfig

    -- * Message options
  , Attachment (..)
  , MessageOptions (..)

    -- * Permission types
  , PermissionRequest (..)
  , PermissionRequestResult (..)
  , PermissionHandler

    -- * User input types
  , UserInputRequest (..)
  , UserInputResponse (..)
  , UserInputHandler

    -- * Hook types
  , HookInvocation (..)
  , PreToolUseHookInput (..)
  , PreToolUseHookOutput (..)
  , PostToolUseHookInput (..)
  , PostToolUseHookOutput (..)
  , UserPromptSubmittedHookInput (..)
  , UserPromptSubmittedHookOutput (..)
  , SessionStartHookInput (..)
  , SessionStartHookOutput (..)
  , SessionEndHookInput (..)
  , SessionEndHookOutput (..)
  , ErrorOccurredHookInput (..)
  , ErrorOccurredHookOutput (..)
  , SessionHooks (..)
  , defaultSessionHooks

    -- * Session event types
  , SessionEvent (..)
  , SessionEventHandler

    -- * Ping / Status / Auth
  , PingResponse (..)
  , GetStatusResponse (..)
  , GetAuthStatusResponse (..)

    -- * Model types
  , ModelSupports (..)
  , ModelLimits (..)
  , ModelVisionLimits (..)
  , ModelCapabilities (..)
  , ModelPolicy (..)
  , ModelBilling (..)
  , ModelInfo (..)

    -- * Session metadata & lifecycle
  , SessionMetadata (..)
  , SessionLifecycleEvent (..)
  , SessionLifecycleHandler

    -- * Client options
  , CopilotClientOptions (..)
  , defaultClientOptions
  ) where

import           Data.Aeson
import qualified Data.Aeson        as Aeson
import qualified Data.Map.Strict   as Map
import           Data.Text         (Text)
import           GHC.Generics      (Generic)

-- ============================================================================
-- Connection State
-- ============================================================================

-- | Current connection state of the client.
data ConnectionState
  = Disconnected
  | Connecting
  | Connected
  | ConnectionError
  deriving (Show, Eq, Generic)

instance ToJSON ConnectionState where
  toJSON Disconnected    = String "disconnected"
  toJSON Connecting      = String "connecting"
  toJSON Connected       = String "connected"
  toJSON ConnectionError = String "error"

instance FromJSON ConnectionState where
  parseJSON = withText "ConnectionState" $ \case
    "disconnected" -> pure Disconnected
    "connecting"   -> pure Connecting
    "connected"    -> pure Connected
    "error"        -> pure ConnectionError
    other          -> fail $ "Unknown ConnectionState: " ++ show other

-- ============================================================================
-- Tool Result Types
-- ============================================================================

-- | Result type classification for tool execution.
data ToolResultType = Success | Failure | Rejected | Denied
  deriving (Show, Eq, Generic)

instance ToJSON ToolResultType where
  toJSON Success  = String "success"
  toJSON Failure  = String "failure"
  toJSON Rejected = String "rejected"
  toJSON Denied   = String "denied"

instance FromJSON ToolResultType where
  parseJSON = withText "ToolResultType" $ \case
    "success"  -> pure Success
    "failure"  -> pure Failure
    "rejected" -> pure Rejected
    "denied"   -> pure Denied
    other      -> fail $ "Unknown ToolResultType: " ++ show other

-- | Binary data returned by a tool.
data ToolBinaryResult = ToolBinaryResult
  { tbrData        :: !Text
  , tbrMimeType    :: !Text
  , tbrType        :: !Text
  , tbrDescription :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance ToJSON ToolBinaryResult where
  toJSON ToolBinaryResult{..} = object
    [ "data"        .= tbrData
    , "mimeType"    .= tbrMimeType
    , "type"        .= tbrType
    , "description" .= tbrDescription
    ]

instance FromJSON ToolBinaryResult where
  parseJSON = withObject "ToolBinaryResult" $ \o ->
    ToolBinaryResult
      <$> o .:  "data"
      <*> o .:  "mimeType"
      <*> o .:  "type"
      <*> o .:? "description"

-- | Structured tool result object.
data ToolResultObject = ToolResultObject
  { troTextResultForLlm    :: !Text
  , troBinaryResultsForLlm :: !(Maybe [ToolBinaryResult])
  , troResultType          :: !ToolResultType
  , troError               :: !(Maybe Text)
  , troSessionLog          :: !(Maybe Text)
  , troToolTelemetry       :: !(Maybe (Map.Map Text Value))
  } deriving (Show, Eq, Generic)

instance ToJSON ToolResultObject where
  toJSON ToolResultObject{..} = object
    [ "textResultForLlm"    .= troTextResultForLlm
    , "binaryResultsForLlm" .= troBinaryResultsForLlm
    , "resultType"          .= troResultType
    , "error"               .= troError
    , "sessionLog"          .= troSessionLog
    , "toolTelemetry"       .= troToolTelemetry
    ]

instance FromJSON ToolResultObject where
  parseJSON = withObject "ToolResultObject" $ \o ->
    ToolResultObject
      <$> o .:  "textResultForLlm"
      <*> o .:? "binaryResultsForLlm"
      <*> o .:  "resultType"
      <*> o .:? "error"
      <*> o .:? "sessionLog"
      <*> o .:? "toolTelemetry"

-- | Tool result: either a simple string or a structured object.
data ToolResult
  = ToolResultText   !Text
  | ToolResultStruct !ToolResultObject
  deriving (Show, Eq)

instance ToJSON ToolResult where
  toJSON (ToolResultText t)   = toJSON t
  toJSON (ToolResultStruct o) = toJSON o

instance FromJSON ToolResult where
  parseJSON v@(String _) = ToolResultText <$> parseJSON v
  parseJSON v@(Object _) = ToolResultStruct <$> parseJSON v
  parseJSON _            = fail "ToolResult must be a string or object"

-- | Context about a tool invocation.
data ToolInvocation = ToolInvocation
  { tiSessionId  :: !Text
  , tiToolCallId :: !Text
  , tiToolName   :: !Text
  , tiArguments  :: !Value
  } deriving (Show, Eq, Generic)

-- | A tool handler function.
-- Takes arguments (as a JSON 'Value') and the invocation context, returns an IO
-- action producing a 'ToolResult'.
type ToolHandler = Value -> ToolInvocation -> IO ToolResult

-- | Tool definition with name, description, JSON schema parameters, and handler.
data Tool = Tool
  { toolName        :: !Text
  , toolDescription :: !(Maybe Text)
  , toolParameters  :: !(Maybe Value)
  , toolHandler     :: !ToolHandler
  }

instance Show Tool where
  show t = "Tool { name = " ++ show (toolName t)
        ++ ", description = " ++ show (toolDescription t) ++ " }"

-- | Request payload from the server for a tool call.
data ToolCallRequest = ToolCallRequest
  { tcrSessionId  :: !Text
  , tcrToolCallId :: !Text
  , tcrToolName   :: !Text
  , tcrArguments  :: !Value
  } deriving (Show, Eq, Generic)

instance FromJSON ToolCallRequest where
  parseJSON = withObject "ToolCallRequest" $ \o ->
    ToolCallRequest
      <$> o .: "sessionId"
      <*> o .: "toolCallId"
      <*> o .: "toolName"
      <*> o .: "arguments"

instance ToJSON ToolCallRequest where
  toJSON ToolCallRequest{..} = object
    [ "sessionId"  .= tcrSessionId
    , "toolCallId" .= tcrToolCallId
    , "toolName"   .= tcrToolName
    , "arguments"  .= tcrArguments
    ]

-- | Response payload for a tool call.
data ToolCallResponse = ToolCallResponse
  { tcrResult :: !ToolResult
  } deriving (Show, Eq)

instance ToJSON ToolCallResponse where
  toJSON (ToolCallResponse r) = object [ "result" .= r ]

instance FromJSON ToolCallResponse where
  parseJSON = withObject "ToolCallResponse" $ \o ->
    ToolCallResponse <$> o .: "result"

-- ============================================================================
-- System Message Configuration
-- ============================================================================

-- | System message configuration for session creation.
-- Mode can be "append" (default) or "replace".
data SystemMessageConfig = SystemMessageConfig
  { smcMode    :: !(Maybe Text)  -- ^ "append" or "replace"
  , smcContent :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance ToJSON SystemMessageConfig where
  toJSON SystemMessageConfig{..} = object
    [ "mode"    .= smcMode
    , "content" .= smcContent
    ]

instance FromJSON SystemMessageConfig where
  parseJSON = withObject "SystemMessageConfig" $ \o ->
    SystemMessageConfig
      <$> o .:? "mode"
      <*> o .:? "content"

-- ============================================================================
-- Provider Configuration
-- ============================================================================

-- | Azure-specific provider options.
data AzureProviderOptions = AzureProviderOptions
  { apoApiVersion :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance ToJSON AzureProviderOptions where
  toJSON AzureProviderOptions{..} = object [ "apiVersion" .= apoApiVersion ]

instance FromJSON AzureProviderOptions where
  parseJSON = withObject "AzureProviderOptions" $ \o ->
    AzureProviderOptions <$> o .:? "apiVersion"

-- | Custom provider configuration (BYOK).
data ProviderConfig = ProviderConfig
  { pcType        :: !(Maybe Text)  -- ^ "openai", "azure", or "anthropic"
  , pcWireApi     :: !(Maybe Text)  -- ^ "completions" or "responses"
  , pcBaseUrl     :: !Text
  , pcApiKey      :: !(Maybe Text)
  , pcBearerToken :: !(Maybe Text)
  , pcAzure       :: !(Maybe AzureProviderOptions)
  } deriving (Show, Eq, Generic)

instance ToJSON ProviderConfig where
  toJSON ProviderConfig{..} = object
    [ "type"        .= pcType
    , "wireApi"     .= pcWireApi
    , "baseUrl"     .= pcBaseUrl
    , "apiKey"      .= pcApiKey
    , "bearerToken" .= pcBearerToken
    , "azure"       .= pcAzure
    ]

instance FromJSON ProviderConfig where
  parseJSON = withObject "ProviderConfig" $ \o ->
    ProviderConfig
      <$> o .:? "type"
      <*> o .:? "wireApi"
      <*> o .:  "baseUrl"
      <*> o .:? "apiKey"
      <*> o .:? "bearerToken"
      <*> o .:? "azure"

-- ============================================================================
-- MCP Server Configuration
-- ============================================================================

-- | MCP server configuration (local or remote).
-- Stored as a generic JSON 'Value' for flexibility.
type MCPServerConfig = Value

-- ============================================================================
-- Custom Agent Configuration
-- ============================================================================

-- | Configuration for a custom agent.
data CustomAgentConfig = CustomAgentConfig
  { cacName        :: !Text
  , cacDisplayName :: !(Maybe Text)
  , cacDescription :: !(Maybe Text)
  , cacTools       :: !(Maybe [Text])
  , cacPrompt      :: !Text
  , cacMcpServers  :: !(Maybe (Map.Map Text MCPServerConfig))
  , cacInfer       :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)

instance ToJSON CustomAgentConfig where
  toJSON CustomAgentConfig{..} = object
    [ "name"        .= cacName
    , "displayName" .= cacDisplayName
    , "description" .= cacDescription
    , "tools"       .= cacTools
    , "prompt"      .= cacPrompt
    , "mcpServers"  .= cacMcpServers
    , "infer"       .= cacInfer
    ]

instance FromJSON CustomAgentConfig where
  parseJSON = withObject "CustomAgentConfig" $ \o ->
    CustomAgentConfig
      <$> o .:  "name"
      <*> o .:? "displayName"
      <*> o .:? "description"
      <*> o .:? "tools"
      <*> o .:  "prompt"
      <*> o .:? "mcpServers"
      <*> o .:? "infer"

-- ============================================================================
-- Infinite Session Configuration
-- ============================================================================

-- | Configuration for infinite sessions with automatic context compaction.
data InfiniteSessionConfig = InfiniteSessionConfig
  { iscEnabled                        :: !(Maybe Bool)
  , iscBackgroundCompactionThreshold  :: !(Maybe Double)
  , iscBufferExhaustionThreshold      :: !(Maybe Double)
  } deriving (Show, Eq, Generic)

instance ToJSON InfiniteSessionConfig where
  toJSON InfiniteSessionConfig{..} = object
    [ "enabled"                        .= iscEnabled
    , "backgroundCompactionThreshold"  .= iscBackgroundCompactionThreshold
    , "bufferExhaustionThreshold"      .= iscBufferExhaustionThreshold
    ]

instance FromJSON InfiniteSessionConfig where
  parseJSON = withObject "InfiniteSessionConfig" $ \o ->
    InfiniteSessionConfig
      <$> o .:? "enabled"
      <*> o .:? "backgroundCompactionThreshold"
      <*> o .:? "bufferExhaustionThreshold"

-- ============================================================================
-- Session Configuration
-- ============================================================================

-- | Configuration for creating a new session.
data SessionConfig = SessionConfig
  { scSessionId          :: !(Maybe Text)
  , scModel              :: !(Maybe Text)
  , scReasoningEffort    :: !(Maybe Text)
  , scConfigDir          :: !(Maybe Text)
  , scTools              :: ![Tool]
  , scSystemMessage      :: !(Maybe SystemMessageConfig)
  , scAvailableTools     :: !(Maybe [Text])
  , scExcludedTools      :: !(Maybe [Text])
  , scProvider           :: !(Maybe ProviderConfig)
  , scOnPermissionRequest :: !(Maybe PermissionHandler)
  , scOnUserInputRequest :: !(Maybe UserInputHandler)
  , scHooks              :: !(Maybe SessionHooks)
  , scWorkingDirectory   :: !(Maybe Text)
  , scStreaming          :: !(Maybe Bool)
  , scMcpServers         :: !(Maybe (Map.Map Text MCPServerConfig))
  , scCustomAgents       :: !(Maybe [CustomAgentConfig])
  , scSkillDirectories   :: !(Maybe [Text])
  , scDisabledSkills     :: !(Maybe [Text])
  , scInfiniteSessions   :: !(Maybe InfiniteSessionConfig)
  }

-- | Default (empty) session configuration.
defaultSessionConfig :: SessionConfig
defaultSessionConfig = SessionConfig
  { scSessionId           = Nothing
  , scModel               = Nothing
  , scReasoningEffort     = Nothing
  , scConfigDir           = Nothing
  , scTools               = []
  , scSystemMessage       = Nothing
  , scAvailableTools      = Nothing
  , scExcludedTools       = Nothing
  , scProvider            = Nothing
  , scOnPermissionRequest = Nothing
  , scOnUserInputRequest  = Nothing
  , scHooks               = Nothing
  , scWorkingDirectory    = Nothing
  , scStreaming           = Nothing
  , scMcpServers          = Nothing
  , scCustomAgents        = Nothing
  , scSkillDirectories    = Nothing
  , scDisabledSkills      = Nothing
  , scInfiniteSessions    = Nothing
  }

-- | Configuration for resuming a session.
data ResumeSessionConfig = ResumeSessionConfig
  { rscModel              :: !(Maybe Text)
  , rscReasoningEffort    :: !(Maybe Text)
  , rscTools              :: ![Tool]
  , rscSystemMessage      :: !(Maybe SystemMessageConfig)
  , rscAvailableTools     :: !(Maybe [Text])
  , rscExcludedTools      :: !(Maybe [Text])
  , rscProvider           :: !(Maybe ProviderConfig)
  , rscOnPermissionRequest :: !(Maybe PermissionHandler)
  , rscOnUserInputRequest :: !(Maybe UserInputHandler)
  , rscHooks              :: !(Maybe SessionHooks)
  , rscWorkingDirectory   :: !(Maybe Text)
  , rscConfigDir          :: !(Maybe Text)
  , rscStreaming          :: !(Maybe Bool)
  , rscMcpServers         :: !(Maybe (Map.Map Text MCPServerConfig))
  , rscCustomAgents       :: !(Maybe [CustomAgentConfig])
  , rscSkillDirectories   :: !(Maybe [Text])
  , rscDisabledSkills     :: !(Maybe [Text])
  , rscInfiniteSessions   :: !(Maybe InfiniteSessionConfig)
  , rscDisableResume      :: !(Maybe Bool)
  }

-- | Default (empty) resume session configuration.
defaultResumeSessionConfig :: ResumeSessionConfig
defaultResumeSessionConfig = ResumeSessionConfig
  { rscModel              = Nothing
  , rscReasoningEffort    = Nothing
  , rscTools              = []
  , rscSystemMessage      = Nothing
  , rscAvailableTools     = Nothing
  , rscExcludedTools      = Nothing
  , rscProvider           = Nothing
  , rscOnPermissionRequest = Nothing
  , rscOnUserInputRequest = Nothing
  , rscHooks              = Nothing
  , rscWorkingDirectory   = Nothing
  , rscConfigDir          = Nothing
  , rscStreaming          = Nothing
  , rscMcpServers         = Nothing
  , rscCustomAgents       = Nothing
  , rscSkillDirectories   = Nothing
  , rscDisabledSkills     = Nothing
  , rscInfiniteSessions   = Nothing
  , rscDisableResume      = Nothing
  }

-- ============================================================================
-- Message Options & Attachments
-- ============================================================================

-- | Attachment to a message (file, directory, or selection).
data Attachment = Attachment
  { attType        :: !Text
  , attPath        :: !(Maybe Text)
  , attFilePath    :: !(Maybe Text)
  , attDisplayName :: !(Maybe Text)
  , attText        :: !(Maybe Text)
  , attSelection   :: !(Maybe Value)
  } deriving (Show, Eq, Generic)

instance ToJSON Attachment where
  toJSON Attachment{..} = object
    [ "type"        .= attType
    , "path"        .= attPath
    , "filePath"    .= attFilePath
    , "displayName" .= attDisplayName
    , "text"        .= attText
    , "selection"   .= attSelection
    ]

instance FromJSON Attachment where
  parseJSON = withObject "Attachment" $ \o ->
    Attachment
      <$> o .:  "type"
      <*> o .:? "path"
      <*> o .:? "filePath"
      <*> o .:? "displayName"
      <*> o .:? "text"
      <*> o .:? "selection"

-- | Options for sending a message to a session.
data MessageOptions = MessageOptions
  { moPrompt      :: !Text
  , moAttachments :: !(Maybe [Attachment])
  , moMode        :: !(Maybe Text)  -- ^ "enqueue" or "immediate"
  } deriving (Show, Eq, Generic)

-- ============================================================================
-- Permission Types
-- ============================================================================

-- | A permission request from the server.
data PermissionRequest = PermissionRequest
  { prKind       :: !Text
  , prToolCallId :: !(Maybe Text)
  , prExtra      :: !(Map.Map Text Value)
  } deriving (Show, Eq, Generic)

instance FromJSON PermissionRequest where
  parseJSON = withObject "PermissionRequest" $ \o -> do
    kind <- o .: "kind"
    toolCallId <- o .:? "toolCallId"
    -- Parse the entire object as a Map, then remove known keys
    let allFields = case fromJSON (Object o) of
          Aeson.Success (m :: Map.Map Text Value) -> m
          Aeson.Error _   -> Map.empty
        extra = Map.delete "kind" . Map.delete "toolCallId" $ allFields
    pure $ PermissionRequest kind toolCallId extra

instance ToJSON PermissionRequest where
  toJSON PermissionRequest{..} =
    let base = Map.insert "kind" (toJSON prKind)
             $ maybe id (\tc -> Map.insert "toolCallId" (toJSON tc)) prToolCallId
             $ prExtra
    in  toJSON base

-- | Result of a permission request.
data PermissionRequestResult = PermissionRequestResult
  { prrKind  :: !Text
  , prrRules :: !(Maybe [Value])
  } deriving (Show, Eq, Generic)

instance ToJSON PermissionRequestResult where
  toJSON PermissionRequestResult{..} = object
    [ "kind"  .= prrKind
    , "rules" .= prrRules
    ]

instance FromJSON PermissionRequestResult where
  parseJSON = withObject "PermissionRequestResult" $ \o ->
    PermissionRequestResult
      <$> o .:  "kind"
      <*> o .:? "rules"

-- | Permission handler callback.
type PermissionHandler = PermissionRequest -> Text -> IO PermissionRequestResult

-- ============================================================================
-- User Input Types
-- ============================================================================

-- | Request for user input from the agent.
data UserInputRequest = UserInputRequest
  { uirQuestion      :: !Text
  , uirChoices       :: !(Maybe [Text])
  , uirAllowFreeform :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)

instance ToJSON UserInputRequest where
  toJSON UserInputRequest{..} = object
    [ "question"      .= uirQuestion
    , "choices"       .= uirChoices
    , "allowFreeform" .= uirAllowFreeform
    ]

instance FromJSON UserInputRequest where
  parseJSON = withObject "UserInputRequest" $ \o ->
    UserInputRequest
      <$> o .:  "question"
      <*> o .:? "choices"
      <*> o .:? "allowFreeform"

-- | Response to a user input request.
data UserInputResponse = UserInputResponse
  { uirAnswer      :: !Text
  , uirWasFreeform :: !Bool
  } deriving (Show, Eq, Generic)

instance ToJSON UserInputResponse where
  toJSON UserInputResponse{..} = object
    [ "answer"      .= uirAnswer
    , "wasFreeform" .= uirWasFreeform
    ]

instance FromJSON UserInputResponse where
  parseJSON = withObject "UserInputResponse" $ \o ->
    UserInputResponse
      <$> o .:  "answer"
      <*> o .:  "wasFreeform"

-- | User input handler callback.
type UserInputHandler = UserInputRequest -> Text -> IO UserInputResponse

-- ============================================================================
-- Hook Types
-- ============================================================================

-- | Context about a hook invocation.
data HookInvocation = HookInvocation
  { hiSessionId :: !Text
  } deriving (Show, Eq, Generic)

-- | Input for pre-tool-use hook.
data PreToolUseHookInput = PreToolUseHookInput
  { ptuTimestamp :: !Integer
  , ptuCwd      :: !Text
  , ptuToolName :: !Text
  , ptuToolArgs :: !Value
  } deriving (Show, Eq, Generic)

instance FromJSON PreToolUseHookInput where
  parseJSON = withObject "PreToolUseHookInput" $ \o ->
    PreToolUseHookInput
      <$> o .: "timestamp"
      <*> o .: "cwd"
      <*> o .: "toolName"
      <*> o .: "toolArgs"

-- | Output for pre-tool-use hook.
data PreToolUseHookOutput = PreToolUseHookOutput
  { ptuoPermissionDecision       :: !(Maybe Text)
  , ptuoPermissionDecisionReason :: !(Maybe Text)
  , ptuoModifiedArgs             :: !(Maybe Value)
  , ptuoAdditionalContext        :: !(Maybe Text)
  , ptuoSuppressOutput           :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)

instance ToJSON PreToolUseHookOutput where
  toJSON PreToolUseHookOutput{..} = object
    [ "permissionDecision"       .= ptuoPermissionDecision
    , "permissionDecisionReason" .= ptuoPermissionDecisionReason
    , "modifiedArgs"             .= ptuoModifiedArgs
    , "additionalContext"        .= ptuoAdditionalContext
    , "suppressOutput"           .= ptuoSuppressOutput
    ]

-- | Input for post-tool-use hook.
data PostToolUseHookInput = PostToolUseHookInput
  { potuTimestamp  :: !Integer
  , potuCwd       :: !Text
  , potuToolName  :: !Text
  , potuToolArgs  :: !Value
  , potuToolResult :: !Value
  } deriving (Show, Eq, Generic)

instance FromJSON PostToolUseHookInput where
  parseJSON = withObject "PostToolUseHookInput" $ \o ->
    PostToolUseHookInput
      <$> o .: "timestamp"
      <*> o .: "cwd"
      <*> o .: "toolName"
      <*> o .: "toolArgs"
      <*> o .: "toolResult"

-- | Output for post-tool-use hook.
data PostToolUseHookOutput = PostToolUseHookOutput
  { potuoModifiedResult    :: !(Maybe Value)
  , potuoAdditionalContext :: !(Maybe Text)
  , potuoSuppressOutput    :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)

instance ToJSON PostToolUseHookOutput where
  toJSON PostToolUseHookOutput{..} = object
    [ "modifiedResult"    .= potuoModifiedResult
    , "additionalContext" .= potuoAdditionalContext
    , "suppressOutput"    .= potuoSuppressOutput
    ]

-- | Input for user-prompt-submitted hook.
data UserPromptSubmittedHookInput = UserPromptSubmittedHookInput
  { upsTimestamp :: !Integer
  , upsCwd      :: !Text
  , upsPrompt   :: !Text
  } deriving (Show, Eq, Generic)

instance FromJSON UserPromptSubmittedHookInput where
  parseJSON = withObject "UserPromptSubmittedHookInput" $ \o ->
    UserPromptSubmittedHookInput
      <$> o .: "timestamp"
      <*> o .: "cwd"
      <*> o .: "prompt"

-- | Output for user-prompt-submitted hook.
data UserPromptSubmittedHookOutput = UserPromptSubmittedHookOutput
  { upsoModifiedPrompt    :: !(Maybe Text)
  , upsoAdditionalContext :: !(Maybe Text)
  , upsoSuppressOutput    :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)

instance ToJSON UserPromptSubmittedHookOutput where
  toJSON UserPromptSubmittedHookOutput{..} = object
    [ "modifiedPrompt"    .= upsoModifiedPrompt
    , "additionalContext" .= upsoAdditionalContext
    , "suppressOutput"    .= upsoSuppressOutput
    ]

-- | Input for session-start hook.
data SessionStartHookInput = SessionStartHookInput
  { sshTimestamp     :: !Integer
  , sshCwd          :: !Text
  , sshSource       :: !Text
  , sshInitialPrompt :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance FromJSON SessionStartHookInput where
  parseJSON = withObject "SessionStartHookInput" $ \o ->
    SessionStartHookInput
      <$> o .: "timestamp"
      <*> o .: "cwd"
      <*> o .: "source"
      <*> o .:? "initialPrompt"

-- | Output for session-start hook.
data SessionStartHookOutput = SessionStartHookOutput
  { sshoAdditionalContext :: !(Maybe Text)
  , sshoModifiedConfig    :: !(Maybe (Map.Map Text Value))
  } deriving (Show, Eq, Generic)

instance ToJSON SessionStartHookOutput where
  toJSON SessionStartHookOutput{..} = object
    [ "additionalContext" .= sshoAdditionalContext
    , "modifiedConfig"    .= sshoModifiedConfig
    ]

-- | Input for session-end hook.
data SessionEndHookInput = SessionEndHookInput
  { sehTimestamp    :: !Integer
  , sehCwd         :: !Text
  , sehReason      :: !Text
  , sehFinalMessage :: !(Maybe Text)
  , sehError       :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance FromJSON SessionEndHookInput where
  parseJSON = withObject "SessionEndHookInput" $ \o ->
    SessionEndHookInput
      <$> o .: "timestamp"
      <*> o .: "cwd"
      <*> o .: "reason"
      <*> o .:? "finalMessage"
      <*> o .:? "error"

-- | Output for session-end hook.
data SessionEndHookOutput = SessionEndHookOutput
  { sehoSuppressOutput :: !(Maybe Bool)
  , sehoCleanupActions :: !(Maybe [Text])
  , sehoSessionSummary :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance ToJSON SessionEndHookOutput where
  toJSON SessionEndHookOutput{..} = object
    [ "suppressOutput" .= sehoSuppressOutput
    , "cleanupActions" .= sehoCleanupActions
    , "sessionSummary" .= sehoSessionSummary
    ]

-- | Input for error-occurred hook.
data ErrorOccurredHookInput = ErrorOccurredHookInput
  { eohTimestamp    :: !Integer
  , eohCwd         :: !Text
  , eohError       :: !Text
  , eohErrorContext :: !Text
  , eohRecoverable :: !Bool
  } deriving (Show, Eq, Generic)

instance FromJSON ErrorOccurredHookInput where
  parseJSON = withObject "ErrorOccurredHookInput" $ \o ->
    ErrorOccurredHookInput
      <$> o .: "timestamp"
      <*> o .: "cwd"
      <*> o .: "error"
      <*> o .: "errorContext"
      <*> o .: "recoverable"

-- | Output for error-occurred hook.
data ErrorOccurredHookOutput = ErrorOccurredHookOutput
  { eohoSuppressOutput   :: !(Maybe Bool)
  , eohoErrorHandling    :: !(Maybe Text)
  , eohoRetryCount       :: !(Maybe Int)
  , eohoUserNotification :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance ToJSON ErrorOccurredHookOutput where
  toJSON ErrorOccurredHookOutput{..} = object
    [ "suppressOutput"   .= eohoSuppressOutput
    , "errorHandling"    .= eohoErrorHandling
    , "retryCount"       .= eohoRetryCount
    , "userNotification" .= eohoUserNotification
    ]

-- | Session hooks configuration.
data SessionHooks = SessionHooks
  { shOnPreToolUse          :: !(Maybe (PreToolUseHookInput -> HookInvocation -> IO (Maybe PreToolUseHookOutput)))
  , shOnPostToolUse         :: !(Maybe (PostToolUseHookInput -> HookInvocation -> IO (Maybe PostToolUseHookOutput)))
  , shOnUserPromptSubmitted :: !(Maybe (UserPromptSubmittedHookInput -> HookInvocation -> IO (Maybe UserPromptSubmittedHookOutput)))
  , shOnSessionStart        :: !(Maybe (SessionStartHookInput -> HookInvocation -> IO (Maybe SessionStartHookOutput)))
  , shOnSessionEnd          :: !(Maybe (SessionEndHookInput -> HookInvocation -> IO (Maybe SessionEndHookOutput)))
  , shOnErrorOccurred       :: !(Maybe (ErrorOccurredHookInput -> HookInvocation -> IO (Maybe ErrorOccurredHookOutput)))
  }

-- | Default (empty) session hooks.
defaultSessionHooks :: SessionHooks
defaultSessionHooks = SessionHooks Nothing Nothing Nothing Nothing Nothing Nothing

-- ============================================================================
-- Session Events
-- ============================================================================

-- | A session event from the server.
-- Uses a generic representation: type tag + JSON data payload.
data SessionEvent = SessionEvent
  { seId        :: !Text
  , seTimestamp :: !Text
  , seParentId  :: !(Maybe Text)
  , seEphemeral :: !(Maybe Bool)
  , seType      :: !Text
  , seData      :: !Value
  } deriving (Show, Eq, Generic)

instance ToJSON SessionEvent where
  toJSON SessionEvent{..} = object
    [ "id"        .= seId
    , "timestamp" .= seTimestamp
    , "parentId"  .= seParentId
    , "ephemeral" .= seEphemeral
    , "type"      .= seType
    , "data"      .= seData
    ]

instance FromJSON SessionEvent where
  parseJSON = withObject "SessionEvent" $ \o ->
    SessionEvent
      <$> o .:  "id"
      <*> o .:  "timestamp"
      <*> o .:? "parentId"
      <*> o .:? "ephemeral"
      <*> o .:  "type"
      <*> o .:  "data"

-- | Session event handler callback.
type SessionEventHandler = SessionEvent -> IO ()

-- ============================================================================
-- Ping / Status / Auth Responses
-- ============================================================================

-- | Response from a ping request.
data PingResponse = PingResponse
  { pingMessage         :: !Text
  , pingTimestamp       :: !Integer
  , pingProtocolVersion :: !(Maybe Int)
  } deriving (Show, Eq, Generic)

instance FromJSON PingResponse where
  parseJSON = withObject "PingResponse" $ \o ->
    PingResponse
      <$> o .:  "message"
      <*> o .:  "timestamp"
      <*> o .:? "protocolVersion"

instance ToJSON PingResponse where
  toJSON PingResponse{..} = object
    [ "message"         .= pingMessage
    , "timestamp"       .= pingTimestamp
    , "protocolVersion" .= pingProtocolVersion
    ]

-- | Response from status.get.
data GetStatusResponse = GetStatusResponse
  { gsrVersion         :: !Text
  , gsrProtocolVersion :: !Int
  } deriving (Show, Eq, Generic)

instance FromJSON GetStatusResponse where
  parseJSON = withObject "GetStatusResponse" $ \o ->
    GetStatusResponse
      <$> o .: "version"
      <*> o .: "protocolVersion"

instance ToJSON GetStatusResponse where
  toJSON GetStatusResponse{..} = object
    [ "version"         .= gsrVersion
    , "protocolVersion" .= gsrProtocolVersion
    ]

-- | Response from auth.getStatus.
data GetAuthStatusResponse = GetAuthStatusResponse
  { gasIsAuthenticated :: !Bool
  , gasAuthType        :: !(Maybe Text)
  , gasHost            :: !(Maybe Text)
  , gasLogin           :: !(Maybe Text)
  , gasStatusMessage   :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance FromJSON GetAuthStatusResponse where
  parseJSON = withObject "GetAuthStatusResponse" $ \o ->
    GetAuthStatusResponse
      <$> o .:  "isAuthenticated"
      <*> o .:? "authType"
      <*> o .:? "host"
      <*> o .:? "login"
      <*> o .:? "statusMessage"

instance ToJSON GetAuthStatusResponse where
  toJSON GetAuthStatusResponse{..} = object
    [ "isAuthenticated" .= gasIsAuthenticated
    , "authType"        .= gasAuthType
    , "host"            .= gasHost
    , "login"           .= gasLogin
    , "statusMessage"   .= gasStatusMessage
    ]

-- ============================================================================
-- Model Types
-- ============================================================================

-- | Model support flags.
data ModelSupports = ModelSupports
  { msVision          :: !Bool
  , msReasoningEffort :: !Bool
  } deriving (Show, Eq, Generic)

instance FromJSON ModelSupports where
  parseJSON = withObject "ModelSupports" $ \o ->
    ModelSupports
      <$> o .: "vision"
      <*> o .: "reasoningEffort"

instance ToJSON ModelSupports where
  toJSON ModelSupports{..} = object
    [ "vision"          .= msVision
    , "reasoningEffort" .= msReasoningEffort
    ]

-- | Vision-specific limits.
data ModelVisionLimits = ModelVisionLimits
  { mvlSupportedMediaTypes :: ![Text]
  , mvlMaxPromptImages     :: !Int
  , mvlMaxPromptImageSize  :: !Int
  } deriving (Show, Eq, Generic)

instance FromJSON ModelVisionLimits where
  parseJSON = withObject "ModelVisionLimits" $ \o ->
    ModelVisionLimits
      <$> o .: "supported_media_types"
      <*> o .: "max_prompt_images"
      <*> o .: "max_prompt_image_size"

instance ToJSON ModelVisionLimits where
  toJSON ModelVisionLimits{..} = object
    [ "supported_media_types" .= mvlSupportedMediaTypes
    , "max_prompt_images"     .= mvlMaxPromptImages
    , "max_prompt_image_size" .= mvlMaxPromptImageSize
    ]

-- | Model limits.
data ModelLimits = ModelLimits
  { mlMaxPromptTokens        :: !(Maybe Int)
  , mlMaxContextWindowTokens :: !Int
  , mlVision                 :: !(Maybe ModelVisionLimits)
  } deriving (Show, Eq, Generic)

instance FromJSON ModelLimits where
  parseJSON = withObject "ModelLimits" $ \o ->
    ModelLimits
      <$> o .:? "max_prompt_tokens"
      <*> o .:  "max_context_window_tokens"
      <*> o .:? "vision"

instance ToJSON ModelLimits where
  toJSON ModelLimits{..} = object
    [ "max_prompt_tokens"         .= mlMaxPromptTokens
    , "max_context_window_tokens" .= mlMaxContextWindowTokens
    , "vision"                    .= mlVision
    ]

-- | Model capabilities.
data ModelCapabilities = ModelCapabilities
  { mcSupports :: !ModelSupports
  , mcLimits   :: !ModelLimits
  } deriving (Show, Eq, Generic)

instance FromJSON ModelCapabilities where
  parseJSON = withObject "ModelCapabilities" $ \o ->
    ModelCapabilities
      <$> o .: "supports"
      <*> o .: "limits"

instance ToJSON ModelCapabilities where
  toJSON ModelCapabilities{..} = object
    [ "supports" .= mcSupports
    , "limits"   .= mcLimits
    ]

-- | Model policy state.
data ModelPolicy = ModelPolicy
  { mpState :: !Text
  , mpTerms :: !Text
  } deriving (Show, Eq, Generic)

instance FromJSON ModelPolicy where
  parseJSON = withObject "ModelPolicy" $ \o ->
    ModelPolicy
      <$> o .: "state"
      <*> o .: "terms"

instance ToJSON ModelPolicy where
  toJSON ModelPolicy{..} = object
    [ "state" .= mpState
    , "terms" .= mpTerms
    ]

-- | Model billing information.
data ModelBilling = ModelBilling
  { mbMultiplier :: !Double
  } deriving (Show, Eq, Generic)

instance FromJSON ModelBilling where
  parseJSON = withObject "ModelBilling" $ \o ->
    ModelBilling <$> o .: "multiplier"

instance ToJSON ModelBilling where
  toJSON ModelBilling{..} = object [ "multiplier" .= mbMultiplier ]

-- | Information about an available model.
data ModelInfo = ModelInfo
  { miId                        :: !Text
  , miName                      :: !Text
  , miCapabilities              :: !ModelCapabilities
  , miPolicy                    :: !(Maybe ModelPolicy)
  , miBilling                   :: !(Maybe ModelBilling)
  , miSupportedReasoningEfforts :: !(Maybe [Text])
  , miDefaultReasoningEffort    :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance FromJSON ModelInfo where
  parseJSON = withObject "ModelInfo" $ \o ->
    ModelInfo
      <$> o .:  "id"
      <*> o .:  "name"
      <*> o .:  "capabilities"
      <*> o .:? "policy"
      <*> o .:? "billing"
      <*> o .:? "supportedReasoningEfforts"
      <*> o .:? "defaultReasoningEffort"

instance ToJSON ModelInfo where
  toJSON ModelInfo{..} = object
    [ "id"                        .= miId
    , "name"                      .= miName
    , "capabilities"              .= miCapabilities
    , "policy"                    .= miPolicy
    , "billing"                   .= miBilling
    , "supportedReasoningEfforts" .= miSupportedReasoningEfforts
    , "defaultReasoningEffort"    .= miDefaultReasoningEffort
    ]

-- ============================================================================
-- Session Metadata & Lifecycle
-- ============================================================================

-- | Metadata about a session.
data SessionMetadata = SessionMetadata
  { smSessionId    :: !Text
  , smStartTime    :: !Text
  , smModifiedTime :: !Text
  , smSummary      :: !(Maybe Text)
  , smIsRemote     :: !Bool
  } deriving (Show, Eq, Generic)

instance FromJSON SessionMetadata where
  parseJSON = withObject "SessionMetadata" $ \o ->
    SessionMetadata
      <$> o .:  "sessionId"
      <*> o .:  "startTime"
      <*> o .:  "modifiedTime"
      <*> o .:? "summary"
      <*> o .:  "isRemote"

instance ToJSON SessionMetadata where
  toJSON SessionMetadata{..} = object
    [ "sessionId"    .= smSessionId
    , "startTime"    .= smStartTime
    , "modifiedTime" .= smModifiedTime
    , "summary"      .= smSummary
    , "isRemote"     .= smIsRemote
    ]

-- | Session lifecycle event notification.
data SessionLifecycleEvent = SessionLifecycleEvent
  { sleType      :: !Text
  , sleSessionId :: !Text
  , sleMetadata  :: !(Maybe Value)
  } deriving (Show, Eq, Generic)

instance FromJSON SessionLifecycleEvent where
  parseJSON = withObject "SessionLifecycleEvent" $ \o ->
    SessionLifecycleEvent
      <$> o .:  "type"
      <*> o .:  "sessionId"
      <*> o .:? "metadata"

instance ToJSON SessionLifecycleEvent where
  toJSON SessionLifecycleEvent{..} = object
    [ "type"      .= sleType
    , "sessionId" .= sleSessionId
    , "metadata"  .= sleMetadata
    ]

-- | Session lifecycle handler callback.
type SessionLifecycleHandler = SessionLifecycleEvent -> IO ()

-- ============================================================================
-- Client Options
-- ============================================================================

-- | Options for creating a 'CopilotClient'.
data CopilotClientOptions = CopilotClientOptions
  { ccoCliPath        :: !(Maybe FilePath)
  , ccoCliArgs        :: ![String]
  , ccoCwd            :: !(Maybe FilePath)
  , ccoLogLevel       :: !Text
  , ccoAutoStart      :: !Bool
  , ccoAutoRestart    :: !Bool
  , ccoEnv            :: !(Maybe [(String, String)])
  , ccoGithubToken    :: !(Maybe Text)
  , ccoUseLoggedInUser :: !(Maybe Bool)
  }

-- | Default client options.
defaultClientOptions :: CopilotClientOptions
defaultClientOptions = CopilotClientOptions
  { ccoCliPath         = Nothing
  , ccoCliArgs         = []
  , ccoCwd             = Nothing
  , ccoLogLevel        = "info"
  , ccoAutoStart       = True
  , ccoAutoRestart     = True
  , ccoEnv             = Nothing
  , ccoGithubToken     = Nothing
  , ccoUseLoggedInUser = Nothing
  }
