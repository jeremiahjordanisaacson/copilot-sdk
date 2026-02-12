<?php

declare(strict_types=1);

/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

namespace GitHub\Copilot;

/**
 * Type definitions for the Copilot SDK.
 *
 * All types are modeled as PHP classes with public properties, mirroring the
 * TypeScript/Python SDK interfaces.
 */

// ============================================================================
// Connection State
// ============================================================================

enum ConnectionState: string
{
    case Disconnected = 'disconnected';
    case Connecting = 'connecting';
    case Connected = 'connected';
    case Error = 'error';
}

// ============================================================================
// Log Level
// ============================================================================

enum LogLevel: string
{
    case None = 'none';
    case Error = 'error';
    case Warning = 'warning';
    case Info = 'info';
    case Debug = 'debug';
    case All = 'all';
}

// ============================================================================
// Tool Result Types
// ============================================================================

enum ToolResultType: string
{
    case Success = 'success';
    case Failure = 'failure';
    case Rejected = 'rejected';
    case Denied = 'denied';
}

class ToolBinaryResult
{
    public function __construct(
        public readonly string $data,
        public readonly string $mimeType,
        public readonly string $type,
        public readonly ?string $description = null,
    ) {}

    public function toArray(): array
    {
        $result = [
            'data' => $this->data,
            'mimeType' => $this->mimeType,
            'type' => $this->type,
        ];
        if ($this->description !== null) {
            $result['description'] = $this->description;
        }
        return $result;
    }

    public static function fromArray(array $data): self
    {
        return new self(
            data: $data['data'] ?? '',
            mimeType: $data['mimeType'] ?? '',
            type: $data['type'] ?? '',
            description: $data['description'] ?? null,
        );
    }
}

class ToolResultObject
{
    public function __construct(
        public readonly string $textResultForLlm,
        public readonly string $resultType = 'success',
        /** @var ToolBinaryResult[]|null */
        public readonly ?array $binaryResultsForLlm = null,
        public readonly ?string $error = null,
        public readonly ?string $sessionLog = null,
        public readonly ?array $toolTelemetry = null,
    ) {}

    public function toArray(): array
    {
        $result = [
            'textResultForLlm' => $this->textResultForLlm,
            'resultType' => $this->resultType,
        ];
        if ($this->binaryResultsForLlm !== null) {
            $result['binaryResultsForLlm'] = array_map(
                fn(ToolBinaryResult $b) => $b->toArray(),
                $this->binaryResultsForLlm,
            );
        }
        if ($this->error !== null) {
            $result['error'] = $this->error;
        }
        if ($this->sessionLog !== null) {
            $result['sessionLog'] = $this->sessionLog;
        }
        if ($this->toolTelemetry !== null) {
            $result['toolTelemetry'] = $this->toolTelemetry;
        }
        return $result;
    }

    public static function fromArray(array $data): self
    {
        $binaryResults = null;
        if (isset($data['binaryResultsForLlm'])) {
            $binaryResults = array_map(
                fn(array $b) => ToolBinaryResult::fromArray($b),
                $data['binaryResultsForLlm'],
            );
        }
        return new self(
            textResultForLlm: $data['textResultForLlm'] ?? '',
            resultType: $data['resultType'] ?? 'success',
            binaryResultsForLlm: $binaryResults,
            error: $data['error'] ?? null,
            sessionLog: $data['sessionLog'] ?? null,
            toolTelemetry: $data['toolTelemetry'] ?? null,
        );
    }
}

// ============================================================================
// Tool Types
// ============================================================================

class ToolInvocation
{
    public function __construct(
        public readonly string $sessionId,
        public readonly string $toolCallId,
        public readonly string $toolName,
        public readonly mixed $arguments,
    ) {}
}

class Tool
{
    /**
     * @param string $name Tool name
     * @param string|null $description Tool description
     * @param array|null $parameters JSON Schema parameters
     * @param callable $handler Function(mixed $args, ToolInvocation $invocation): mixed
     */
    public function __construct(
        public readonly string $name,
        public readonly ?string $description = null,
        public readonly ?array $parameters = null,
        public /* readonly */ $handler = null,
    ) {}

    public function toServerFormat(): array
    {
        $result = ['name' => $this->name];
        if ($this->description !== null) {
            $result['description'] = $this->description;
        }
        if ($this->parameters !== null) {
            $result['parameters'] = $this->parameters;
        }
        return $result;
    }
}

// ============================================================================
// System Message Configuration
// ============================================================================

class SystemMessageAppendConfig
{
    public function __construct(
        public readonly ?string $content = null,
    ) {}

    public function toArray(): array
    {
        $result = ['mode' => 'append'];
        if ($this->content !== null) {
            $result['content'] = $this->content;
        }
        return $result;
    }
}

class SystemMessageReplaceConfig
{
    public function __construct(
        public readonly string $content,
    ) {}

    public function toArray(): array
    {
        return [
            'mode' => 'replace',
            'content' => $this->content,
        ];
    }
}

// ============================================================================
// Permission Types
// ============================================================================

class PermissionRequest
{
    public function __construct(
        public readonly string $kind,
        public readonly ?string $toolCallId = null,
        public readonly array $extra = [],
    ) {}

