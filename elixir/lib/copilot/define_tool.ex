defmodule Copilot.DefineTool do
  @moduledoc """
  Helper for defining tools to expose to the Copilot CLI.

  Provides a convenient function for creating `Copilot.Types.Tool` structs
  with proper JSON schema parameters.

  ## Examples

  ### Simple tool (no parameters)

      tool = Copilot.DefineTool.define("get_time",
        description: "Returns the current UTC time",
        handler: fn _args, _inv -> DateTime.utc_now() |> DateTime.to_iso8601() end
      )

  ### Tool with JSON schema parameters

      tool = Copilot.DefineTool.define("lookup_fact",
        description: "Returns a fun fact about a given topic.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "topic" => %{
              "type" => "string",
              "description" => "Topic to look up (e.g. 'javascript', 'node')"
            }
          },
          "required" => ["topic"]
        },
        handler: fn %{"topic" => topic}, _invocation ->
          facts = %{
            "javascript" => "JavaScript was created in 10 days by Brendan Eich.",
            "node" => "Node.js uses the V8 engine."
          }
          Map.get(facts, String.downcase(topic), "No fact stored for \#{topic}.")
        end
      )

  ### Using the macro for cleaner syntax

      use Copilot.DefineTool

      deftool :weather, "Get weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["city"]
        } do
        fn %{"city" => city}, _inv ->
          "The weather in \#{city} is sunny, 72F."
        end
      end
  """

  alias Copilot.Types.Tool

  @doc """
  Define a tool with the given name and options.

  ## Options

    * `:description` - Description shown to the LLM (required).
    * `:parameters` - JSON schema map for tool parameters (optional).
    * `:handler` - A 2-arity function `(args, invocation) -> result`.
      The result can be:
      - A string (wrapped as success)
      - A `Copilot.Types.ToolResult` struct
      - Any term (JSON-encoded as success)
  """
  @spec define(String.t(), keyword()) :: Tool.t()
  def define(name, opts) when is_binary(name) do
    description = Keyword.get(opts, :description)
    parameters = Keyword.get(opts, :parameters)
    handler = Keyword.fetch!(opts, :handler)

    %Tool{
      name: name,
      description: description,
      parameters: parameters,
      handler: handler
    }
  end

  @doc """
  Convenience for defining a tool from a keyword list that includes `:name`.
  """
  @spec define(keyword()) :: Tool.t()
  def define(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    define(name, opts)
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Copilot.DefineTool, only: [deftool: 4]
    end
  end

  @doc """
  Macro for defining a tool inline.

  ## Example

      use Copilot.DefineTool

      deftool :echo, "Echoes back the input",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string"}
          },
          "required" => ["text"]
        } do
        fn %{"text" => text}, _inv -> text end
      end

  Returns a `Copilot.Types.Tool` struct bound to a variable with the tool name.
  """
  defmacro deftool(name, description, opts, do: handler_block) do
    var_name = name

    quote do
      unquote(Macro.var(var_name, nil)) =
        Copilot.DefineTool.define(to_string(unquote(name)),
          description: unquote(description),
          parameters: Keyword.get(unquote(opts), :parameters),
          handler: unquote(handler_block)
        )
    end
  end
end
