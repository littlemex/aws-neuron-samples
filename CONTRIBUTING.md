# Contributing

Thank you for your interest in contributing. This project welcomes community
contributions: bug reports, feature requests, documentation improvements, and
code changes.

## Reporting issues

Before opening a new issue, please search existing issues to avoid duplicates.
When filing a new issue, include:

- A concise description of the problem or request.
- The AWS region, instance type, and AMI variant you are using.
- The commands you ran and the output you observed.
- Any relevant excerpts from CloudFormation events, CloudWatch logs, or SSM
  command output. Redact account ids and other identifiers you do not want
  public before attaching them.

## Proposing changes

1. Open an issue first for anything larger than a small bug fix so we can
   agree on direction before you invest time.
2. Fork the repository and create a topic branch off `main`.
3. Keep the commit history focused: one logical change per commit, with a
   clear subject line.
4. For shell scripts, verify `bash -n <file>` passes. For the CDK app, make
   sure `npm run build` succeeds from `setup/single-node/cdk`.
5. Avoid introducing new hard-coded identifiers (AWS accounts, VPC / subnet
   / EFS ids, AMI ids). Make them configurable through flags or environment
   variables and document the default behavior.
6. Open a pull request. Describe what the change does, why it is needed, and
   how you verified it.

## Coding conventions

- Shell scripts: POSIX-compatible where practical; otherwise `#!/bin/bash`
  is acceptable. Prefer `set -e` and explicit error messages. Document
  expected environment variables at the top of the file.
- TypeScript (CDK): follow the existing file layout. Prefer L2 constructs
  unless L1 is required to expose a property the L2 does not surface.
- User-facing output: English, and parseable where possible (one fact per
  line, labels first).

## Security

If you discover a potential security issue, please do not open a public
issue. Instead, follow AWS's vulnerability reporting process documented at
<https://aws.amazon.com/security/vulnerability-reporting/>.

## License

By contributing, you agree that your contributions will be licensed under
the MIT-0 License that covers this repository (see `LICENSE`).