    public static function fromArray(array $data): self
    {
        $kind = $data['kind'] ?? '';
        $toolCallId = $data['toolCallId'] ?? null;
        $extra = array_diff_key($data, array_flip(['kind', 'toolCallId']));
        return new self($kind, $toolCallId, $extra);
    }

    public function toArray(): array
    {
        $result = array_merge($this->extra, ['kind' => $this->kind]);
        if ($this->toolCallId !== null) {
            $result['toolCallId'] = $this->toolCallId;
        }
        return $result;
    }
}

class PermissionRequestResult
{
    public function __construct(
        public readonly string $kind,
        public readonly ?array $rules = null,
    ) {}

    public function toArray(): array
    {
        $result = ['kind' => $this->kind];
        if ($this->rules !== null) {
            $result['rules'] = $this->rules;
        }
        return $result;
    }
}

// ============================================================================
// User Input Types
// ============================================================================

class UserInputRequest
{
    public function __construct(
        public readonly string $question,
        /** @var string[]|null */
        public readonly ?array $choices = null,
        public readonly ?bool $allowFreeform = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            question: $data['question'] ?? '',
            choices: $data['choices'] ?? null,
            allowFreeform: $data['allowFreeform'] ?? null,
        );
    }
}

class UserInputResponse
{
    public function __construct(
        public readonly string $answer,
        public readonly bool $wasFreeform,
    ) {}

    public function toArray(): array
    {
        return [
            'answer' => $this->answer,
            'wasFreeform' => $this->wasFreeform,
        ];
    }
}

// ============================================================================
// Provider Configuration
// ============================================================================

class AzureProviderOptions
{
    public function __construct(
        public readonly ?string $apiVersion = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->apiVersion !== null) {
            $result['apiVersion'] = $this->apiVersion;
        }
        return $result;
    }
}

class ProviderConfig
{
    public function __construct(
        public readonly string $baseUrl,
        public readonly ?string $type = null,
        public readonly ?string $wireApi = null,
        public readonly ?string $apiKey = null,
        public readonly ?string $bearerToken = null,
        public readonly ?AzureProviderOptions $azure = null,
    ) {}

    public function toArray(): array
    {
        $result = ['baseUrl' => $this->baseUrl];
        if ($this->type !== null) {
            $result['type'] = $this->type;
        }
        if ($this->wireApi !== null) {
            $result['wireApi'] = $this->wireApi;
        }
        if ($this->apiKey !== null) {
            $result['apiKey'] = $this->apiKey;
        }
        if ($this->bearerToken !== null) {
            $result['bearerToken'] = $this->bearerToken;
        }
        if ($this->azure !== null) {
            $result['azure'] = $this->azure->toArray();
        }
        return $result;
    }
}

// ============================================================================
// MCP Server Configuration
// ============================================================================

class MCPLocalServerConfig
{
    /**
     * @param string[] $tools List of tools to include. [] means none.
     * @param string $command Command to run
     * @param string[] $args Command arguments
     * @param string|null $type Server type (local/stdio)
     * @param int|null $timeout Timeout in milliseconds
     * @param array<string,string>|null $env Environment variables
     * @param string|null $cwd Working directory
     */
    public function __construct(
        public readonly array $tools,
        public readonly string $command,
        public readonly array $args,
        public readonly ?string $type = null,
        public readonly ?int $timeout = null,
        public readonly ?array $env = null,
        public readonly ?string $cwd = null,
    ) {}

    public function toArray(): array
    {
        $result = [
            'tools' => $this->tools,
            'command' => $this->command,
            'args' => $this->args,
        ];
        if ($this->type !== null) {
            $result['type'] = $this->type;
        }
        if ($this->timeout !== null) {
            $result['timeout'] = $this->timeout;
        }
        if ($this->env !== null) {
            $result['env'] = $this->env;
        }
        if ($this->cwd !== null) {
            $result['cwd'] = $this->cwd;
        }
        return $result;
    }
}

class MCPRemoteServerConfig
{
    /**
     * @param string[] $tools List of tools to include
     * @param string $type Server type (http/sse)
     * @param string $url URL of the remote server
     * @param int|null $timeout Timeout in milliseconds
     * @param array<string,string>|null $headers HTTP headers
     */
    public function __construct(
        public readonly array $tools,
        public readonly string $type,
        public readonly string $url,
        public readonly ?int $timeout = null,
        public readonly ?array $headers = null,
    ) {}

    public function toArray(): array
    {
        $result = [
            'tools' => $this->tools,
            'type' => $this->type,
            'url' => $this->url,
        ];
        if ($this->timeout !== null) {
            $result['timeout'] = $this->timeout;
        }
        if ($this->headers !== null) {
            $result['headers'] = $this->headers;
        }
        return $result;
    }
}

// ============================================================================
// Custom Agent Configuration
// ============================================================================

