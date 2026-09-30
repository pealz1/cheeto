# Security policy

Cheeto generates code that sits between untrusted clients and your game's server, so security reports are taken seriously and handled before anything else.

## Supported versions

| Version | Supported |
| --- | --- |
| 1.x | Yes |
| < 1.0 | No |

Fixes are released as patch versions of the latest minor release.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through [GitHub's private vulnerability reporting](https://github.com/pealz1/cheeto/security/advisories/new), or email **security@pealz.cc**.

Include as much of the following as you can:

- the Cheeto version, and whether the issue is in the compiler, the generated runtime, the Studio plugin or `extras/security`,
- a minimal `.cheeto` schema and the steps or packet that trigger the problem,
- what an attacker gains: a crash, a server hang, a bypassed policy, data they should not see, and so on.

You can expect an acknowledgement within three days and an assessment within a week. Once a fix is ready we will agree on a disclosure date with you and credit you in the release notes, unless you prefer to stay anonymous.

## Scope

In scope:

- ways for a client to crash, hang or exhaust the memory of a server running generated code,
- bypasses of schema validation, policies, auth rules, rate limits, cooldowns, replay protection or honeypots,
- code generation that produces unsafe modules from a valid schema,
- vulnerabilities in the release pipeline or published artifacts.

Out of scope:

- anything that requires the attacker to already control the server,
- reading traffic that a client legitimately receives. Clients can always observe data sent to them; see the [security model](README.md#security-model),
- client-side detection evasion by an executor running at a higher privilege level than game scripts. The client shield and `extras/security` detectors raise the cost of abuse but are documented as best-effort.
