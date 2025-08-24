# CC Streamer

CC Streamer is a CLI app that accepts streamed JSON output from Claude Code and formats it for your terminal so it's nice and easy to read.

## Using CC Streamer

```bash
PROMPT="Build me a hello world app in C"

claude --verbose -p --output-format stream-json --dangerously-skip-permissions "$PROMPT" | ccstreamer
```