class CustomAgentConfig
{
    /**
     * @param string $name Unique name
     * @param string $prompt The prompt content
     * @param string|null $displayName Display name
     * @param string|null $description Description
     * @param string[]|null $tools Tool names (null for all)
     * @param array<string,MCPLocalServerConfig|MCPRemoteServerConfig>|null $mcpServers
     * @param bool|null $infer Whether available for inference
     */
    public function __construct(
        public readonly string $name,
        public readonly string $prompt,
        public readonly ?string $displayName = null,
        public readonly ?string $description = null,
        public readonly ?array $tools = null,
        public readonly ?array $mcpServers = null,
        public readonly ?bool $infer = null,
    ) {}

    public function toArray(): array
    {
        $result = [
            'name' => $this->name,
            'prompt' => $this->prompt,
        ];
        if ($this->displayName !== null) {
            $result['displayName'] = $this->displayName;
        }
        if ($this->description !== null) {
            $result['description'] = $this->description;
        }
        if ($this->tools !== null) {
            $result['tools'] = $this->tools;
        }
        if ($this->mcpServers !== null) {
            $result['mcpServers'] = array_map(
                fn($s) => $s->toArray(),
                $this->mcpServers,
            );
        }
        if ($this->infer !== null) {
            $result['infer'] = $this->infer;
        }
        return $result;
    }
}

// ============================================================================
// Infinite Session Configuration
// ============================================================================

class InfiniteSessionConfig
{
    public function __construct(
        public readonly ?bool $enabled = null,
        public readonly ?float $backgroundCompactionThreshold = null,
        public readonly ?float $bufferExhaustionThreshold = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->enabled !== null) {
            $result['enabled'] = $this->enabled;
        }
        if ($this->backgroundCompactionThreshold !== null) {
            $result['backgroundCompactionThreshold'] = $this->backgroundCompactionThreshold;
        }
        if ($this->bufferExhaustionThreshold !== null) {
            $result['bufferExhaustionThreshold'] = $this->bufferExhaustionThreshold;
        }
        return $result;
    }
}

// ============================================================================
// Reasoning Effort
// ============================================================================

enum ReasoningEffort: string
{
    case Low = 'low';
    case Medium = 'medium';
    case High = 'high';
    case XHigh = 'xhigh';
}

// ============================================================================
// Session Configuration
// ============================================================================

class SessionConfig
{
    /**
     * @param string|null $sessionId Optional custom session ID
     * @param string|null $model Model to use
     * @param ReasoningEffort|null $reasoningEffort Reasoning effort level
     * @param string|null $configDir Override config directory
     * @param Tool[]|null $tools Tools exposed to CLI server
     * @param SystemMessageAppendConfig|SystemMessageReplaceConfig|null $systemMessage
     * @param string[]|null $availableTools Tool names to allow
     * @param string[]|null $excludedTools Tool names to disable
     * @param ProviderConfig|null $provider Custom BYOK provider
     * @param callable|null $onPermissionRequest Permission handler
     * @param callable|null $onUserInputRequest User input handler
     * @param SessionHooks|null $hooks Hook handlers
     * @param string|null $workingDirectory Working directory
     * @param bool|null $streaming Enable streaming
     * @param array<string,MCPLocalServerConfig|MCPRemoteServerConfig>|null $mcpServers
     * @param CustomAgentConfig[]|null $customAgents
     * @param string[]|null $skillDirectories
     * @param string[]|null $disabledSkills
     * @param InfiniteSessionConfig|null $infiniteSessions
     */
    public function __construct(
        public readonly ?string $sessionId = null,
        public readonly ?string $model = null,
        public readonly ?ReasoningEffort $reasoningEffort = null,
        public readonly ?string $configDir = null,
        public readonly ?array $tools = null,
        public readonly SystemMessageAppendConfig|SystemMessageReplaceConfig|null $systemMessage = null,
        public readonly ?array $availableTools = null,
        public readonly ?array $excludedTools = null,
        public readonly ?ProviderConfig $provider = null,
        public /* readonly */ $onPermissionRequest = null,
        public /* readonly */ $onUserInputRequest = null,
        public readonly ?SessionHooks $hooks = null,
        public readonly ?string $workingDirectory = null,
        public readonly ?bool $streaming = null,
        public readonly ?array $mcpServers = null,
        public readonly ?array $customAgents = null,
        public readonly ?array $skillDirectories = null,
        public readonly ?array $disabledSkills = null,
        public readonly ?InfiniteSessionConfig $infiniteSessions = null,
    ) {}

