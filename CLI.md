# zig-ai - Universal AI Command Line Tool

A production-ready CLI tool for interacting with multiple AI providers from the terminal. Built with Zig 0.16.0 using our high-performance HTTP client with automatic gzip decompression.

## Supported Providers

- **Claude** (Anthropic) - Industry-leading reasoning and coding
- **DeepSeek** - Ultra-affordable (95% cheaper than Claude!)
- **Gemini** (Google) - Fast and capable
- **Grok** (X.AI) - Specialized for code
- **Vertex AI** (Google Cloud) - Enterprise-grade with OAuth2

## Features

✨ **Multiple Modes**
- One-shot queries for quick questions
- Interactive mode for conversations
- Batch processing for CSV files (coming soon)

📊 **Rich Output**
- Token usage tracking
- Cost estimation per query
- Formatted, readable responses

⚙️ **Highly Configurable**
- Adjustable temperature
- Max tokens control
- Custom system prompts
- Provider switching on-the-fly

🚀 **Production Ready**
- Automatic gzip decompression
- Proper error handling
- Thread-safe HTTP client
- Memory-efficient

## Installation

### Build from Source

```bash
cd zig-http-concurrent
zig build install --prefix ~/.local
```

This installs `zig-ai` to `~/.local/bin/zig-ai`. Make sure `~/.local/bin` is in your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### System-Wide Installation (requires sudo)

```bash
zig build install --prefix /usr/local
```

This installs to `/usr/local/bin/zig-ai`, making it available system-wide.

## Configuration

### API Keys

Configure API keys using environment variables:

```bash
# Claude (Anthropic)
export ANTHROPIC_API_KEY="sk-ant-..."

# DeepSeek (most affordable!)
export DEEPSEEK_API_KEY="sk-..."

# Gemini (Google)
export GEMINI_API_KEY="..."

# Grok (X.AI)
export GROK_API_KEY="xai-..."

# Vertex AI (Google Cloud) - requires gcloud auth
export VERTEX_PROJECT_ID="your-project-id"
gcloud auth login
gcloud auth application-default login
```

**Tip**: Add these to your `~/.bashrc` or `~/.zshrc` for persistence:

```bash
# Add to ~/.bashrc
export DEEPSEEK_API_KEY="your-key-here"
```

### Security Best Practices

**Never commit API keys to git!** Use one of these secure methods:

1. **Environment Variables** (recommended for development)
   ```bash
   export DEEPSEEK_API_KEY="your-key"
   ```

2. **Separate Config File** (recommended for production)
   ```bash
   # Create ~/.config/zig-ai/config
   mkdir -p ~/.config/zig-ai
   echo 'export DEEPSEEK_API_KEY="your-key"' > ~/.config/zig-ai/config
   chmod 600 ~/.config/zig-ai/config

   # Source it in your shell
   source ~/.config/zig-ai/config
   ```

3. **Pass-through from Secret Manager**
   ```bash
   export DEEPSEEK_API_KEY=$(pass show api/deepseek)
   ```

## Usage

### Basic Syntax

```bash
zig-ai [provider] [options] "prompt"
zig-ai --interactive [provider]
zig-ai --list
zig-ai --help
```

### Quick Start Examples

**Simple query:**
```bash
zig-ai deepseek "What is Zig?"
```

**With temperature control:**
```bash
zig-ai claude --temperature 0.5 "Explain async/await"
```

**Interactive mode:**
```bash
zig-ai --interactive gemini
```

**Custom system prompt:**
```bash
zig-ai grok --system "You are a Zig expert" "Best practices for error handling?"
```

**List all providers:**
```bash
zig-ai --list
```

### Command-Line Options

