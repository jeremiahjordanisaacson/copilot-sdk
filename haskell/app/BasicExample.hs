---------------------------------------------------------------------------------------------
--  Copyright (c) Microsoft Corporation. All rights reserved.
---------------------------------------------------------------------------------------------

{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Basic example demonstrating the Copilot Haskell SDK.
--
-- This example:
-- 1. Creates a CopilotClient that spawns the CLI process
-- 2. Creates a session with a custom tool
-- 3. Subscribes to events to print assistant messages
-- 4. Sends a prompt and waits for the response
-- 5. Cleans up resources
module Main where

import           Control.Monad    (forM_)
import           Data.Aeson       (FromJSON, Value (..), (.=), object)
import qualified Data.Aeson       as Aeson
import           Data.Text        (Text)
import qualified Data.Text        as T
import qualified Data.Text.IO     as TIO
import           GHC.Generics     (Generic)

import           Copilot.Client
import           Copilot.DefineTool
import           Copilot.Session
import           Copilot.Types

-- | Arguments for our example "get_weather" tool.
data WeatherArgs = WeatherArgs
  { city :: !Text
  , unit :: !Text
  } deriving (Show, Generic)

instance FromJSON WeatherArgs

-- | The weather tool definition.
weatherTool :: Tool
weatherTool = defineSimpleTool
  "get_weather"
  (Just "Get the current weather for a city")
  (Just $ object
    [ "type"       .= ("object" :: Text)
    , "properties" .= object
        [ "city" .= object [ "type" .= ("string" :: Text), "description" .= ("City name" :: Text) ]
        , "unit" .= object [ "type" .= ("string" :: Text), "description" .= ("Temperature unit: celsius or fahrenheit" :: Text) ]
        ]
    , "required" .= (["city"] :: [Text])
    ])
  (\(WeatherArgs c u) _inv -> do
    let temp = if u == "fahrenheit" then "72F" else "22C"
    pure $ "Weather in " <> c <> ": " <> temp <> ", sunny"
  )

main :: IO ()
main = do
  TIO.putStrLn "=== Copilot Haskell SDK Basic Example ==="
  TIO.putStrLn ""

  -- Create a client with default options
  client <- newCopilotClient defaultClientOptions

  -- Start the client (spawns CLI process, verifies protocol version)
  TIO.putStrLn "Starting Copilot client..."
  startClient client

  state <- getClientState client
  TIO.putStrLn $ "Client state: " <> T.pack (show state)

  -- Ping the server
  TIO.putStrLn "Pinging server..."
  pingResp <- ping client (Just "hello from haskell")
  TIO.putStrLn $ "Ping response: " <> pingMessage pingResp

  -- List available models
  TIO.putStrLn "Listing models..."
  models <- listModels client
  forM_ models $ \model ->
    TIO.putStrLn $ "  Model: " <> miId model <> " (" <> miName model <> ")"

  -- Create a session with our weather tool
  TIO.putStrLn ""
  TIO.putStrLn "Creating session..."
  session <- createSession client defaultSessionConfig
    { scTools = [weatherTool]
    }

  -- Subscribe to events
  unsubscribe <- onSessionEvent session $ \evt -> do
    case seType evt of
      "assistant.message" -> do
        let mContent = Aeson.parseMaybe (Aeson.withObject "" $ \o -> o Aeson..: "content") (seData evt) :: Maybe Text
        case mContent of
          Just content -> TIO.putStrLn $ "\n[Assistant] " <> content
          Nothing      -> pure ()
      "tool.execution_start" -> do
        let mToolName = Aeson.parseMaybe (Aeson.withObject "" $ \o -> o Aeson..: "toolName") (seData evt) :: Maybe Text
        case mToolName of
          Just tn -> TIO.putStrLn $ "[Tool] Executing: " <> tn
          Nothing -> pure ()
      "tool.execution_complete" -> do
        TIO.putStrLn "[Tool] Execution complete"
      "session.idle" -> do
        TIO.putStrLn "[Session] Idle"
      _ -> pure ()

  -- Send a message and wait for completion
  TIO.putStrLn ""
  TIO.putStrLn "Sending message: \"What is the weather in San Francisco?\""
  mResponse <- sendAndWait session
    (MessageOptions
      { moPrompt      = "What is the weather in San Francisco?"
      , moAttachments = Nothing
      , moMode        = Nothing
      })
    Nothing  -- Use default 60s timeout

  case mResponse of
    Just evt -> do
      let mContent = Aeson.parseMaybe (Aeson.withObject "" $ \o -> o Aeson..: "content") (seData evt) :: Maybe Text
      TIO.putStrLn $ "\nFinal response: " <> maybe "(no content)" id mContent
    Nothing ->
      TIO.putStrLn "\nNo assistant message received."

  -- Get conversation history
  TIO.putStrLn ""
  TIO.putStrLn "Session history:"
  messages <- getMessages session
  forM_ messages $ \msg ->
    TIO.putStrLn $ "  [" <> seType msg <> "] " <> T.take 80 (T.pack $ show $ seData msg)

  -- Clean up
  TIO.putStrLn ""
  TIO.putStrLn "Cleaning up..."
  unsubscribe
  destroySession session
  errors <- stopClient client
  forM_ errors $ \err ->
    TIO.putStrLn $ "Cleanup error: " <> err

  TIO.putStrLn "Done."