    public function toServerParams(): array
    {
        $params = [];
        if ($this->sessionId !== null) {
            $params['sessionId'] = $this->sessionId;
        }
        if ($this->model !== null) {
            $params['model'] = $this->model;
        }
        if ($this->reasoningEffort !== null) {
            $params['reasoningEffort'] = $this->reasoningEffort->value;
        }
        if ($this->configDir !== null) {
            $params['configDir'] = $this->configDir;
        }
        if ($this->tools !== null) {
            $params['tools'] = array_map(
                fn(Tool $t) => $t->toServerFormat(),
                $this->tools,
            );
        }
        if ($this->systemMessage !== null) {
            $params['systemMessage'] = $this->systemMessage->toArray();
        }
        if ($this->availableTools !== null) {
            $params['availableTools'] = $this->availableTools;
        }
        if ($this->excludedTools !== null) {
            $params['excludedTools'] = $this->excludedTools;
        }
        if ($this->provider !== null) {
            $params['provider'] = $this->provider->toArray();
        }
        $params['requestPermission'] = $this->onPermissionRequest !== null;
        $params['requestUserInput'] = $this->onUserInputRequest !== null;
        $params['hooks'] = $this->hooks !== null && $this->hooks->hasAnyHandler();
        if ($this->workingDirectory !== null) {
            $params['workingDirectory'] = $this->workingDirectory;
        }
        if ($this->streaming !== null) {
            $params['streaming'] = $this->streaming;
        }
        if ($this->mcpServers !== null) {
            $mcpArr = [];
            foreach ($this->mcpServers as $name => $config) {
                $mcpArr[$name] = $config->toArray();
            }
            $params['mcpServers'] = $mcpArr;
        }
        if ($this->customAgents !== null) {
            $params['customAgents'] = array_map(
                fn(CustomAgentConfig $a) => $a->toArray(),
                $this->customAgents,
            );
        }
        if ($this->skillDirectories !== null) {
            $params['skillDirectories'] = $this->skillDirectories;
        }
        if ($this->disabledSkills !== null) {
            $params['disabledSkills'] = $this->disabledSkills;
        }
        if ($this->infiniteSessions !== null) {
            $params['infiniteSessions'] = $this->infiniteSessions->toArray();
        }
        return $params;
    }
}

class ResumeSessionConfig
{
    /**
     * @param string|null $model Model to use
     * @param ReasoningEffort|null $reasoningEffort Reasoning effort level
     * @param Tool[]|null $tools Tools exposed to CLI server
     * @param SystemMessageAppendConfig|SystemMessageReplaceConfig|null $systemMessage
     * @param string[]|null $availableTools
     * @param string[]|null $excludedTools
     * @param ProviderConfig|null $provider
     * @param callable|null $onPermissionRequest
     * @param callable|null $onUserInputRequest
     * @param SessionHooks|null $hooks
     * @param string|null $workingDirectory
     * @param string|null $configDir
     * @param bool|null $streaming
     * @param array|null $mcpServers
     * @param CustomAgentConfig[]|null $customAgents
     * @param string[]|null $skillDirectories
     * @param string[]|null $disabledSkills
     * @param InfiniteSessionConfig|null $infiniteSessions
     * @param bool|null $disableResume
     */
    public function __construct(
        public readonly ?string $model = null,
        public readonly ?ReasoningEffort $reasoningEffort = null,
        public readonly ?array $tools = null,
        public readonly SystemMessageAppendConfig|SystemMessageReplaceConfig|null $systemMessage = null,
        public readonly ?array $availableTools = null,
        public readonly ?array $excludedTools = null,
        public readonly ?ProviderConfig $provider = null,
        public /* readonly */ $onPermissionRequest = null,
        public /* readonly */ $onUserInputRequest = null,
        public readonly ?SessionHooks $hooks = null,
        public readonly ?string $workingDirectory = null,
        public readonly ?string $configDir = null,
        public readonly ?bool $streaming = null,
        public readonly ?array $mcpServers = null,
        public readonly ?array $customAgents = null,
        public readonly ?array $skillDirectories = null,
        public readonly ?array $disabledSkills = null,
        public readonly ?InfiniteSessionConfig $infiniteSessions = null,
        public readonly ?bool $disableResume = null,
    ) {}

    public function toServerParams(string $sessionId): array
    {
        $params = ['sessionId' => $sessionId];
        if ($this->model !== null) {
            $params['model'] = $this->model;
        }
        if ($this->reasoningEffort !== null) {
            $params['reasoningEffort'] = $this->reasoningEffort->value;
        }
        if ($this->tools !== null) {
            $params['tools'] = array_map(
                fn(Tool $t) => $t->toServerFormat(),
                $this->tools,
            );
        }
        if ($this->systemMessage !== null) {
            $params['systemMessage'] = $this->systemMessage->toArray();
        }
        if ($this->availableTools !== null) {
            $params['availableTools'] = $this->availableTools;
        }
        if ($this->excludedTools !== null) {
            $params['excludedTools'] = $this->excludedTools;
        }
        if ($this->provider !== null) {
            $params['provider'] = $this->provider->toArray();
        }
        $params['requestPermission'] = $this->onPermissionRequest !== null;
        $params['requestUserInput'] = $this->onUserInputRequest !== null;
        $params['hooks'] = $this->hooks !== null && $this->hooks->hasAnyHandler();
        if ($this->workingDirectory !== null) {
            $params['workingDirectory'] = $this->workingDirectory;
        }
        if ($this->configDir !== null) {
            $params['configDir'] = $this->configDir;
        }
        if ($this->streaming !== null) {
            $params['streaming'] = $this->streaming;
        }
        if ($this->mcpServers !== null) {
            $mcpArr = [];
            foreach ($this->mcpServers as $name => $config) {
                $mcpArr[$name] = $config->toArray();
            }
            $params['mcpServers'] = $mcpArr;
        }
        if ($this->customAgents !== null) {
            $params['customAgents'] = array_map(
                fn(CustomAgentConfig $a) => $a->toArray(),
                $this->customAgents,
            );
        }
        if ($this->skillDirectories !== null) {
            $params['skillDirectories'] = $this->skillDirectories;
        }
        if ($this->disabledSkills !== null) {
            $params['disabledSkills'] = $this->disabledSkills;
        }
        if ($this->infiniteSessions !== null) {
            $params['infiniteSessions'] = $this->infiniteSessions->toArray();
        }
        if ($this->disableResume !== null) {
            $params['disableResume'] = $this->disableResume;
        }
        return $params;
    }
}