| Option | Short | Description | Example |
|--------|-------|-------------|---------|
| `--help` | `-h` | Show help message | `zig-ai --help` |
| `--list` | `-l` | List available providers | `zig-ai --list` |
| `--interactive` | `-i` | Start interactive mode | `zig-ai -i deepseek` |
| `--temperature` | `-t` | Set temperature (0.0-2.0) | `zig-ai -t 0.7 claude "..."` |
| `--max-tokens` | `-m` | Set max output tokens | `zig-ai -m 4096 deepseek "..."` |
| `--system` | `-s` | Set system prompt | `zig-ai -s "You are helpful" grok "..."` |
| `--no-usage` | | Hide token usage stats | `zig-ai --no-usage deepseek "..."` |
| `--no-cost` | | Hide cost estimates | `zig-ai --no-cost claude "..."` |

### Interactive Mode

Interactive mode provides a conversation experience with persistent context:

```bash
$ zig-ai --interactive deepseek

╔══════════════════════════════════════════════════════════╗
║  AI Providers CLI - Interactive Mode                    ║
║  Provider: DeepSeek (Ultra-Affordable)                  ║
╚══════════════════════════════════════════════════════════╝

Commands:
  /help     - Show this help
  /clear    - Clear conversation history
  /switch   - Switch provider
  /quit     - Exit

👤 You: What is Zig?

🤖 DeepSeek:
Zig is a general-purpose programming language designed for
robustness, optimality, and clarity...

📊 Tokens: 11 in, 29 out
💰 Estimated cost: $0.000010

👤 You: What makes it different from Rust?

🤖 DeepSeek:
[Response with full conversation context...]

👤 You: /quit

👋 Goodbye!
```

### Practical Use Cases

#### 1. Quick Documentation Lookup
```bash
zig-ai deepseek "How do I use ArrayList in Zig?"
```

#### 2. Code Review
```bash
zig-ai claude --system "You are a code reviewer" "$(cat mycode.zig)"
```

#### 3. Shell Scripting Integration
```bash
#!/bin/bash
# Generate commit messages
DIFF=$(git diff --staged)
MSG=$(zig-ai deepseek "Generate a commit message for: $DIFF")
echo "$MSG"
```

#### 4. Piping from stdin
```bash
cat error.log | zig-ai grok "Analyze these errors and suggest fixes"
```

#### 5. Cost Comparison
```bash
# Test same prompt on different providers
zig-ai deepseek "Explain monads" > deepseek_response.txt
zig-ai claude "Explain monads" > claude_response.txt
```

#### 6. Batch Processing (via script)
```bash
#!/bin/bash
while IFS=',' read -r provider prompt; do
    echo "Testing $provider..."
    zig-ai "$provider" "$prompt" >> results.txt
done < prompts.csv
```

## Output Format

### Standard Output

```
🤖 DeepSeek (Ultra-Affordable)
💬 Query: What is Zig?

✨ Response:
[AI response here...]

📊 Tokens: 11 in, 29 out
💰 Estimated cost: $0.000010
```

### Quiet Mode (for scripting)

Use `--no-usage` and `--no-cost` to get just the response:

```bash
zig-ai --no-usage --no-cost deepseek "What is Zig?" 2>/dev/null
```

## Provider Comparison

| Provider | Speed | Quality | Cost/1K Tokens | Best For |
|----------|-------|---------|----------------|----------|
| DeepSeek | ⚡⚡⚡ | ⭐⭐⭐⭐ | $0.00014 (in) / $0.00028 (out) | **Most use cases** |
| Claude | ⚡⚡ | ⭐⭐⭐⭐⭐ | $3.00 (in) / $15.00 (out) | Complex reasoning |
| Gemini | ⚡⚡⚡ | ⭐⭐⭐⭐ | $0.075 (in) / $0.30 (out) | Fast responses |
| Grok | ⚡⚡ | ⭐⭐⭐⭐ | $2.00 (in) / $10.00 (out) | Code-focused |
| Vertex | ⚡⚡ | ⭐⭐⭐⭐ | $1.25 (in) / $5.00 (out) | Enterprise |

**Recommendation**: Start with **DeepSeek** for cost-effectiveness, use **Claude** for complex tasks.

## Troubleshooting

### "API key not set" error

