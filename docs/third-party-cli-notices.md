# Third-party CLI adapter notices

来源分为两类：Token Monitor、Tokscale 和项目中随包保留的固定上游目录属于基于固定源码的二次开发与原生集成；CodexBar、subswap、QuotaBar、zcode-acp、Codex-Manager 以及 aswap 仅作协议适配或静态研究参考，未复制代码，也不构成运行时依赖。

The notices distinguish second-developed bundled integrations from protocol research. Fixed Token Monitor and Tokscale sources remain bundled with AiGoodBro bridge, hooks and Swift host changes; the other references below are independently implemented and are not runtime dependencies.

## Embedded second-developed integrations

- **Token Monitor v0.62.0** — [Javis603/token-monitor](https://github.com/Javis603/token-monitor/tree/dcccfb01557e2786888fd5479552f392ac6c0d32). The fixed upstream tree and MIT notice remain bundled; AiGoodBro adds the native bridge, hooks and host integration. See [`Companion/TokenMonitorEngine/SOURCE.json`](../Companion/TokenMonitorEngine/SOURCE.json) and [`token-monitor-integration-0913v1.md`](token-monitor-integration-0913v1.md).
- **Tokscale fork** — [Javis603/tokscale](https://github.com/Javis603/tokscale), bundled revision `06a9f1625d5a505f01b39eff29f7be44a2c52188`. The fixed source and MIT notice remain bundled; the host integration is maintained by AiGoodBro.

## Protocol and static research references

- **BlackHole1/aswap v1.1.0** — [release](https://github.com/BlackHole1/aswap/releases/tag/v1.1.0), fixed commit `f0e5bc6512d1055adac77127fc59dc5de486cb31`, with the upstream `realiti4/claude-swap` baseline `9aa6d0292736173e70d4c5d8e2026210fe39a9ee`. This is the Claude multi-account CLI/Chrome profile tool referenced by the X post. It is not a communication protocol and is not copied, bundled, or connected to Codex login, Feishu, WeCom, or AiGoodBro quota routing. If it is ever reused, retain its MIT notice, patch provenance and an explicit second-development record; this release does not integrate it.

The native, read-only local CLI quota adapters use endpoint, credential-shape, header, and response-schema knowledge adapted from the following fixed source snapshots. No third-party code is executed or bundled as a dependency.

## CodexBar

- Project: `steipete/CodexBar`
- Source snapshot: `7fdc17636f161ab410d8a6a0e8f45b6a595cf8d2`
- Adapted knowledge: Grok CLI OAuth selection and billing protocol; Kimi Code credential and usage protocol; Claude OAuth credential/usage shapes and required beta header; OpenCode Go usage endpoint and schema.

MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## subswap

- Project: `x0c/subswap`
- Source snapshot: `52e9c077b0dd12893c95fa638c3c534ffff4ee42`
- Adapted knowledge: Kimi usage windows and reset fields; OpenCode data directory, provider isolation, API usage windows, and rate-limited status semantics.

MIT License

Copyright (c) 2026 subswap contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## QuotaBar

- Project: `zydtiger/QuotaBar`
- Source snapshot: `8834af6d6d79364881494e586bbb445f7509a579`
- Adapted knowledge: exact ZCode GLM/Z.AI Coding Plan provider configuration and quota response schema. Native ZCode subscription data is separate and unsupported.

MIT License

Copyright (c) 2026 zydtiger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


The Apache-2.0 project `william0wang/zcode-acp` at `e515987baf4df755c19912ccb9735cbf28024e02` was consulted to corroborate the protocol. Its implementation was not copied.