// ============================================================================
// Session Event (generic container)
// ============================================================================

class SessionEvent
{
    public function __construct(
        public readonly string $type,
        public readonly array $data = [],
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            type: $data['type'] ?? 'unknown',
            data: $data['data'] ?? $data,
        );
    }
}

// ============================================================================
// Response Format & Image Types
// ============================================================================

class ResponseFormat
{
    const TEXT = 'text';
    const IMAGE = 'image';
    const JSON_OBJECT = 'json_object';
}

class ImageOptions
{
    public function __construct(
        public readonly ?string $size = null,
        public readonly ?string $quality = null,
        public readonly ?string $style = null,
    ) {}

    public function toArray(): array
    {
        return array_filter([
            'size' => $this->size,
            'quality' => $this->quality,
            'style' => $this->style,
        ], fn($v) => $v !== null);
    }
}

class AssistantImageData
{
    public function __construct(
        public readonly string $format,
        public readonly string $base64,
        public readonly int $width,
        public readonly int $height,
        public readonly ?string $url = null,
        public readonly ?string $revisedPrompt = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            format: $data['format'] ?? '',
            base64: $data['base64'] ?? '',
            width: $data['width'] ?? 0,
            height: $data['height'] ?? 0,
            url: $data['url'] ?? null,
            revisedPrompt: $data['revisedPrompt'] ?? null,
        );
    }
}

class ContentBlock
{
    public function __construct(
        public readonly string $type,
        public readonly ?string $text = null,
        public readonly ?AssistantImageData $image = null,
    ) {}

    public static function fromArray(array $data): self
    {
        $image = isset($data['image']) ? AssistantImageData::fromArray($data['image']) : null;
        return new self(
            type: $data['type'] ?? '',
            text: $data['text'] ?? null,
            image: $image,
        );
    }
}

// ============================================================================
// Message Options
// ============================================================================

class FileAttachment
{
    public function __construct(
        public readonly string $path,
        public readonly ?string $displayName = null,
    ) {}

    public function toArray(): array
    {
        $result = ['type' => 'file', 'path' => $this->path];
        if ($this->displayName !== null) {
            $result['displayName'] = $this->displayName;
        }
        return $result;
    }
}

class DirectoryAttachment
{
    public function __construct(
        public readonly string $path,
        public readonly ?string $displayName = null,
    ) {}

    public function toArray(): array
    {
        $result = ['type' => 'directory', 'path' => $this->path];
        if ($this->displayName !== null) {
            $result['displayName'] = $this->displayName;
        }
        return $result;
    }
}

class SelectionRange
{
    public function __construct(
        public readonly int $line,
        public readonly int $character,
    ) {}

    public function toArray(): array
    {
        return ['line' => $this->line, 'character' => $this->character];
    }
}

class Selection
{
    public function __construct(
        public readonly SelectionRange $start,
        public readonly SelectionRange $end,
    ) {}

    public function toArray(): array
    {
        return ['start' => $this->start->toArray(), 'end' => $this->end->toArray()];
    }
}

class SelectionAttachment
{
    public function __construct(
        public readonly string $filePath,
        public readonly string $displayName,
        public readonly ?Selection $selection = null,
        public readonly ?string $text = null,
    ) {}

    public function toArray(): array
    {
        $result = [
            'type' => 'selection',
            'filePath' => $this->filePath,
            'displayName' => $this->displayName,
        ];
        if ($this->selection !== null) {
            $result['selection'] = $this->selection->toArray();
        }
        if ($this->text !== null) {
            $result['text'] = $this->text;
        }
        return $result;
    }
}

class MessageOptions
{
    /**
     * @param string $prompt The prompt/message to send
     * @param array<FileAttachment|DirectoryAttachment|SelectionAttachment>|null $attachments
     * @param string|null $mode "enqueue" (default) or "immediate"
     * @param string|null $responseFormat Response format (see ResponseFormat constants)
     * @param ImageOptions|null $imageOptions Image generation options
     */
    public function __construct(
        public readonly string $prompt,
        public readonly ?array $attachments = null,
        public readonly ?string $mode = null,
        public readonly ?string $responseFormat = null,
        public readonly ?ImageOptions $imageOptions = null,
    ) {}

    public function toArray(): array
    {
        $result = ['prompt' => $this->prompt];
        if ($this->attachments !== null) {
            $result['attachments'] = array_map(
                fn($a) => $a->toArray(),
                $this->attachments,
            );
        }
        if ($this->mode !== null) {
            $result['mode'] = $this->mode;
        }
        if ($this->responseFormat !== null) {
            $result['responseFormat'] = $this->responseFormat;
        }
        if ($this->imageOptions !== null) {
            $result['imageOptions'] = $this->imageOptions->toArray();
        }
        return $result;
    }
}