```bash
❌ Error: DEEPSEEK_API_KEY environment variable not set

   Set it with:
   export DEEPSEEK_API_KEY=your_api_key_here
```

**Solution**: Set the required environment variable for your chosen provider.

### gcloud authentication error (Vertex AI)

```bash
❌ Error: gcloud authentication failed
```

**Solution**: Run:
```bash
gcloud auth login
gcloud auth application-default login
```

### Connection timeout

**Solution**: Check your internet connection and API status:
```bash
curl -I https://api.deepseek.com
```

### Rate limiting

```bash
❌ Error: RateLimitExceeded
```

**Solution**: Wait a moment and retry. Consider:
- Reducing request frequency
- Upgrading your API plan
- Switching to a different provider temporarily

## Advanced Usage

### Custom Temperature Strategies

```bash
# Creative writing (high temperature)
zig-ai --temperature 1.5 claude "Write a sci-fi story"

# Factual answers (low temperature)
zig-ai --temperature 0.3 deepseek "Explain quantum computing"

# Balanced (default)
zig-ai --temperature 1.0 gemini "Compare React vs Vue"
```

### Automation Scripts

**Generate documentation:**
```bash
#!/bin/bash
for file in src/*.zig; do
    echo "Processing $file..."
    zig-ai deepseek "Generate documentation for: $(cat $file)" > "docs/$(basename $file .zig).md"
done
```

**Code translation:**
```bash
#!/bin/bash
CODE=$(cat input.py)
zig-ai claude --system "You are a code translator" "Convert this Python to Zig: $CODE" > output.zig
```

## Benchmarking

Use the CLI as a benchmarking engine:

```bash
#!/bin/bash
PROMPT="Explain async/await in Zig"

echo "=== Provider Benchmark ==="
for provider in deepseek claude gemini grok; do
    echo "Testing $provider..."
    time zig-ai "$provider" "$PROMPT" > /dev/null
done
```

## Development

### Building from Source

```bash
git clone <repo>
cd zig-http-concurrent
zig build cli -- --help
```

### Running Tests

```bash
# Smoke tests
zig build cli -- --list
zig build cli -- --help

# Integration test
zig build cli -- deepseek "test query"
```

### Project Structure

```
src/
├── main.zig          # Entry point, argument parsing
├── cli.zig           # CLI logic, interactive mode
├── ai/               # AI provider implementations
│   ├── common.zig    # Shared types and utilities
│   ├── claude.zig    # Claude client
│   ├── deepseek.zig  # DeepSeek client
│   ├── gemini.zig    # Gemini client
│   ├── grok.zig      # Grok client
│   └── vertex.zig    # Vertex AI client
└── http_client.zig   # HTTP client with gzip
```

## Roadmap

### V1.0 (Current)
- ✅ Multi-provider support
- ✅ Interactive mode
- ✅ Token usage tracking
- ✅ Cost estimation
- ✅ System installation

### V1.1 (Next)
- ⏳ CSV batch processing
- ⏳ Parallel requests (100+ at once)
- ⏳ JSON output mode
- ⏳ Stdin piping support
- ⏳ Streaming responses

### V2.0 (Future)
- 📋 Configuration file support
- 📋 Response caching
- 📋 Conversation history save/load
- 📋 Markdown output formatting
- 📋 Plugin system for custom providers

## Contributing

This is part of the HTTP Sentinel project. See main README for contribution guidelines.

## License

MIT License - See LICENSE file

## Credits

Built with:
- Zig 0.16.0-dev
- HTTP Sentinel library
- High-performance concurrent HTTP client

---

**Quick Links:**
- [Main Project README](./README.md)
- [AI Providers Documentation](./AI_CLIENTS.md)
- [HTTP Client Documentation](./HTTP_CLIENT.md)
- [Issue Tracker](https://github.com/...)

**Support:**
- For bugs: Open an issue
- For questions: Check documentation
- For features: Open a feature request

**Remember**: DeepSeek is 95% cheaper than Claude! Start there for most tasks. 💰
