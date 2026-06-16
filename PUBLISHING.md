# Publishing Paddock to the Official MCP Registry

The manifest is `server.json` in the repo root. The namespace `io.github.unblinkr/paddock-mcp` authorizes via the **unblinkr** GitHub account — log in as that account.

## Steps

1. Install the publisher CLI:
   ```bash
   brew install mcp-publisher
   # or download from https://github.com/modelcontextprotocol/registry/releases
   ```
2. Authenticate with GitHub (device flow; authorizes io.github.unblinkr/*):
   ```bash
   mcp-publisher login github
   ```
3. Publish (from the repo root, where server.json lives):
   ```bash
   mcp-publisher publish
   ```
4. Verify:
   ```bash
   curl "https://registry.modelcontextprotocol.io/v0/servers?search=paddock"
   ```

## Notes

- If schema validation complains, run `mcp-publisher init` and copy the description/remotes/repository fields from server.json.
- Endpoint is the verified working `https://paddock.finance/api/mcp/mcp`.
- Once published, PulseMCP and other downstream registries ingest from here automatically.