// ============================================================================
// Hook Types
// ============================================================================

class PreToolUseHookInput
{
    public function __construct(
        public readonly int $timestamp,
        public readonly string $cwd,
        public readonly string $toolName,
        public readonly mixed $toolArgs,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            timestamp: $data['timestamp'] ?? 0,
            cwd: $data['cwd'] ?? '',
            toolName: $data['toolName'] ?? '',
            toolArgs: $data['toolArgs'] ?? null,
        );
    }
}

class PreToolUseHookOutput
{
    public function __construct(
        public readonly ?string $permissionDecision = null,
        public readonly ?string $permissionDecisionReason = null,
        public readonly mixed $modifiedArgs = null,
        public readonly ?string $additionalContext = null,
        public readonly ?bool $suppressOutput = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->permissionDecision !== null) {
            $result['permissionDecision'] = $this->permissionDecision;
        }
        if ($this->permissionDecisionReason !== null) {
            $result['permissionDecisionReason'] = $this->permissionDecisionReason;
        }
        if ($this->modifiedArgs !== null) {
            $result['modifiedArgs'] = $this->modifiedArgs;
        }
        if ($this->additionalContext !== null) {
            $result['additionalContext'] = $this->additionalContext;
        }
        if ($this->suppressOutput !== null) {
            $result['suppressOutput'] = $this->suppressOutput;
        }
        return $result;
    }
}

class PostToolUseHookInput
{
    public function __construct(
        public readonly int $timestamp,
        public readonly string $cwd,
        public readonly string $toolName,
        public readonly mixed $toolArgs,
        public readonly mixed $toolResult,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            timestamp: $data['timestamp'] ?? 0,
            cwd: $data['cwd'] ?? '',
            toolName: $data['toolName'] ?? '',
            toolArgs: $data['toolArgs'] ?? null,
            toolResult: $data['toolResult'] ?? null,
        );
    }
}

class PostToolUseHookOutput
{
    public function __construct(
        public readonly mixed $modifiedResult = null,
        public readonly ?string $additionalContext = null,
        public readonly ?bool $suppressOutput = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->modifiedResult !== null) {
            $result['modifiedResult'] = $this->modifiedResult;
        }
        if ($this->additionalContext !== null) {
            $result['additionalContext'] = $this->additionalContext;
        }
        if ($this->suppressOutput !== null) {
            $result['suppressOutput'] = $this->suppressOutput;
        }
        return $result;
    }
}

class UserPromptSubmittedHookInput
{
    public function __construct(
        public readonly int $timestamp,
        public readonly string $cwd,
        public readonly string $prompt,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            timestamp: $data['timestamp'] ?? 0,
            cwd: $data['cwd'] ?? '',
            prompt: $data['prompt'] ?? '',
        );
    }
}

class UserPromptSubmittedHookOutput
{
    public function __construct(
        public readonly ?string $modifiedPrompt = null,
        public readonly ?string $additionalContext = null,
        public readonly ?bool $suppressOutput = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->modifiedPrompt !== null) {
            $result['modifiedPrompt'] = $this->modifiedPrompt;
        }
        if ($this->additionalContext !== null) {
            $result['additionalContext'] = $this->additionalContext;
        }
        if ($this->suppressOutput !== null) {
            $result['suppressOutput'] = $this->suppressOutput;
        }
        return $result;
    }
}

class SessionStartHookInput
{
    public function __construct(
        public readonly int $timestamp,
        public readonly string $cwd,
        public readonly string $source,
        public readonly ?string $initialPrompt = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            timestamp: $data['timestamp'] ?? 0,
            cwd: $data['cwd'] ?? '',
            source: $data['source'] ?? 'new',
            initialPrompt: $data['initialPrompt'] ?? null,
        );
    }
}

class SessionStartHookOutput
{
    public function __construct(
        public readonly ?string $additionalContext = null,
        public readonly ?array $modifiedConfig = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->additionalContext !== null) {
            $result['additionalContext'] = $this->additionalContext;
        }
        if ($this->modifiedConfig !== null) {
            $result['modifiedConfig'] = $this->modifiedConfig;
        }
        return $result;
    }
}

class SessionEndHookInput
{
    public function __construct(
        public readonly int $timestamp,
        public readonly string $cwd,
        public readonly string $reason,
        public readonly ?string $finalMessage = null,
        public readonly ?string $error = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            timestamp: $data['timestamp'] ?? 0,
            cwd: $data['cwd'] ?? '',
            reason: $data['reason'] ?? 'complete',
            finalMessage: $data['finalMessage'] ?? null,
            error: $data['error'] ?? null,
        );
    }
}

class SessionEndHookOutput
{
    public function __construct(
        public readonly ?bool $suppressOutput = null,
        /** @var string[]|null */
        public readonly ?array $cleanupActions = null,
        public readonly ?string $sessionSummary = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->suppressOutput !== null) {
            $result['suppressOutput'] = $this->suppressOutput;
        }
        if ($this->cleanupActions !== null) {
            $result['cleanupActions'] = $this->cleanupActions;
        }
        if ($this->sessionSummary !== null) {
            $result['sessionSummary'] = $this->sessionSummary;
        }
        return $result;
    }
}

