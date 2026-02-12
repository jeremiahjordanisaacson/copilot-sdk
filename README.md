# GitHub Copilot SDK - Supercharged

![GitHub Copilot SDK SUPERCHARGED](./assets/SUPERCHARGED!!!.gif)

[![npm](https://img.shields.io/npm/v/copilot-sdk-supercharged?logo=npm&label=npm&color=CB3837)](https://www.npmjs.com/package/copilot-sdk-supercharged)
[![PyPI](https://img.shields.io/pypi/v/copilot-sdk-supercharged?logo=python&label=PyPI&color=3775A9)](https://pypi.org/project/copilot-sdk-supercharged/)
[![crates.io](https://img.shields.io/crates/v/copilot-sdk-supercharged?logo=rust&label=crates.io&color=dea584)](https://crates.io/crates/copilot-sdk-supercharged)
[![Gem](https://img.shields.io/gem/v/copilot-sdk-supercharged?logo=rubygems&label=RubyGems&color=E9573F)](https://rubygems.org/gems/copilot-sdk-supercharged)
[![Hex](https://img.shields.io/hexpm/v/copilot_sdk_supercharged?logo=elixir&label=Hex&color=6e4a7e)](https://hex.pm/packages/copilot_sdk_supercharged)
[![LuaRocks](https://img.shields.io/badge/LuaRocks-1.0.6-2C2D72?logo=lua)](https://luarocks.org/modules/jeremiahjordanisaacson/copilot-sdk-supercharged)
[![GitHub Stars](https://img.shields.io/github/stars/jeremiahjordanisaacson/copilot-sdk-supercharged?style=flat&logo=github&color=238636)](https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged)
[![Languages](https://img.shields.io/badge/languages-21-58a6ff?style=flat)](https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged#available-sdks)

**21 languages. One SDK.** Agents for every app.

Embed Copilot's agentic workflows in your application. A production-tested agent runtime you can invoke programmatically in any major language. You define agent behavior, Copilot handles planning, tool invocation, file edits, and more.

## Available SDKs

| SDK | Location | Installation | Build System |
|-----|----------|-------------|--------------|
| **Node.js / TypeScript** | [`nodejs/`](./nodejs/README.md) | `npm install copilot-sdk-supercharged` | npm |
| **Python** | [`python/`](./python/README.md) | `pip install copilot-sdk-supercharged` | pip |
| **Go** | [`go/`](./go/README.md) | `go get github.com/github/copilot-sdk/go` | Go modules |
| **.NET / C#** | [`dotnet/`](./dotnet/README.md) | `dotnet add package GitHub.Copilot.SDK` | NuGet |
| **Java** | [`java/`](./java/README.md) | Maven / Gradle | Maven |
| **Rust** | [`rust/`](./rust/README.md) | `cargo add copilot-sdk-supercharged` | Cargo |
| **Ruby** | [`ruby/`](./ruby/README.md) | `gem install copilot-sdk-supercharged` | RubyGems |
| **PHP** | [`php/`](./php/README.md) | Composer | Composer |
| **Swift** | [`swift/`](./swift/README.md) | Swift Package Manager | SPM |
| **Kotlin** | [`kotlin/`](./kotlin/README.md) | Gradle | Gradle |
| **C++** | [`cpp/`](./cpp/README.md) | CMake | CMake |
| **C** | [`c/`](./c/README.md) | CMake | CMake |
| **Dart** | [`dart/`](./dart/README.md) | pub | pub |
| **Scala** | [`scala/`](./scala/README.md) | sbt | sbt |
| **R** | [`r/`](./r/README.md) | CRAN | CRAN |
| **Perl** | [`perl/`](./perl/README.md) | CPAN | CPAN |
| **Lua** | [`lua/`](./lua/README.md) | `luarocks install copilot-sdk-supercharged` | LuaRocks |
| **Shell / Bash** | [`shell/`](./shell/README.md) | Source | N/A |
| **Elixir** | [`elixir/`](./elixir/README.md) | `{:copilot_sdk_supercharged, "~> 1.0"}` | Hex |
| **Haskell** | [`haskell/`](./haskell/README.md) | Cabal | Cabal |
| **Clojure** | [`clojure/`](./clojure/README.md) | deps.edn | deps.edn |

See the individual SDK READMEs for usage examples and API reference. For architecture details, see [`MULTI_LANGUAGE_SDKS.md`](./MULTI_LANGUAGE_SDKS.md).

## Getting Started

For a complete walkthrough, see the **[Getting Started Guide](./docs/getting-started.md)**.

Quick steps:

1. **Install the Copilot CLI:**

   Follow the [Copilot CLI installation guide](https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli) to install the CLI, or ensure `copilot` is available in your PATH.

2. **Install your preferred SDK** using the commands above.

3. **See the SDK README** for usage examples and API documentation.

## Architecture

All SDKs communicate with the Copilot CLI server via JSON-RPC:

```
Your Application
       ↓
  SDK Client
       ↓ JSON-RPC
  Copilot CLI (server mode)
```

The SDK manages the CLI process lifecycle automatically. You can also connect to an external CLI server. See the [Getting Started Guide](./docs/getting-started.md#connecting-to-an-external-cli-server) for details on running the CLI in server mode.

## FAQ

### Do I need a GitHub Copilot subscription to use the SDK?

Yes, a GitHub Copilot subscription is required to use the GitHub Copilot SDK, **unless you are using BYOK (Bring Your Own Key)**. With BYOK, you can use the SDK without GitHub authentication by configuring your own API keys from supported LLM providers. For standard usage (non-BYOK), refer to the [GitHub Copilot pricing page](https://github.com/features/copilot#pricing), which includes a free tier with limited usage.

### How does billing work for SDK usage?

Billing for the GitHub Copilot SDK is based on the same model as the Copilot CLI, with each prompt being counted towards your premium request quota. For more information on premium requests, see [Requests in GitHub Copilot](https://docs.github.com/en/copilot/concepts/billing/copilot-requests).

### Does it support BYOK (Bring Your Own Key)?

Yes, the GitHub Copilot SDK supports BYOK (Bring Your Own Key). You can configure the SDK to use your own API keys from supported LLM providers (e.g. OpenAI, Azure AI Foundry, Anthropic) to access models through those providers. See the **[BYOK documentation](./docs/auth/byok.md)** for setup instructions and examples.

**Note:** BYOK uses key-based authentication only. Microsoft Entra ID (Azure AD), managed identities, and third-party identity providers are not supported.

### What authentication methods are supported?

The SDK supports multiple authentication methods:
- **GitHub signed-in user** - Uses stored OAuth credentials from `copilot` CLI login
- **OAuth GitHub App** - Pass user tokens from your GitHub OAuth app
- **Environment variables** - `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`
- **BYOK** - Use your own API keys (no GitHub auth required)

See the **[Authentication documentation](./docs/auth/index.md)** for details on each method.

### Do I need to install the Copilot CLI separately?

Yes, the Copilot CLI must be installed separately. The SDKs communicate with the Copilot CLI in server mode to provide agent capabilities.

### What tools are enabled by default?

By default, the SDK will operate the Copilot CLI in the equivalent of `--allow-all` being passed to the CLI, enabling all first-party tools, which means that the agents can perform a wide range of actions, including file system operations, Git operations, and web requests. You can customize tool availability by configuring the SDK client options to enable and disable specific tools. Refer to the individual SDK documentation for details on tool configuration and Copilot CLI for the list of tools available.

### Can I use custom agents, skills or tools?

Yes, the GitHub Copilot SDK allows you to define custom agents, skills, and tools. You can extend the functionality of the agents by implementing your own logic and integrating additional tools as needed. Refer to the SDK documentation of your preferred language for more details.

### Are there instructions for Copilot to speed up development with the SDK?

Yes, check out the custom instructions at [`github/awesome-copilot`](https://github.com/github/awesome-copilot/blob/main/collections/copilot-sdk.md).

### What models are supported?

All models available via Copilot CLI are supported in the SDK. The SDK also exposes a method which will return the models available so they can be accessed at runtime.

### Is the SDK production-ready?

The GitHub Copilot SDK is currently in Technical Preview. While it is functional and can be used for development and testing, it may not yet be suitable for production use.

### How do I report issues or request features?

Please use the [GitHub Issues](https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged/issues) page to report bugs or request new features. We welcome your feedback to help improve the SDK.

## Quick Links

- **[Getting Started](./docs/getting-started.md)** - Tutorial to get up and running
- **[Authentication](./docs/auth/index.md)** - GitHub OAuth, BYOK, and more
- **[Architecture](./MULTI_LANGUAGE_SDKS.md)** - How all 21 SDKs work under the hood
- **[Contributing](./CONTRIBUTING.md)** - How to contribute (new languages welcome!)
- **[Website](https://jeremiahjordanisaacson.github.io/copilot-sdk-supercharged/)** - Landing page with examples in every language


## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution guidelines.

## License

MIT
