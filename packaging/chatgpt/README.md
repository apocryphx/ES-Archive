# ES Archive for ChatGPT and Codex

This local macOS plugin packages the ES Archive MCP connection and all seven
canonical skills from `skills/codex`. Claude's skills are not included.

The ES Archive MCP app must already be installed. The plugin uses its existing
STDIO server; it does not bundle the native app or make the archive accessible
to hosted web chats. Archive contents returned by tools are shared with the AI
client handling your conversation.

## Build

From the ES Archive repository:

```sh
python3 scripts/package-chatgpt-plugin.py --output /tmp/es-archive-plugin
```

Use `--app '/path/to/ES Archive MCP.app'` for another installation location.
Use `--author Codex` to select a different archive persona; the default is
`ChatGPT`, matching the onboarding instructions. Both clients using the same
plugin connection use that author. Packaging preserves the skill suite's Codex
names and text; skills instruct the assistant to check the actual author scope.

The output contains an `es-archive` plugin directory and `es-archive.zip`.
The ZIP is a transport artifact, not a verified double-click installer.
Regenerate and reinstall the plugin if the native app moves. Build into a new
output directory each time; existing output is never overwritten.

## Install and verify

Register the generated folder in a personal plugin marketplace, then install
`es-archive` from that marketplace in ChatGPT/Codex. The default personal
marketplace lives at `~/.agents/plugins/marketplace.json`; it is discovered
automatically. Installation copies the plugin into the client's plugin cache.

Start a new conversation after installation. Confirm that the ES Archive
skills are available and that `/mcp` shows the plugin's connection. First ask
the assistant to inspect the available archive tools without changing entries.

If you already configured ES Archive manually, use one connection for the
intended author to avoid duplicate tool listings. Existing standalone copies
of the same skills may also appear alongside the plugin's skills. This package
does not delete or disable any existing configuration or skills.

## Maintaining the package

Edit skills only in `skills/codex`, then regenerate. Generated copies are not
the source of truth. The packaging template is under
`packaging/chatgpt/es-archive`; the builder adds `.mcp.json` using the actual app
path and copies complete skill folders, including their metadata.

This package uses the supported `.codex-plugin/plugin.json` manifest and
`.mcp.json` configuration. Public directory publication and an onboarding
button are separate from this local plugin prototype.

Official packaging documentation: https://developers.openai.com/plugins/build/plugins