class ErrorOccurredHookInput
{
    public function __construct(
        public readonly int $timestamp,
        public readonly string $cwd,
        public readonly string $error,
        public readonly string $errorContext,
        public readonly bool $recoverable,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            timestamp: $data['timestamp'] ?? 0,
            cwd: $data['cwd'] ?? '',
            error: $data['error'] ?? '',
            errorContext: $data['errorContext'] ?? 'system',
            recoverable: $data['recoverable'] ?? false,
        );
    }
}

class ErrorOccurredHookOutput
{
    public function __construct(
        public readonly ?bool $suppressOutput = null,
        public readonly ?string $errorHandling = null,
        public readonly ?int $retryCount = null,
        public readonly ?string $userNotification = null,
    ) {}

    public function toArray(): array
    {
        $result = [];
        if ($this->suppressOutput !== null) {
            $result['suppressOutput'] = $this->suppressOutput;
        }
        if ($this->errorHandling !== null) {
            $result['errorHandling'] = $this->errorHandling;
        }
        if ($this->retryCount !== null) {
            $result['retryCount'] = $this->retryCount;
        }
        if ($this->userNotification !== null) {
            $result['userNotification'] = $this->userNotification;
        }
        return $result;
    }
}

class SessionHooks
{
    /**
     * @param callable|null $onPreToolUse fn(PreToolUseHookInput, array{sessionId:string}): ?PreToolUseHookOutput
     * @param callable|null $onPostToolUse fn(PostToolUseHookInput, array{sessionId:string}): ?PostToolUseHookOutput
     * @param callable|null $onUserPromptSubmitted fn(UserPromptSubmittedHookInput, array{sessionId:string}): ?UserPromptSubmittedHookOutput
     * @param callable|null $onSessionStart fn(SessionStartHookInput, array{sessionId:string}): ?SessionStartHookOutput
     * @param callable|null $onSessionEnd fn(SessionEndHookInput, array{sessionId:string}): ?SessionEndHookOutput
     * @param callable|null $onErrorOccurred fn(ErrorOccurredHookInput, array{sessionId:string}): ?ErrorOccurredHookOutput
     */
    public function __construct(
        public /* readonly */ $onPreToolUse = null,
        public /* readonly */ $onPostToolUse = null,
        public /* readonly */ $onUserPromptSubmitted = null,
        public /* readonly */ $onSessionStart = null,
        public /* readonly */ $onSessionEnd = null,
        public /* readonly */ $onErrorOccurred = null,
    ) {}

    public function hasAnyHandler(): bool
    {
        return $this->onPreToolUse !== null
            || $this->onPostToolUse !== null
            || $this->onUserPromptSubmitted !== null
            || $this->onSessionStart !== null
            || $this->onSessionEnd !== null
            || $this->onErrorOccurred !== null;
    }
}

// ============================================================================
// Ping Response
// ============================================================================

class PingResponse
{
    public function __construct(
        public readonly string $message,
        public readonly int $timestamp,
        public readonly ?int $protocolVersion = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            message: $data['message'] ?? '',
            timestamp: $data['timestamp'] ?? 0,
            protocolVersion: $data['protocolVersion'] ?? null,
        );
    }
}

// ============================================================================
// Status Responses
// ============================================================================

class GetStatusResponse
{
    public function __construct(
        public readonly string $version,
        public readonly int $protocolVersion,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            version: $data['version'] ?? '',
            protocolVersion: $data['protocolVersion'] ?? 0,
        );
    }
}

class GetAuthStatusResponse
{
    public function __construct(
        public readonly bool $isAuthenticated,
        public readonly ?string $authType = null,
        public readonly ?string $host = null,
        public readonly ?string $login = null,
        public readonly ?string $statusMessage = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            isAuthenticated: (bool) ($data['isAuthenticated'] ?? false),
            authType: $data['authType'] ?? null,
            host: $data['host'] ?? null,
            login: $data['login'] ?? null,
            statusMessage: $data['statusMessage'] ?? null,
        );
    }
}

// ============================================================================
// Model Types
// ============================================================================

class ModelVisionLimits
{
    public function __construct(
        /** @var string[]|null */
        public readonly ?array $supportedMediaTypes = null,
        public readonly ?int $maxPromptImages = null,
        public readonly ?int $maxPromptImageSize = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            supportedMediaTypes: $data['supported_media_types'] ?? null,
            maxPromptImages: $data['max_prompt_images'] ?? null,
            maxPromptImageSize: $data['max_prompt_image_size'] ?? null,
        );
    }
}

class ModelLimits
{
    public function __construct(
        public readonly ?int $maxPromptTokens = null,
        public readonly ?int $maxContextWindowTokens = null,
        public readonly ?ModelVisionLimits $vision = null,
    ) {}

    public static function fromArray(array $data): self
    {
        $vision = isset($data['vision']) ? ModelVisionLimits::fromArray($data['vision']) : null;
        return new self(
            maxPromptTokens: $data['max_prompt_tokens'] ?? null,
            maxContextWindowTokens: $data['max_context_window_tokens'] ?? null,
            vision: $vision,
        );
    }
}

class ModelSupports
{
    public function __construct(
        public readonly bool $vision,
        public readonly bool $reasoningEffort = false,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            vision: (bool) ($data['vision'] ?? false),
            reasoningEffort: (bool) ($data['reasoningEffort'] ?? false),
        );
    }
}

class ModelCapabilities
{
    public function __construct(
        public readonly ModelSupports $supports,
        public readonly ModelLimits $limits,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            supports: ModelSupports::fromArray($data['supports'] ?? []),
            limits: ModelLimits::fromArray($data['limits'] ?? []),
        );
    }
}

class ModelPolicy
{
    public function __construct(
        public readonly string $state,
        public readonly string $terms,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            state: $data['state'] ?? 'unconfigured',
            terms: $data['terms'] ?? '',
        );
    }
}

class ModelBilling
{
    public function __construct(
        public readonly float $multiplier,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            multiplier: (float) ($data['multiplier'] ?? 1.0),
        );
    }
}

class ModelInfo
{
    public function __construct(
        public readonly string $id,
        public readonly string $name,
        public readonly ModelCapabilities $capabilities,
        public readonly ?ModelPolicy $policy = null,
        public readonly ?ModelBilling $billing = null,
        /** @var string[]|null */
        public readonly ?array $supportedReasoningEfforts = null,
        public readonly ?string $defaultReasoningEffort = null,
    ) {}

    public static function fromArray(array $data): self
    {
        $policy = isset($data['policy']) ? ModelPolicy::fromArray($data['policy']) : null;
        $billing = isset($data['billing']) ? ModelBilling::fromArray($data['billing']) : null;
        return new self(
            id: $data['id'] ?? '',
            name: $data['name'] ?? '',
            capabilities: ModelCapabilities::fromArray($data['capabilities'] ?? []),
            policy: $policy,
            billing: $billing,
            supportedReasoningEfforts: $data['supportedReasoningEfforts'] ?? null,
            defaultReasoningEffort: $data['defaultReasoningEffort'] ?? null,
        );
    }
}

// ============================================================================
// Session Metadata
// ============================================================================

class SessionMetadata
{
    public function __construct(
        public readonly string $sessionId,
        public readonly string $startTime,
        public readonly string $modifiedTime,
        public readonly bool $isRemote,
        public readonly ?string $summary = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            sessionId: $data['sessionId'] ?? '',
            startTime: $data['startTime'] ?? '',
            modifiedTime: $data['modifiedTime'] ?? '',
            isRemote: (bool) ($data['isRemote'] ?? false),
            summary: $data['summary'] ?? null,
        );
    }
}

// ============================================================================
// Session Lifecycle Event
// ============================================================================

class SessionLifecycleEventMetadata
{
    public function __construct(
        public readonly string $startTime,
        public readonly string $modifiedTime,
        public readonly ?string $summary = null,
    ) {}

    public static function fromArray(array $data): self
    {
        return new self(
            startTime: $data['startTime'] ?? '',
            modifiedTime: $data['modifiedTime'] ?? '',
            summary: $data['summary'] ?? null,
        );
    }
}

class SessionLifecycleEvent
{
    public function __construct(
        public readonly string $type,
        public readonly string $sessionId,
        public readonly ?SessionLifecycleEventMetadata $metadata = null,
    ) {}

    public static function fromArray(array $data): self
    {
        $metadata = isset($data['metadata']) && $data['metadata']
            ? SessionLifecycleEventMetadata::fromArray($data['metadata'])
            : null;
        return new self(
            type: $data['type'] ?? 'session.updated',
            sessionId: $data['sessionId'] ?? '',
            metadata: $metadata,
        );
    }
}

// ============================================================================
// Client Options
// ============================================================================

class CopilotClientOptions
{
    /**
     * @param string|null $cliPath Path to CLI executable
     * @param string[]|null $cliArgs Extra CLI arguments
     * @param string|null $cwd Working directory
     * @param int|null $port Port for TCP mode
     * @param bool $useStdio Use stdio transport (default: true)
     * @param string|null $cliUrl URL of existing server (mutually exclusive with cliPath/useStdio)
     * @param LogLevel $logLevel Log level
     * @param bool $autoStart Auto-start on first use
     * @param bool $autoRestart Auto-restart on crash
     * @param array<string,string>|null $env Environment variables
     * @param string|null $githubToken GitHub token for auth
     * @param bool|null $useLoggedInUser Use logged-in user auth
     */
    public function __construct(
        public readonly ?string $cliPath = null,
        public readonly ?array $cliArgs = null,
        public readonly ?string $cwd = null,
        public readonly ?int $port = null,
        public readonly bool $useStdio = true,
        public readonly ?string $cliUrl = null,
        public readonly LogLevel $logLevel = LogLevel::Info,
        public readonly bool $autoStart = true,
        public readonly bool $autoRestart = true,
        public readonly ?array $env = null,
        public readonly ?string $githubToken = null,
        public readonly ?bool $useLoggedInUser = null,
    ) {}
}
